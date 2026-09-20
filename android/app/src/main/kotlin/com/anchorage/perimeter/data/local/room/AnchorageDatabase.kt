package com.anchorage.perimeter.data.local.room

import androidx.room.Database
import androidx.room.RoomDatabase

/**
 * The app's SQLite database, defined for Room.
 *
 * One table only: attendance records. The office anchor lives in DataStore
 * instead, because it is a single small value that the UI needs to observe,
 * not a growing collection to query.
 *
 * ## No destructive migration fallback
 *
 * Room offers `fallbackToDestructiveMigration()`, which silently wipes the
 * database when the schema version changes. It is deliberately **not** used
 * here: losing someone's attendance history to a schema bump is a
 * data-integrity incident, not a convenience. A future version bump must ship
 * a real migration.
 *
 * `exportSchema = false` only because this assessment build has no migration
 * test suite to point the exported schema at; a production app would set it
 * true and commit the JSON.
 */
@Database(
    entities = [AttendanceEntity::class],
    version = 1,
    exportSchema = false,
)
abstract class AnchorageDatabase : RoomDatabase() {

    /** Room generates the implementation of this at build time. */
    abstract fun attendanceDao(): AttendanceDao

    companion object {
        /** The file name on disk, inside the app's private storage. */
        const val NAME = "anchorage-perimeter.db"
    }
}
