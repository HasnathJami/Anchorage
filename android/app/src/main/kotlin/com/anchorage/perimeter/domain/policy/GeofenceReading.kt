package com.anchorage.perimeter.domain.policy

/**
 * The result of measuring one GPS fix against the office anchor: how far away
 * the user is, and whether that counts as "at the office".
 *
 * Produced by [GeofenceEvaluator.evaluate] and carried on
 * [com.anchorage.perimeter.domain.model.AttendanceStatus.reading].
 *
 * ## Why distance and confidence are separate fields
 *
 * They answer different questions, and the UI must say very different things
 * about them:
 *
 * - OUTSIDE at 120 m with a 5 m error radius → "you are 120 m away". True and
 *   actionable.
 * - INSIDE at 12 m with a 90 m error radius → the phone has no idea where it
 *   is. The 12 m is not evidence of anything.
 *
 * Collapsing these into one boolean would let the second case silently
 * authorise a check-in, which is precisely the failure this app exists to
 * prevent.
 *
 * @property distanceMeters Metres from the office anchor to the user.
 * @property radiusMeters The fence size this reading was judged against,
 *   carried so the UI never has to look the number up separately.
 * @property status INSIDE or OUTSIDE, after hysteresis has been applied.
 * @property accuracyMeters The error radius of the fix behind this reading.
 * @property isConfident Whether [accuracyMeters] is good enough to believe.
 *   See [GeofencePolicy.maxTrustedAccuracyMeters].
 * @property fixTimestampEpochMillis When the underlying fix was taken, so the
 *   UI can show how fresh the reading is.
 * @property isMockProvider Whether the fix came from a mock location
 *   provider. Reported, never blocked.
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
    /**
     * How full the distance dial's arc should be: `0f` standing on the
     * anchor, `1f` at the fence edge or anywhere beyond it.
     *
     * Clamped, because the arc cannot draw more than a full sweep and a user
     * 5 km away should look exactly as outside as one 51 m away.
     */
    val fenceProgress: Float
        get() = (distanceMeters / radiusMeters).coerceIn(0.0, 1.0).toFloat()

    /**
     * True only when proximity **and** confidence both permit a check-in.
     *
     * This is the single expression the button's enabled state and the
     * use case's enforcement both read, so they cannot drift apart.
     */
    val allowsCheckIn: Boolean get() = status.isInside && isConfident
}
