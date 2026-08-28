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
) {
    companion object {
        const val DEFAULT_LABEL = "Head Office"
    }
}
