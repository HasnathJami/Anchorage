package com.anchorage.perimeter.domain.policy

/**
 * Every tunable number the geofence obeys, in one reviewable place.
 *
 * The brief only mandates [radiusMeters] = 50. The other three exist because a
 * naive `distance < 50` check behaves badly on real hardware:
 *
 *  * [exitHysteresisMeters] - GPS noise of a few metres makes a user standing
 *    still on the boundary flip INSIDE/OUTSIDE several times a second, which
 *    would strobe the UI and could revoke the button mid-tap. Entry is judged
 *    at 50 m, exit only past 50 + 8 m. This is a Schmitt trigger, the standard
 *    fix for a noisy threshold.
 *  * [maxTrustedAccuracyMeters] - a fix whose own error radius exceeds the
 *    fence tells you nothing. Anchorage shows it as "low confidence" instead
 *    of pretending to know.
 *  * [maxAnchorAccuracyMeters] - the bar for *saving* an office is stricter
 *    than for checking against one, because the anchor's error is inherited by
 *    every future comparison.
 */
data class GeofencePolicy(
    val radiusMeters: Double = DEFAULT_RADIUS_METERS,
    val exitHysteresisMeters: Double = DEFAULT_EXIT_HYSTERESIS_METERS,
    val maxTrustedAccuracyMeters: Float = DEFAULT_MAX_TRUSTED_ACCURACY_METERS,
    val maxAnchorAccuracyMeters: Float = DEFAULT_MAX_ANCHOR_ACCURACY_METERS,
) {
    init {
        require(radiusMeters > 0) { "radius must be positive" }
        require(exitHysteresisMeters >= 0) { "hysteresis cannot be negative" }
    }

    /** Distance at which an INSIDE user is finally declared OUTSIDE. */
    val exitRadiusMeters: Double get() = radiusMeters + exitHysteresisMeters

    companion object {
        const val DEFAULT_RADIUS_METERS = 50.0
        const val DEFAULT_EXIT_HYSTERESIS_METERS = 8.0
        const val DEFAULT_MAX_TRUSTED_ACCURACY_METERS = 50f
        const val DEFAULT_MAX_ANCHOR_ACCURACY_METERS = 35f

        val Default = GeofencePolicy()
    }
}
