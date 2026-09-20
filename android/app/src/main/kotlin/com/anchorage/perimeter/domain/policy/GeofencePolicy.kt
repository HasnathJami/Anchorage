package com.anchorage.perimeter.domain.policy

/**
 * Every tunable number the geofence obeys, in one reviewable place.
 *
 * If you want to know why the app behaves the way it does at the edge of the
 * office, the answer is one of these four numbers.
 *
 * ## The brief only asked for one of them
 *
 * The assessment mandates [radiusMeters] = 50. The other three exist because
 * a naive `if (distance < 50)` check behaves badly on real hardware:
 *
 * - **[exitHysteresisMeters]** — GPS noise of a few metres makes a user
 *   standing still on the boundary flip INSIDE/OUTSIDE several times a
 *   second. That would strobe the UI and could revoke the check-in button
 *   mid-tap. So entry is judged at 50 m but exit only past 50 + 8 m. This is
 *   a *Schmitt trigger*, the standard fix for a noisy threshold: the line you
 *   must cross depends on which side you are already on.
 *
 * - **[maxTrustedAccuracyMeters]** — a fix whose own error radius is bigger
 *   than the fence tells you nothing at all. Anchorage shows it as "low
 *   confidence" instead of pretending to know.
 *
 * - **[maxAnchorAccuracyMeters]** — the bar for *saving* an office is
 *   stricter than the bar for checking against one, because the anchor's
 *   error is inherited by every future comparison made against it. Get the
 *   anchor wrong once and every check-in afterwards is wrong.
 *
 * @property radiusMeters How close the user must be to check in. The fence.
 * @property exitHysteresisMeters Extra distance beyond [radiusMeters] that an
 *   already-inside user must travel before being declared outside.
 * @property maxTrustedAccuracyMeters The worst fix accuracy still allowed to
 *   decide a check-in.
 * @property maxAnchorAccuracyMeters The worst fix accuracy still allowed to
 *   *become* an office anchor. Stricter than the above, on purpose.
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

    /**
     * The distance at which a user currently reported INSIDE is finally
     * declared OUTSIDE: [radiusMeters] + [exitHysteresisMeters], so 58 m by
     * default.
     *
     * Note this affects the **dial only**. The check-in decision itself uses
     * the true 50 m with no forgiveness — see [GeofenceEvaluator].
     */
    val exitRadiusMeters: Double get() = radiusMeters + exitHysteresisMeters

    companion object {
        /** The fence the brief specifies. */
        const val DEFAULT_RADIUS_METERS = 50.0

        /** Comfortably above typical urban GPS jitter, well below the fence. */
        const val DEFAULT_EXIT_HYSTERESIS_METERS = 8.0

        /** A fix worse than the fence itself cannot decide anything. */
        const val DEFAULT_MAX_TRUSTED_ACCURACY_METERS = 50f

        /** Stricter, because the anchor's error is inherited forever. */
        const val DEFAULT_MAX_ANCHOR_ACCURACY_METERS = 35f

        /** The policy the app actually runs with. */
        val Default = GeofencePolicy()
    }
}
