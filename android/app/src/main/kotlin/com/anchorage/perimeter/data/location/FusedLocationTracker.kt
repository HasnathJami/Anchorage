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
 * [LocationTracker] backed by Google Play Services' fused provider.
 *
 * This class is the app's entire blast radius for positioning failures. Its
 * contract is that it **never throws** - every hardware, permission and
 * connectivity fault is translated into a typed
 * [AppError.Location] and delivered as a value, because a `Flow` that throws
 * would tear the collector down and lose the geofence hysteresis state built
 * up in the use case above it.
 *
 * The failure paths covered here, in the order they are checked:
 *
 *  1. Permission not granted            -> [AppError.Location.PermissionDenied]
 *  2. Device location toggle off        -> [AppError.Location.ServicesDisabled]
 *  3. `SecurityException` from the OS   -> [AppError.Location.PermissionDenied]
 *     (a permission revoked *while* the stream is live lands here)
 *  4. Provider reports unavailable      -> [AppError.Location.PositionUnavailable]
 *  5. No fix inside the deadline        -> [AppError.Location.Timeout]
 *  6. Anything else at all              -> [AppError.Location.PositionUnavailable]
 */
@Singleton
class FusedLocationTracker @Inject constructor(
    private val fusedClient: FusedLocationProviderClient,
    private val environment: LocationEnvironment,
    private val dispatchers: DispatcherProvider,
) : LocationTracker {

    @SuppressLint("MissingPermission") // Guarded by [environment] on every path.
    override fun stream(intervalMillis: Long): Flow<Outcome<LocationFix>> {
        preflight()?.let { return flowOf(Outcome.Failure(it)) }

        return callbackFlow {
            // Seed with the position the platform already holds.
            //
            // Without this the screen sat on "Acquiring a satellite fix" until
            // the *next* update arrived, which indoors is tens of seconds and
            // sometimes never - the provider had a perfectly good fix cached
            // and nobody asked for it. The user is left unable to tell a slow
            // GPS from a broken app.
            //
            // Safe to show because it is never trusted: `MarkAttendanceUseCase`
            // takes its own fresh fix through [currentFix] and ignores this
            // stream entirely, so a stale seed can move the dial but can never
            // authorise a check-in.
            runCatching { fusedClient.lastLocation.await() }
                .getOrNull()
                ?.let { trySend(Outcome.Success(it.toFix())) }

            val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, intervalMillis)
                .setMinUpdateIntervalMillis(intervalMillis / 2)
                .setWaitForAccurateLocation(false)
                .build()

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

            try {
                fusedClient.requestLocationUpdates(request, callback, null).addOnFailureListener {
                    trySend(Outcome.Failure(it.toLocationError()))
                }
            } catch (security: SecurityException) {
                // Permission revoked between the preflight and this call.
                trySend(Outcome.Failure(AppError.Location.PermissionDenied(security)))
            }

            awaitClose { fusedClient.removeLocationUpdates(callback) }
        }
            .catch { throwable ->
                if (throwable is CancellationException) throw throwable
                emit(Outcome.Failure(throwable.toLocationError()))
            }
            .flowOn(dispatchers.io)
    }

    @SuppressLint("MissingPermission") // Guarded by [environment] on every path.
    override suspend fun currentFix(timeoutMillis: Long): Outcome<LocationFix> {
        preflight()?.let { return Outcome.Failure(it) }

        val cancellationSource = CancellationTokenSource()
        return try {
            val location = withTimeoutOrNull(timeoutMillis) {
                fusedClient
                    .getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, cancellationSource.token)
                    .await()
            }

            when (location) {
                null -> {
                    // Distinguishing "the clock ran out" from "the chip has no
                    // fix" matters: the first is worth retrying immediately,
                    // the second usually means step outside.
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
     * Returns the blocking error, or `null` when the environment is usable.
     */
    private fun preflight(): AppError.Location? = when {
        !environment.hasLocationPermission() -> AppError.Location.PermissionDenied()
        !environment.isLocationEnabled() -> AppError.Location.ServicesDisabled()
        else -> null
    }

    private fun Throwable.toLocationError(): AppError.Location = when (this) {
        is SecurityException -> AppError.Location.PermissionDenied(this)
        else -> AppError.Location.PositionUnavailable(this)
    }

    private fun Location.toFix(): LocationFix = LocationFix(
        point = GeoPoint(latitude = latitude, longitude = longitude),
        accuracyMeters = if (hasAccuracy()) accuracy else UNKNOWN_ACCURACY_METERS,
        timestampEpochMillis = time,
        isMock = isMockLocation(),
    )

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
