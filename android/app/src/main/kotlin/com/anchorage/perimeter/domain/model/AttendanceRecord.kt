package com.anchorage.perimeter.domain.model

/**
 * An immutable, append-only proof of presence.
 *
 * The distance and accuracy *at the moment of marking* are frozen into the
 * record. Storing only a timestamp would make the audit trail unfalsifiable
 * later, when the office anchor may already have been moved.
 */
data class AttendanceRecord(
    val id: String,
    val markedAtEpochMillis: Long,
    val point: GeoPoint,
    val distanceMeters: Double,
    val accuracyMeters: Float,
    val anchorLabel: String,
)
