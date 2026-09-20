package com.anchorage.perimeter.domain.model

/**
 * The saved office location — the centre of the geofence.
 *
 * The user sets this once (either by standing at the office and tapping
 * "Use my current location", or by dropping a pin on the map picker). From
 * then on, every proximity check measures the distance from the phone to
 * [point].
 *
 * It is stored on the device in DataStore, so it survives the app being
 * closed. See
 * [com.anchorage.perimeter.data.local.datastore.OfficeAnchorLocalSource].
 *
 * ## Why the original fix's accuracy is kept
 *
 * The anchor's own error is inherited by every future comparison against it.
 * A 50 m geofence anchored on a 4 m fix is a meaningful promise; the same
 * geofence anchored on a 40 m fix is close to meaningless. Storing
 * [accuracyMeters] lets the UI be honest about which of those the user has.
 *
 * @property point The office coordinate. The centre of the circle.
 * @property accuracyMeters How good the GPS fix was when this anchor was
 *   captured. Meaningless — and displayed as such — when [source] is
 *   [AnchorSource.ManualPlacement].
 * @property capturedAtEpochMillis When the anchor was saved, so the UI can
 *   show "Anchored 3 days ago".
 * @property label A human name for the place, shown on the office card.
 * @property source How the anchor came to exist. See [AnchorSource].
 */
data class OfficeAnchor(
    val point: GeoPoint,
    val accuracyMeters: Float,
    val capturedAtEpochMillis: Long,
    val label: String = DEFAULT_LABEL,
    val source: AnchorSource = AnchorSource.GpsFix,
) {
    companion object {
        /** Used when the user has not named the place themselves. */
        const val DEFAULT_LABEL = "Head Office"
    }
}

/**
 * How an [OfficeAnchor] came to exist.
 *
 * This decides what the UI may honestly say about
 * [OfficeAnchor.accuracyMeters].
 *
 * A GPS-captured anchor inherits the error radius of the fix behind it, and
 * that number means something. A pin dropped on a map has no fix and
 * therefore no error radius — reporting "±0 m" for one would claim a
 * precision nobody measured. The provenance is stored so the two can never be
 * confused after the fact.
 */
enum class AnchorSource {
    /**
     * Captured from a live high-accuracy fix, and subject to the accuracy
     * gate in
     * [com.anchorage.perimeter.domain.policy.GeofenceEvaluator.isAcceptableAnchorFix].
     */
    GpsFix,

    /** Placed by hand on the map picker. Carries no measured accuracy. */
    ManualPlacement,
}
