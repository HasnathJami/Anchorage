package com.anchorage.perimeter.domain.model

/**
 * The saved office coordinate that every proximity check is measured against.
 *
 * The accuracy and capture timestamp of the *original* fix are stored with it
 * so the UI can honestly show how trustworthy the anchor itself is - a 50 m
 * geofence anchored on a 40 m fix is a very different promise from one
 * anchored on a 4 m fix.
 */
data class OfficeAnchor(
    val point: GeoPoint,
    val accuracyMeters: Float,
    val capturedAtEpochMillis: Long,
    val label: String = DEFAULT_LABEL,
    val source: AnchorSource = AnchorSource.GpsFix,
) {
    companion object {
        const val DEFAULT_LABEL = "Head Office"
    }
}

/**
 * How the anchor came to exist.
 *
 * This decides what the UI may honestly say about [OfficeAnchor.accuracyMeters].
 * A GPS-captured anchor inherits the error radius of the fix behind it, and
 * that number means something. A pin dropped on a map has no fix and therefore
 * no error radius - reporting "±0 m" for one would claim a precision nobody
 * measured. The provenance is stored so the two can never be confused after
 * the fact.
 */
enum class AnchorSource {
    /** Captured from a live high-accuracy fix, subject to the accuracy gate. */
    GpsFix,

    /** Placed by hand on the map picker. Carries no measured accuracy. */
    ManualPlacement,
}
