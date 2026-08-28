package com.anchorage.perimeter.data.local.room

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.model.GeoPoint

/**
 * Storage shape of an attendance proof.
 *
 * [localDate] is denormalised (stored as an ISO yyyy-MM-dd string) and given a
 * unique index. That index - not application code - is what actually makes the
 * once-per-day rule true: even if two coroutines raced past the use case check
 * simultaneously, SQLite would reject the second insert.
 */
@Entity(
    tableName = "attendance_records",
    indices = [Index(value = ["local_date"], unique = true)],
)
data class AttendanceEntity(
    @PrimaryKey
    @ColumnInfo(name = "id")
    val id: String,

    @ColumnInfo(name = "marked_at_epoch_millis")
    val markedAtEpochMillis: Long,

    @ColumnInfo(name = "local_date")
    val localDate: String,

    @ColumnInfo(name = "latitude")
    val latitude: Double,

    @ColumnInfo(name = "longitude")
    val longitude: Double,

    @ColumnInfo(name = "distance_meters")
    val distanceMeters: Double,

    @ColumnInfo(name = "accuracy_meters")
    val accuracyMeters: Float,

    @ColumnInfo(name = "anchor_label")
    val anchorLabel: String,
)

/** Entity -> domain. Kept as extensions so neither layer imports the other's mapper. */
fun AttendanceEntity.toDomain(): AttendanceRecord = AttendanceRecord(
    id = id,
    markedAtEpochMillis = markedAtEpochMillis,
    point = GeoPoint(latitude, longitude),
    distanceMeters = distanceMeters,
    accuracyMeters = accuracyMeters,
    anchorLabel = anchorLabel,
)

/** Domain -> entity. [localDate] is supplied by the repository, which owns the clock. */
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
