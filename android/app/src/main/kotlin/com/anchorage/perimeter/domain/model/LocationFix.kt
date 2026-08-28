package com.anchorage.perimeter.domain.model

/**
 * One reading from the device's positioning stack.
 *
 * [accuracyMeters] is the 68 % confidence radius reported by the platform and
 * is a first-class part of the model rather than metadata: Anchorage refuses
 * to anchor an office - or admit a check-in - on a fix it does not trust.
 *
 * [isMock] is captured so the audit trail can flag records produced while a
 * mock-location provider was active.
 */
data class LocationFix(
    val point: GeoPoint,
    val accuracyMeters: Float,
    val timestampEpochMillis: Long,
    val isMock: Boolean = false,
) {
    init {
        require(accuracyMeters >= 0f) { "accuracy cannot be negative but was $accuracyMeters" }
    }
}
