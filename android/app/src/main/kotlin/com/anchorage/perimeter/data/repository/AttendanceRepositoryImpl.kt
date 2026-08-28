package com.anchorage.perimeter.data.repository

import android.database.sqlite.SQLiteConstraintException
import com.anchorage.perimeter.core.common.dispatcher.DispatcherProvider
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.data.local.room.AttendanceDao
import com.anchorage.perimeter.data.local.room.toDomain
import com.anchorage.perimeter.data.local.room.toEntity
import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.port.AttendanceRepository
import com.anchorage.perimeter.domain.port.TimeProvider
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Room-backed attendance log.
 *
 * The repository owns the calendar-date derivation because "which day is this
 * timestamp?" depends on the device time zone - a detail the DAO has no
 * business knowing and the domain should not have to restate at every call.
 *
 * Read flows [catch] their errors into an empty list rather than rethrowing:
 * a corrupt history should degrade the history sheet, not take down the
 * attendance screen that is collecting it.
 */
@Singleton
class AttendanceRepositoryImpl @Inject constructor(
    private val dao: AttendanceDao,
    private val timeProvider: TimeProvider,
    private val dispatchers: DispatcherProvider,
) : AttendanceRepository {

    override fun observeHistory(): Flow<List<AttendanceRecord>> = dao.observeAll()
        .map { entities -> entities.map { it.toDomain() } }
        .catch { emit(emptyList()) }

    override fun observeRecordFor(date: LocalDate): Flow<AttendanceRecord?> =
        dao.observeForDate(date.format(DATE_FORMATTER))
            .map { it?.toDomain() }
            .catch { emit(null) }

    override suspend fun findRecordFor(date: LocalDate): Outcome<AttendanceRecord?> =
        withContext(dispatchers.io) {
            try {
                Outcome.Success(dao.findForDate(date.format(DATE_FORMATTER))?.toDomain())
            } catch (throwable: Throwable) {
                Outcome.Failure(AppError.Storage.ReadFailed(throwable))
            }
        }

    override suspend fun append(record: AttendanceRecord): Outcome<AttendanceRecord> =
        withContext(dispatchers.io) {
            val localDate = Instant.ofEpochMilli(record.markedAtEpochMillis)
                .atZone(timeProvider.zone())
                .toLocalDate()

            try {
                dao.insert(record.toEntity(localDate.format(DATE_FORMATTER)))
                Outcome.Success(record)
            } catch (constraint: SQLiteConstraintException) {
                // The unique index fired: another path already recorded today.
                val existing = dao.findForDate(localDate.format(DATE_FORMATTER))
                Outcome.Failure(
                    AppError.Attendance.AlreadyMarked(
                        markedAtEpochMillis = existing?.markedAtEpochMillis
                            ?: record.markedAtEpochMillis,
                        cause = constraint,
                    ),
                )
            } catch (throwable: Throwable) {
                Outcome.Failure(AppError.Storage.WriteFailed(throwable))
            }
        }

    private companion object {
        val DATE_FORMATTER: DateTimeFormatter = DateTimeFormatter.ISO_LOCAL_DATE
    }
}
