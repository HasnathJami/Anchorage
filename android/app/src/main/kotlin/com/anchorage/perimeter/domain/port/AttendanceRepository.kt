package com.anchorage.perimeter.domain.port

import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.AttendanceRecord
import kotlinx.coroutines.flow.Flow
import java.time.LocalDate

/** Append-only store of attendance proofs. */
interface AttendanceRepository {

    /** Newest first. */
    fun observeHistory(): Flow<List<AttendanceRecord>>

    /** The record for [date], or `null` - backs the once-per-day rule. */
    fun observeRecordFor(date: LocalDate): Flow<AttendanceRecord?>

    suspend fun findRecordFor(date: LocalDate): Outcome<AttendanceRecord?>

    suspend fun append(record: AttendanceRecord): Outcome<AttendanceRecord>
}
