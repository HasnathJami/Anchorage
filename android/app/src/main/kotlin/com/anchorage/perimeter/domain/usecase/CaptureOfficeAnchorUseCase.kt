package com.anchorage.perimeter.domain.usecase

import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.core.common.outcome.flatMap
import com.anchorage.perimeter.core.common.outcome.map
import com.anchorage.perimeter.domain.model.OfficeAnchor
import com.anchorage.perimeter.domain.policy.GeofenceEvaluator
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.anchorage.perimeter.domain.port.LocationTracker
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository

/**
 * **"Set Office Location"** — the user is standing at the office and wants
 * the app to remember this spot.
 *
 * Takes one high-accuracy GPS fix and freezes it as the anchor that every
 * future check-in will be measured against.
 *
 * ## What happens, in order
 *
 * 1. Ask the positioning stack for a single fresh fix.
 * 2. Reject it if it is not accurate enough (see below).
 * 3. Build an [OfficeAnchor] from it and save it.
 *
 * ## Why the accuracy gate makes this a use case, not a one-line save
 *
 * Saving a fix with a 120 m error radius would silently turn the 50 m
 * geofence into a coin toss for the rest of the app's life — every later
 * check-in would be measured against a point that could be anywhere inside a
 * city block. The user would have no way to know.
 *
 * Failing loudly, with the actual numbers attached, is the honest behaviour.
 * The gate is stricter than the one used for check-ins, because this error is
 * inherited by every comparison made afterwards.
 *
 * ## Its sibling
 *
 * [PlaceOfficeAnchorUseCase] does the same job for a pin dropped on the map.
 * They are deliberately separate — see that class for why.
 *
 * @param locationTracker Where the fix comes from.
 * @param officeAnchorRepository Where the anchor is saved.
 * @param geofenceEvaluator Owns the accuracy rule, via
 *   [GeofenceEvaluator.isAcceptableAnchorFix].
 * @param policy Read only to report the *required* accuracy in the failure,
 *   so the message can be specific.
 */
class CaptureOfficeAnchorUseCase(
    private val locationTracker: LocationTracker,
    private val officeAnchorRepository: OfficeAnchorRepository,
    private val geofenceEvaluator: GeofenceEvaluator,
    private val policy: GeofencePolicy = GeofencePolicy.Default,
) {

    /**
     * @param label What to call this place on the office card.
     * @param timeoutMillis How long to wait for a fix before giving up.
     * @return The saved anchor, or a failure — an
     *   [AppError.Location.InsufficientAccuracy] if the fix was too vague, a
     *   [AppError.Location.Timeout] if none arrived, or an
     *   [AppError.Storage] if saving failed.
     */
    suspend operator fun invoke(
        label: String = OfficeAnchor.DEFAULT_LABEL,
        timeoutMillis: Long = LocationTracker.DEFAULT_FIX_TIMEOUT_MILLIS,
    ): Outcome<OfficeAnchor> =
        // Step 1 - one fresh fix. `flatMap` means: if this fails, stop here
        // and hand that failure straight back to the caller.
        locationTracker.currentFix(timeoutMillis)
            .flatMap { fix ->
                // Step 2 - the accuracy gate.
                if (!geofenceEvaluator.isAcceptableAnchorFix(fix)) {
                    Outcome.Failure(
                        AppError.Location.InsufficientAccuracy(
                            reportedAccuracyMeters = fix.accuracyMeters,
                            requiredAccuracyMeters = policy.maxAnchorAccuracyMeters,
                        ),
                    )
                } else {
                    // Step 3 - freeze the fix into an anchor and persist it.
                    val anchor = OfficeAnchor(
                        point = fix.point,
                        accuracyMeters = fix.accuracyMeters,
                        capturedAtEpochMillis = fix.timestampEpochMillis,
                        label = label,
                    )
                    // `map { anchor }` because save() returns Outcome<Unit>,
                    // but the caller wants the anchor it just created.
                    officeAnchorRepository.save(anchor).map { anchor }
                }
            }
}
