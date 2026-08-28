package com.anchorage.perimeter.domain.policy

/**
 * The result of evaluating one location fix against the office anchor.
 *
 * [isConfident] is separate from [status] deliberately: a user can be reported
 * OUTSIDE at 120 m with high confidence, or INSIDE at 12 m with a 90 m error
 * radius - and the UI must say very different things about those two.
 */
data class GeofenceReading(
    val distanceMeters: Double,
    val radiusMeters: Double,
    val status: ProximityStatus,
    val accuracyMeters: Float,
    val isConfident: Boolean,
    val fixTimestampEpochMillis: Long,
    val isMockProvider: Boolean = false,
) {
    /** 0f at the anchor, 1f at (or beyond) the fence edge - drives the dial arc. */
    val fenceProgress: Float
        get() = (distanceMeters / radiusMeters).coerceIn(0.0, 1.0).toFloat()

    /** True only when proximity *and* confidence both permit a check-in. */
    val allowsCheckIn: Boolean get() = status.isInside && isConfident
}
