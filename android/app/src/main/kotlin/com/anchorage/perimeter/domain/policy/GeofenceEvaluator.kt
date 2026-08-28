package com.anchorage.perimeter.domain.policy

import com.anchorage.perimeter.domain.geo.DistanceCalculator
import com.anchorage.perimeter.domain.model.LocationFix
import com.anchorage.perimeter.domain.model.OfficeAnchor

/**
 * Pure decision function: (anchor, fix, previous status) -> [GeofenceReading].
 *
 * It holds no state - the caller threads [previousStatus] through - which
 * keeps it trivially testable and safe to call from any thread.
 */
class GeofenceEvaluator(
    private val distanceCalculator: DistanceCalculator,
    private val policy: GeofencePolicy = GeofencePolicy.Default,
) {

    fun evaluate(
        anchor: OfficeAnchor,
        fix: LocationFix,
        previousStatus: ProximityStatus? = null,
    ): GeofenceReading {
        val distance = distanceCalculator.distanceMeters(anchor.point, fix.point)

        // Schmitt trigger: the threshold you must cross depends on where you
        // already were. Entering requires <= 50 m; leaving requires > 58 m.
        val threshold = if (previousStatus == ProximityStatus.INSIDE) {
            policy.exitRadiusMeters
        } else {
            policy.radiusMeters
        }

        val status = if (distance <= threshold) ProximityStatus.INSIDE else ProximityStatus.OUTSIDE

        return GeofenceReading(
            distanceMeters = distance,
            radiusMeters = policy.radiusMeters,
            status = status,
            accuracyMeters = fix.accuracyMeters,
            isConfident = fix.accuracyMeters <= policy.maxTrustedAccuracyMeters,
            fixTimestampEpochMillis = fix.timestampEpochMillis,
            isMockProvider = fix.isMock,
        )
    }

    /** True when [fix] is precise enough to be frozen as an office anchor. */
    fun isAcceptableAnchorFix(fix: LocationFix): Boolean =
        fix.accuracyMeters <= policy.maxAnchorAccuracyMeters
}
