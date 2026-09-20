package com.anchorage.perimeter.data.local.room

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

/**
 * The SQL for the attendance table. Room writes the implementation; this file
 * is just the set of questions the app asks the database.
 *
 * A DAO method returning [Flow] is special: Room re-runs the query and
 * re-emits automatically whenever the table changes. That is why the history
 * screen updates the instant a check-in is written, with nothing telling it
 * to refresh.
 */
@Dao
interface AttendanceDao {

    /** Every record, newest first. Backs the history screen. */
    @Query("SELECT * FROM attendance_records ORDER BY marked_at_epoch_millis DESC")
    fun observeAll(): Flow<List<AttendanceEntity>>

    /**
     * Today's record, as a live stream.
     *
     * @param localDate An ISO `yyyy-MM-dd` string. The repository converts
     *   the timestamp into the user's local day before calling this.
     */
    @Query("SELECT * FROM attendance_records WHERE local_date = :localDate LIMIT 1")
    fun observeForDate(localDate: String): Flow<AttendanceEntity?>

    /**
     * The one-shot version of [observeForDate], used at the moment of
     * check-in to enforce the once-per-day rule.
     *
     * @param localDate An ISO `yyyy-MM-dd` string.
     */
    @Query("SELECT * FROM attendance_records WHERE local_date = :localDate LIMIT 1")
    suspend fun findForDate(localDate: String): AttendanceEntity?

    /**
     * Writes a record, failing if the day is already taken.
     *
     * **ABORT rather than REPLACE.** A duplicate check-in is a rule violation
     * the caller must learn about, not something to paper over by overwriting
     * the earlier — and more truthful — record. The repository catches the
     * resulting `SQLiteConstraintException` and turns it into
     * [com.anchorage.perimeter.core.common.error.AppError.Attendance.AlreadyMarked].
     */
    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(entity: AttendanceEntity)
}
