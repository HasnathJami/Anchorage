package com.anchorage.perimeter.domain.fake

import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.LocationFix
import com.anchorage.perimeter.domain.model.OfficeAnchor
import com.anchorage.perimeter.domain.port.AttendanceRepository
import com.anchorage.perimeter.domain.port.IdGenerator
import com.anchorage.perimeter.domain.port.LocationTracker
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository
import com.anchorage.perimeter.domain.port.TimeProvider
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.map
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * Hand-written fakes rather than mocks.
 *
 * A mock asserts on *calls*; a fake lets the test assert on *behaviour*. For
 * repositories and streams the second reads far better and survives
 * refactoring, so Anchorage keeps MockK for one-off stubs and uses these for
 * anything stateful.
 */

/** Reference coordinate used across the suite: Gulshan-1 circle, Dhaka. */
val DHAKA_OFFICE = GeoPoint(latitude = 23.780887, longitude = 90.414391)

fun anchorAt(
    point: GeoPoint = DHAKA_OFFICE,
    accuracyMeters: Float = 6f,
    capturedAtEpochMillis: Long = 1_700_000_000_000L,
) = OfficeAnchor(point, accuracyMeters, capturedAtEpochMillis)

fun fixAt(
    point: GeoPoint = DHAKA_OFFICE,
    accuracyMeters: Float = 6f,
    timestampEpochMillis: Long = 1_700_000_000_000L,
) = LocationFix(point, accuracyMeters, timestampEpochMillis)

class FakeOfficeAnchorRepository(
    initial: OfficeAnchor? = null,
) : OfficeAnchorRepository {

    private val state = MutableStateFlow<Outcome<OfficeAnchor?>>(Outcome.Success(initial))

    var saveResult: Outcome<Unit> = Outcome.Success(Unit)
    var savedAnchors: MutableList<OfficeAnchor> = mutableListOf()
    var clearCount: Int = 0

    fun emit(outcome: Outcome<OfficeAnchor?>) {
        state.value = outcome
    }

    override fun observe(): Flow<Outcome<OfficeAnchor?>> = state

    override suspend fun save(anchor: OfficeAnchor): Outcome<Unit> {
        if (saveResult is Outcome.Success) {
            savedAnchors += anchor
            state.value = Outcome.Success(anchor)
        }
        return saveResult
    }

    override suspend fun clear(): Outcome<Unit> {
        clearCount++
        state.value = Outcome.Success(null)
        return Outcome.Success(Unit)
    }
}

class FakeAttendanceRepository(
    initial: List<AttendanceRecord> = emptyList(),
    private val zone: ZoneId = ZoneId.of("Asia/Dhaka"),
) : AttendanceRepository {

    private val records = MutableStateFlow(initial)

    var appendResult: ((AttendanceRecord) -> Outcome<AttendanceRecord>)? = null

    override fun observeHistory(): Flow<List<AttendanceRecord>> = records

    override fun observeRecordFor(date: LocalDate): Flow<AttendanceRecord?> =
        records.map { list -> list.firstOrNull { it.localDate() == date } }

    override suspend fun findRecordFor(date: LocalDate): Outcome<AttendanceRecord?> =
        Outcome.Success(records.value.firstOrNull { it.localDate() == date })

    override suspend fun append(record: AttendanceRecord): Outcome<AttendanceRecord> {
        appendResult?.let { return it(record) }
        records.value = listOf(record) + records.value
        return Outcome.Success(record)
    }

    private fun AttendanceRecord.localDate(): LocalDate =
        Instant.ofEpochMilli(markedAtEpochMillis).atZone(zone).toLocalDate()
}

class FakeLocationTracker(
    var currentFixResult: Outcome<LocationFix> = Outcome.Success(fixAt()),
) : LocationTracker {

    private val updates = MutableSharedFlow<Outcome<LocationFix>>(replay = 1, extraBufferCapacity = 16)

    var currentFixCallCount: Int = 0

    suspend fun emit(outcome: Outcome<LocationFix>) {
        updates.emit(outcome)
    }

    override fun stream(intervalMillis: Long): Flow<Outcome<LocationFix>> = updates.asSharedFlow()

    override suspend fun currentFix(timeoutMillis: Long): Outcome<LocationFix> {
        currentFixCallCount++
        return currentFixResult
    }
}

/** A clock frozen at a moment the test chooses. */
class FixedTimeProvider(
    var instant: Instant = Instant.parse("2026-08-28T03:30:00Z"),
    private val zoneId: ZoneId = ZoneId.of("Asia/Dhaka"),
) : TimeProvider {
    override fun nowEpochMillis(): Long = instant.toEpochMilli()
    override fun zone(): ZoneId = zoneId
    override fun localTime(): LocalTime = instant.atZone(zoneId).toLocalTime()
    override fun localDate(): LocalDate = instant.atZone(zoneId).toLocalDate()
}

class SequentialIdGenerator(private val prefix: String = "record-") : IdGenerator {
    private var counter = 0
    override fun newId(): String = prefix + (++counter)
}

/** Convenience for building a location error outcome in one expression. */
fun locationFailure(error: AppError.Location): Outcome<LocationFix> = Outcome.Failure(error)
