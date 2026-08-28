package com.anchorage.perimeter.data.local.room

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface AttendanceDao {

    @Query("SELECT * FROM attendance_records ORDER BY marked_at_epoch_millis DESC")
    fun observeAll(): Flow<List<AttendanceEntity>>

    @Query("SELECT * FROM attendance_records WHERE local_date = :localDate LIMIT 1")
    fun observeForDate(localDate: String): Flow<AttendanceEntity?>

    @Query("SELECT * FROM attendance_records WHERE local_date = :localDate LIMIT 1")
    suspend fun findForDate(localDate: String): AttendanceEntity?

    /**
     * ABORT rather than REPLACE: a duplicate check-in is a rule violation the
     * caller must learn about, not something to paper over by overwriting the
     * earlier - and more truthful - record.
     */
    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(entity: AttendanceEntity)
}
