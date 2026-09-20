package com.anchorage.perimeter.data.local.room

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.model.GeoPoint

/**
 * How an attendance record is shaped **in the database**.
 *
 * ## Why this exists separately from [AttendanceRecord]
 *
 * They look almost identical, and that duplication is deliberate. The domain
 * model is free to hold a [GeoPoint]; a SQLite row cannot — it needs two
 * plain `REAL` columns. Keeping them apart means the storage format can
 * change (a new column, a renamed field) without the domain model, and every
 * rule built on it, having to change too.
 *
 * ## The unique index is the real once-per-day rule
 *
 * [localDate] is denormalised — the same instant is already in
 * [markedAtEpochMillis] — and carries a **unique index**. That index, not
 * application code, is what actually makes "one check-in per day" true. Even
 * if two coroutines raced past the use case's check simultaneously, SQLite
 * would reject the second insert.
 *
 * Application checks are for giving the user a good message. The database
 * constraint is for correctness.
 */
@Entity(
    tableName = "attendance_records",
    indices = [Index(value = ["local_date"], unique = true)],
)
data class AttendanceEntity(
    @PrimaryKey
    @ColumnInfo(name = "id")
    val id: String,

    /** The exact instant, UTC. What the UI formats into a time. */
    @ColumnInfo(name = "marked_at_epoch_millis")
    val markedAtEpochMillis: Long,

    /** ISO `yyyy-MM-dd` in the *user's* zone. Carries the unique index. */
    @ColumnInfo(name = "local_date")
    val localDate: String,

    @ColumnInfo(name = "latitude")
    val latitude: Double,

    @ColumnInfo(name = "longitude")
    val longitude: Double,

    /** Frozen at check-in time — see [AttendanceRecord] for why. */
    @ColumnInfo(name = "distance_meters")
    val distanceMeters: Double,

    @ColumnInfo(name = "accuracy_meters")
    val accuracyMeters: Float,

    @ColumnInfo(name = "anchor_label")
    val anchorLabel: String,
)

/**
 * Database row to domain model.
 *
 * Kept as an extension function rather than a method on either type, so
 * neither layer has to import the other's mapper.
 */
fun AttendanceEntity.toDomain(): AttendanceRecord = AttendanceRecord(
    id = id,
    markedAtEpochMillis = markedAtEpochMillis,
    point = GeoPoint(latitude, longitude),
    distanceMeters = distanceMeters,
    accuracyMeters = accuracyMeters,
    anchorLabel = anchorLabel,
)

/**
 * Domain model to database row.
 *
 * @param localDate Supplied by the repository, which is the layer that owns
 *   the clock and therefore knows which local day this instant falls on. The
 *   entity cannot work it out for itself without a time zone.
 */
fun AttendanceRecord.toEntity(localDate: String): AttendanceEntity = AttendanceEntity(
    id = id,
    markedAtEpochMillis = markedAtEpochMillis,
    localDate = localDate,
    latitude = point.latitude,
    longitude = point.longitude,
    distanceMeters = distanceMeters,
    accuracyMeters = accuracyMeters,
    anchorLabel = anchorLabel,
)
