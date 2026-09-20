package com.anchorage.perimeter.domain.port

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.AttendanceRecord
import kotlinx.coroutines.flow.Flow
import java.time.LocalDate

/**
 * The append-only store of attendance proofs.
 *
 * "Append-only" is the important word: there is no `update` and no `delete`.
 * A record, once written, is permanent. Implemented by
 * [com.anchorage.perimeter.data.repository.AttendanceRepositoryImpl] on top
 * of Room.
 */
interface AttendanceRepository {

    /**
     * The full history, newest first, re-emitted whenever a record is added.
     *
     * Drives the history screen, and also feeds
     * [com.anchorage.perimeter.domain.usecase.ObserveAttendanceStatusUseCase]
     * so the attendance screen knows whether today is already marked.
     */
    fun observeHistory(): Flow<List<AttendanceRecord>>

    /**
     * The record for one particular day, or `null` if that day is unmarked.
     *
     * @param date The local calendar day to look up.
     */
    fun observeRecordFor(date: LocalDate): Flow<AttendanceRecord?>

    /**
     * A one-shot version of [observeRecordFor], used by
     * [com.anchorage.perimeter.domain.usecase.MarkAttendanceUseCase] to
     * enforce the once-per-day rule at the moment of check-in.
     *
     * @param date The local calendar day to look up.
     * @return `Outcome.Success(null)` when the day is unmarked.
     */
    suspend fun findRecordFor(date: LocalDate): Outcome<AttendanceRecord?>

    /**
     * Writes a new record.
     *
     * The underlying table rejects a second record for the same day rather
     * than overwriting the first — a duplicate check-in is a violation to
     * report, not to silently absorb.
     *
     * @param record The proof to store.
     * @return The stored record, or a
     *   [com.anchorage.perimeter.core.common.error.AppError.Storage] failure.
     */
    suspend fun append(record: AttendanceRecord): Outcome<AttendanceRecord>
}
