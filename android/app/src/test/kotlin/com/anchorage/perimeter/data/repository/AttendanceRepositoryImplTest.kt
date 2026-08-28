package com.anchorage.perimeter.data.repository

import android.database.sqlite.SQLiteConstraintException
import com.anchorage.perimeter.core.common.dispatcher.DispatcherProvider
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.data.local.room.AttendanceDao
import com.anchorage.perimeter.data.local.room.AttendanceEntity
import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.port.TimeProvider
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * The time-zone behaviour here is the interesting part: "which day is this?"
 * must be answered in the user's local calendar, not UTC, or a 2 a.m. check-in
 * in Dhaka would be filed against the previous day.
 */
class AttendanceRepositoryImplTest {

    private val zone: ZoneId = ZoneId.of("Asia/Dhaka")

    private class InMemoryDao : AttendanceDao {
        val rows = MutableStateFlow<List<AttendanceEntity>>(emptyList())
        var insertFailure: Throwable? = null

        override fun observeAll(): Flow<List<AttendanceEntity>> = rows

        override fun observeForDate(localDate: String): Flow<AttendanceEntity?> =
            rows.map { list -> list.firstOrNull { it.localDate == localDate } }

        override suspend fun findForDate(localDate: String): AttendanceEntity? =
            rows.value.firstOrNull { it.localDate == localDate }

        override suspend fun insert(entity: AttendanceEntity) {
            insertFailure?.let { throw it }
            rows.value = listOf(entity) + rows.value
        }
    }

    private inner class FrozenTime(private val instant: Instant) : TimeProvider {
        override fun nowEpochMillis(): Long = instant.toEpochMilli()
        override fun zone(): ZoneId = zone
        override fun localTime(): LocalTime = instant.atZone(zone).toLocalTime()
        override fun localDate(): LocalDate = instant.atZone(zone).toLocalDate()
    }

    private val dispatcher = StandardTestDispatcher()
    private val dispatchers = object : DispatcherProvider {
        override val main = dispatcher
        override val io = dispatcher
        override val default = dispatcher
    }

    private val dao = InMemoryDao()
    private val time = FrozenTime(Instant.parse("2026-08-28T03:30:00Z"))
    private val repository = AttendanceRepositoryImpl(dao, time, dispatchers)

    private val record = AttendanceRecord(
        id = "abc",
        markedAtEpochMillis = Instant.parse("2026-08-28T03:30:00Z").toEpochMilli(),
        point = GeoPoint(23.780887, 90.414391),
        distanceMeters = 12.5,
        accuracyMeters = 6f,
        anchorLabel = "Head Office",
    )

    @Test
    fun `append stores the record under its local calendar date`() = runTest(dispatcher) {
        assertThat(repository.append(record)).isEqualTo(Outcome.Success(record))

        // 03:30 UTC is 09:30 in Dhaka - the same calendar day.
        assertThat(dao.rows.value.single().localDate).isEqualTo("2026-08-28")
    }

    @Test
    fun `a timestamp before the UTC date boundary still lands on the local day`() =
        runTest(dispatcher) {
            // 20:00 UTC on the 27th is 02:00 on the 28th in Dhaka.
            val lateNight = record.copy(
                markedAtEpochMillis = Instant.parse("2026-08-27T20:00:00Z").toEpochMilli(),
            )

            repository.append(lateNight)

            assertThat(dao.rows.value.single().localDate).isEqualTo("2026-08-28")
        }

    @Test
    fun `a unique-index violation is reported as already marked`() = runTest(dispatcher) {
        repository.append(record)
        dao.insertFailure = SQLiteConstraintException("UNIQUE constraint failed")

        val result = repository.append(record.copy(id = "second"))

        val error = (result as Outcome.Failure).error
        assertThat(error).isInstanceOf(AppError.Attendance.AlreadyMarked::class.java)
        assertThat((error as AppError.Attendance.AlreadyMarked).markedAtEpochMillis)
            .isEqualTo(record.markedAtEpochMillis)
    }

    @Test
    fun `an unexpected write failure is reported as a storage failure`() = runTest(dispatcher) {
        dao.insertFailure = IllegalStateException("disk full")

        val result = repository.append(record)

        assertThat((result as Outcome.Failure).error)
            .isInstanceOf(AppError.Storage.WriteFailed::class.java)
    }

    @Test
    fun `history maps entities to domain records`() = runTest(dispatcher) {
        repository.append(record)

        val history = repository.observeHistory().first()

        assertThat(history).hasSize(1)
        assertThat(history.single().id).isEqualTo("abc")
        assertThat(history.single().point).isEqualTo(record.point)
    }

    @Test
    fun `findRecordFor returns the record for that day and null otherwise`() = runTest(dispatcher) {
        repository.append(record)

        assertThat((repository.findRecordFor(LocalDate.of(2026, 8, 28)) as Outcome.Success).value)
            .isNotNull()
        assertThat((repository.findRecordFor(LocalDate.of(2026, 8, 29)) as Outcome.Success).value)
            .isNull()
    }
}
