package com.anchorage.perimeter.domain.model

/**
 * Proof that someone was at the office — one row in the attendance history.
 *
 * Records are **append-only**. Nothing in the app edits or deletes one; the
 * Room table refuses duplicates for the same day rather than overwriting
 * (see [com.anchorage.perimeter.data.local.room.AttendanceDao]).
 *
 * ## Why the distance is frozen into the record
 *
 * It would be tempting to store only a timestamp and recompute the distance
 * later. That breaks the moment the user moves their office anchor: the
 * history would then report distances to a building they have left, and every
 * past record would silently change. Freezing the numbers at the moment of
 * marking is what makes the trail an audit trail rather than a guess.
 *
 * @property id A unique identifier, supplied by
 *   [com.anchorage.perimeter.domain.port.IdGenerator] so tests can be
 *   deterministic.
 * @property markedAtEpochMillis When the check-in happened, in milliseconds
 *   since 1 Jan 1970 UTC.
 * @property point Where the user stood when they checked in.
 * @property distanceMeters How far [point] was from the office anchor at that
 *   moment. Frozen, for the reason above.
 * @property accuracyMeters How trustworthy the GPS fix behind it was.
 * @property anchorLabel The name of the office at the time, so the row still
 *   reads correctly after the anchor is renamed or moved.
 */
data class AttendanceRecord(
    val id: String,
    val markedAtEpochMillis: Long,
    val point: GeoPoint,
    val distanceMeters: Double,
    val accuracyMeters: Float,
    val anchorLabel: String,
)
