package com.anchorage.perimeter.data.local.room

import androidx.room.Database
import androidx.room.RoomDatabase

@Database(
    entities = [AttendanceEntity::class],
    version = 1,
    exportSchema = false,
)
abstract class AnchorageDatabase : RoomDatabase() {

    abstract fun attendanceDao(): AttendanceDao

    companion object {
        const val NAME = "anchorage-perimeter.db"
    }
}
