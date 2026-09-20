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
 * Connects the domain's [AttendanceRepository] port to the Room database.
 *
 * It has two jobs beyond simple delegation, and both are here for a reason.
 *
 * ## 1. It owns the "which calendar day is this?" conversion
 *
 * Records are stored with a UTC millisecond timestamp *and* a separate
 * `localDate` text column, because "today" is a local idea. A check-in at
 * 06:00 in Dhaka is on a different UTC date than the local one, and the
 * once-per-day rule must follow the user's calendar.
 *
 * That derivation lives here because it depends on the device time zone — a
 * detail the DAO has no business knowing, and one the domain should not have
 * to restate at every call site.
 *
 * ## 2. It degrades read failures instead of propagating them
 *
 * The read flows [catch] their errors into an empty list rather than
 * rethrowing. A corrupt history should degrade the history sheet, not take
 * down the attendance screen that happens to be collecting it.
 *
 * Writes do **not** get that treatment — a failed write is reported, because
 * the user needs to know their check-in did not happen.
 *
 * @param dao The Room data access object.
 * @param timeProvider Supplies the time zone for the date conversion.
 * @param dispatchers Which threads to run database work on.
 */
@Singleton
class AttendanceRepositoryImpl @Inject constructor(
    private val dao: AttendanceDao,
    private val timeProvider: TimeProvider,
    private val dispatchers: DispatcherProvider,
) : AttendanceRepository {

    override fun observeHistory(): Flow<List<AttendanceRecord>> = dao.observeAll()
        // Entity -> domain model. The rest of the app never sees a Room type.
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

    /**
     * Writes a record, converting its UTC timestamp into the local calendar
     * day the database indexes on.
     *
     * @param record The proof to store.
     * @return The record on success; [AppError.Attendance.AlreadyMarked] if
     *   the day was taken; [AppError.Storage.WriteFailed] otherwise.
     */
    override suspend fun append(record: AttendanceRecord): Outcome<AttendanceRecord> =
        withContext(dispatchers.io) {
            // Step 1 - which local day does this instant fall on?
            val localDate = Instant.ofEpochMilli(record.markedAtEpochMillis)
                .atZone(timeProvider.zone())
                .toLocalDate()

            try {
                // Step 2 - insert. The table has a unique index on the date
                // column, so the database itself is the final guard against a
                // duplicate check-in - not just the use case's check.
                dao.insert(record.toEntity(localDate.format(DATE_FORMATTER)))
                Outcome.Success(record)
            } catch (constraint: SQLiteConstraintException) {
                // Step 3 - the unique index fired: another path already
                // recorded today. Read back the existing record so the
                // message can name the time it was actually marked, rather
                // than just saying "already done".
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
        /**
         * ISO `yyyy-MM-dd`. Chosen because it sorts lexicographically in the
         * same order it sorts chronologically, which lets SQLite index and
         * compare the column as plain text.
         */
        val DATE_FORMATTER: DateTimeFormatter = DateTimeFormatter.ISO_LOCAL_DATE
    }
}
