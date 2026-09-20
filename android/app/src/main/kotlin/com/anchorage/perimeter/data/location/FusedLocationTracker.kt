package com.anchorage.perimeter.data.location

import android.annotation.SuppressLint
import android.location.Location
import android.os.Build
import com.anchorage.perimeter.core.common.dispatcher.DispatcherProvider
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.LocationFix
import com.anchorage.perimeter.domain.port.LocationTracker
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationAvailability
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The real GPS, wrapped so the rest of the app never has to know that Google
 * Play Services exists.
 *
 * This is the implementation of the [LocationTracker] port. It is where
 * Android actually enters the picture; everything above it - use cases,
 * policies, the ViewModel - sees only [LocationFix] and [AppError].
 *
 * ## The one rule: this class never throws
 *
 * Every hardware, permission and connectivity fault is translated into a
 * typed [AppError.Location] and delivered as a *value*.
 *
 * Why that matters so much here: a `Flow` that throws tears down its
 * collector. If this stream threw on a lost signal, the use case above it
 * would lose the hysteresis state it had built up, and the screen would have
 * to re-subscribe from scratch. As a value, a dropout is just another
 * emission and the stream carries on.
 *
 * ## Every failure path, in the order it is checked
 *
 * | # | Condition | Becomes |
 * |---|-----------|---------|
 * | 1 | Permission not granted | [AppError.Location.PermissionDenied] |
 * | 2 | Device location toggle off | [AppError.Location.ServicesDisabled] |
 * | 3 | `SecurityException` mid-stream | [AppError.Location.PermissionDenied] |
 * | 4 | Provider reports itself unavailable | [AppError.Location.PositionUnavailable] |
 * | 5 | No fix inside the deadline | [AppError.Location.Timeout] |
 * | 6 | Anything else at all | [AppError.Location.PositionUnavailable] |
 *
 * @param fusedClient Play Services' fused location provider - the thing that
 *   blends GPS, Wi-Fi and cell positioning into one answer.
 * @param environment The cheap "am I allowed / is the radio on" checks. A
 *   separate injectable so this class can be unit-tested with a stub.
 * @param dispatchers Which threads to use. Injected so tests are
 *   deterministic.
 */
