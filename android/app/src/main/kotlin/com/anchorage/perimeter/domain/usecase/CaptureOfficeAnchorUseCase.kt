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
 * "Set Office Location": take one high-accuracy fix and freeze it as the
 * anchor every future check-in is measured against.
 *
 * The accuracy gate is the reason this is a use case and not a one-line
 * repository call. Saving a 120 m-accurate fix would silently turn the 50 m
 * geofence into a coin toss for the rest of the app's life, and the user would
 * have no way to know. Failing loudly - with the actual numbers attached - is
 * the honest behaviour.
 */
class CaptureOfficeAnchorUseCase(
    private val locationTracker: LocationTracker,
    private val officeAnchorRepository: OfficeAnchorRepository,
    private val geofenceEvaluator: GeofenceEvaluator,
    private val policy: GeofencePolicy = GeofencePolicy.Default,
) {

    suspend operator fun invoke(
        label: String = OfficeAnchor.DEFAULT_LABEL,
        timeoutMillis: Long = LocationTracker.DEFAULT_FIX_TIMEOUT_MILLIS,
    ): Outcome<OfficeAnchor> =
        locationTracker.currentFix(timeoutMillis)
            .flatMap { fix ->
                if (!geofenceEvaluator.isAcceptableAnchorFix(fix)) {
                    Outcome.Failure(
                        AppError.Location.InsufficientAccuracy(
                            reportedAccuracyMeters = fix.accuracyMeters,
                            requiredAccuracyMeters = policy.maxAnchorAccuracyMeters,
                        ),
                    )
                } else {
                    val anchor = OfficeAnchor(
                        point = fix.point,
                        accuracyMeters = fix.accuracyMeters,
                        capturedAtEpochMillis = fix.timestampEpochMillis,
                        label = label,
                    )
                    officeAnchorRepository.save(anchor).map { anchor }
                }
            }
}