@Singleton
class FusedLocationTracker @Inject constructor(
    private val fusedClient: FusedLocationProviderClient,
    private val environment: LocationEnvironment,
    private val dispatchers: DispatcherProvider,
) : LocationTracker {

    /**
     * Continuous position updates, for the live distance dial.
     *
     * @param intervalMillis How often to ask for a new fix.
     * @return A cold flow. The GPS starts when something collects it and
     *   stops when collection is cancelled - see the `awaitClose` at the
     *   bottom of the builder.
     */
    @SuppressLint("MissingPermission") // Guarded by [environment] on every path.
    override fun stream(intervalMillis: Long): Flow<Outcome<LocationFix>> {
        // Step 1 - cheap checks first. If we already know this cannot work,
        // return a one-item flow carrying the reason rather than wiring up
        // hardware that will only fail.
        preflight()?.let { return flowOf(Outcome.Failure(it)) }

        // Step 2 - `callbackFlow` bridges a callback-based API into a Flow.
        // Play Services pushes updates at us; `trySend` forwards each one on
        // to whoever is collecting.
        return callbackFlow {
            // Step 2a - seed with the position the platform already holds.
            //
            // Without this the screen sat on "Acquiring a satellite fix"
            // until the *next* update arrived, which indoors is tens of
            // seconds and sometimes never - the provider had a perfectly good
            // fix cached and nobody asked for it. The user is left unable to
            // tell a slow GPS from a broken app.
            //
            // Safe to show because it is never trusted: MarkAttendanceUseCase
            // takes its own fresh fix through [currentFix] and ignores this
            // stream entirely, so a stale seed can move the dial but can
            // never authorise a check-in.
            runCatching { fusedClient.lastLocation.await() }
                .getOrNull()
                ?.let { trySend(Outcome.Success(it.toFix())) }

            // Step 2b - describe the updates we want. HIGH_ACCURACY because a
            // 50 m fence needs GPS, not cell towers. No distance filter,
            // because a user standing still still wants the reading to
            // refresh.
            val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, intervalMillis)
                .setMinUpdateIntervalMillis(intervalMillis / 2)
                .setWaitForAccurateLocation(false)
                .build()

            // Step 2c - the callback Play Services will push into.
            val callback = object : LocationCallback() {
                override fun onLocationResult(result: LocationResult) {
                    result.lastLocation?.let { trySend(Outcome.Success(it.toFix())) }
                }

                override fun onLocationAvailability(availability: LocationAvailability) {
                    if (!availability.isLocationAvailable) {
                        trySend(Outcome.Failure(AppError.Location.PositionUnavailable()))
                    }
                }
            }

            // Step 2d - register it.
            try {
                // **An Executor, never a null Looper.** The overload that
                // takes a `Looper` treats `null` as "use the calling
                // thread's", and this block runs on `dispatchers.io` - a pool
                // thread that has no Looper at all. Play Services then throws
                // while wiring up its callback, the stream ends before a
                // single update arrives, and the screen sits on "Acquiring a
                // satellite fix" having asked for nothing. That is the
                // intermittent "it does not update when I move".
                //
                // The Executor overload has no Looper requirement, and
                // keeping the callbacks off the main thread costs nothing:
                // `trySend` is safe from any thread.
                fusedClient.requestLocationUpdates(
                    request,
                    dispatchers.io.asExecutor(),
                    callback,
                ).addOnFailureListener {
                    trySend(Outcome.Failure(it.toLocationError()))
                }
            } catch (security: SecurityException) {
                // Permission revoked between the preflight and this call.
                trySend(Outcome.Failure(AppError.Location.PermissionDenied(security)))
            } catch (throwable: Throwable) {
                // Registration crosses into Play Services, and what comes
                // back from it on the long tail of Android devices is not all
                // `SecurityException`. This class's contract is that it never
                // throws, so the catch has to be as wide as the contract.
                trySend(Outcome.Failure(throwable.toLocationError()))
            }

            // Step 2e - this runs when the collector goes away. Unregistering
            // here is what actually stops the GPS and saves the battery.
            awaitClose { fusedClient.removeLocationUpdates(callback) }
        }
            // Step 3 - the last safety net, for anything thrown inside the
            // builder. CancellationException is rethrown because cancelling a
            // coroutine is not a failure - swallowing it would break
            // structured concurrency.
            .catch { throwable ->
                if (throwable is CancellationException) throw throwable
                emit(Outcome.Failure(throwable.toLocationError()))
            }
            .flowOn(dispatchers.io)
    }

    /**
     * One fresh, high-accuracy fix - the trustworthy kind, used when
     * capturing the office anchor and when marking attendance.
     *
     * Unlike [stream], this actively asks the chip for a *new* fix rather
     * than accepting a cached one, which is the whole point: a stale position
     * must never be able to authorise a check-in.
     *
     * @param timeoutMillis How long to wait before giving up.
     * @return The fix, or a typed failure. Never throws (except
     *   [CancellationException], which is how coroutine cancellation works
     *   and must be allowed through).
     */
    @SuppressLint("MissingPermission") // Guarded by [environment] on every path.
    override suspend fun currentFix(timeoutMillis: Long): Outcome<LocationFix> {
        // Step 1 - same cheap checks as the stream.
        preflight()?.let { return Outcome.Failure(it) }

        // Step 2 - Play Services wants its own cancellation token so it can
        // stop burning the radio if we walk away.
        val cancellationSource = CancellationTokenSource()
        return try {
            val location = withTimeoutOrNull(timeoutMillis) {
                fusedClient
                    .getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, cancellationSource.token)
                    .await()
            }

            when (location) {
                null -> {
                    // Distinguishing "the clock ran out" from "the chip has
                    // no fix" matters: the first is worth retrying
                    // immediately, the second usually means step outside.
                    cancellationSource.cancel()
                    Outcome.Failure(AppError.Location.Timeout(waitedMillis = timeoutMillis))
                }

                else -> Outcome.Success(location.toFix())
            }
        } catch (cancellation: CancellationException) {
            cancellationSource.cancel()
            throw cancellation
        } catch (throwable: Throwable) {
            cancellationSource.cancel()
            Outcome.Failure(throwable.toLocationError())
        }
    }

    /**
     * The cheap checks that must pass before the platform is asked anything.
     *
     * Asking first is what turns a `SecurityException` crash, or a stream
     * that silently never emits, into a precise message on screen.
     *
     * @return The blocking error, or `null` when the environment is usable.
     */
    private fun preflight(): AppError.Location? = when {
        !environment.hasLocationPermission() -> AppError.Location.PermissionDenied()
        !environment.isLocationEnabled() -> AppError.Location.ServicesDisabled()
        else -> null
    }

    /** Translates any platform throwable into this app's error vocabulary. */
    private fun Throwable.toLocationError(): AppError.Location = when (this) {
        is SecurityException -> AppError.Location.PermissionDenied(this)
        else -> AppError.Location.PositionUnavailable(this)
    }

    /**
     * Converts Android's [Location] into the domain's [LocationFix].
     *
     * This single function is the entire boundary between the Android
     * location API and the rest of the app.
     */
    private fun Location.toFix(): LocationFix = LocationFix(
        point = GeoPoint(latitude = latitude, longitude = longitude),
        accuracyMeters = if (hasAccuracy()) accuracy else UNKNOWN_ACCURACY_METERS,
        timestampEpochMillis = time,
        isMock = isMockLocation(),
    )

    /** `isMock` replaced the deprecated `isFromMockProvider` in Android 12. */
    private fun Location.isMockLocation(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) isMock else @Suppress("DEPRECATION") isFromMockProvider

    private companion object {
        /**
         * A fix with no accuracy claim is treated as maximally untrustworthy
         * rather than perfect - failing closed is the only safe default for a
         * value that gates a check-in.
         */
        const val UNKNOWN_ACCURACY_METERS = Float.MAX_VALUE
    }
}
