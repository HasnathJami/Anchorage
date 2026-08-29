package com.anchorage.perimeter.presentation.attendance

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
import kotlinx.coroutines.flow.map
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * The ViewModel is tested against *real* use cases wired to fake ports, not
 * against mocked use cases.
 *
 * Mocking the use cases would prove only that the ViewModel calls them; wiring
 * the real ones proves the whole vertical slice - geofence rules, window
 * rules, hysteresis and state projection - agrees with itself. That is the
 * regression this suite actually needs to catch.
 */

val OFFICE = GeoPoint(23.780887, 90.414391)

/** ~22 m north of [OFFICE]. */
val NEAR = GeoPoint(OFFICE.latitude + 0.0002, OFFICE.longitude)

/** ~333 m north of [OFFICE]. */
val FAR = GeoPoint(OFFICE.latitude + 0.003, OFFICE.longitude)

fun officeAnchor(
    accuracyMeters: Float = 5f,
    point: GeoPoint = OFFICE,
) = OfficeAnchor(
    point = point,
    accuracyMeters = accuracyMeters,
    capturedAtEpochMillis = 1_756_000_000_000L,
)

fun fix(
    point: GeoPoint = NEAR,
    accuracyMeters: Float = 6f,
    isMock: Boolean = false,
) = LocationFix(
    point = point,
    accuracyMeters = accuracyMeters,
    timestampEpochMillis = 1_756_000_000_000L,
    isMock = isMock,
)

class FakeOfficeRepository(initial: OfficeAnchor? = null) : OfficeAnchorRepository {
    private val state = MutableStateFlow<Outcome<OfficeAnchor?>>(Outcome.Success(initial))

    var saveResult: Outcome<Unit> = Outcome.Success(Unit)

    fun emit(outcome: Outcome<OfficeAnchor?>) {
        state.value = outcome
    }

    override fun observe(): Flow<Outcome<OfficeAnchor?>> = state

    override suspend fun save(anchor: OfficeAnchor): Outcome<Unit> {
        if (saveResult is Outcome.Success) state.value = Outcome.Success(anchor)
        return saveResult
    }

    override suspend fun clear(): Outcome<Unit> {
        state.value = Outcome.Success(null)
        return Outcome.Success(Unit)
    }
}

class FakeAttendanceRepo(
    private val zone: ZoneId = ZoneId.of("Asia/Dhaka"),
) : AttendanceRepository {
    private val records = MutableStateFlow<List<AttendanceRecord>>(emptyList())

    /** Direct read for assertions; the interface only exposes flows. */
    val snapshot: List<AttendanceRecord> get() = records.value

    override fun observeHistory(): Flow<List<AttendanceRecord>> = records

    override fun observeRecordFor(date: LocalDate): Flow<AttendanceRecord?> =
        records.map { list -> list.firstOrNull { it.dateIn(zone) == date } }

    override suspend fun findRecordFor(date: LocalDate): Outcome<AttendanceRecord?> =
        Outcome.Success(records.value.firstOrNull { it.dateIn(zone) == date })

    override suspend fun append(record: AttendanceRecord): Outcome<AttendanceRecord> {
        records.value = listOf(record) + records.value
        return Outcome.Success(record)
    }

    private fun AttendanceRecord.dateIn(zone: ZoneId): LocalDate =
        Instant.ofEpochMilli(markedAtEpochMillis).atZone(zone).toLocalDate()
}

class FakeTracker : LocationTracker {
    private val updates = MutableSharedFlow<Outcome<LocationFix>>(replay = 1, extraBufferCapacity = 16)

    var currentFixResult: Outcome<LocationFix> = Outcome.Success(fix())

    suspend fun emit(outcome: Outcome<LocationFix>) = updates.emit(outcome)

    override fun stream(intervalMillis: Long): Flow<Outcome<LocationFix>> = updates

    override suspend fun currentFix(timeoutMillis: Long): Outcome<LocationFix> = currentFixResult
}

class MutableTimeProvider(
    var instant: Instant = Instant.parse("2026-08-28T03:30:00Z"),
    private val zoneId: ZoneId = ZoneId.of("Asia/Dhaka"),
) : TimeProvider {
    override fun nowEpochMillis(): Long = instant.toEpochMilli()
    override fun zone(): ZoneId = zoneId
    override fun localTime(): LocalTime = instant.atZone(zoneId).toLocalTime()
    override fun localDate(): LocalDate = instant.atZone(zoneId).toLocalDate()
}

class FixedIdGenerator(private val id: String = "record-1") : IdGenerator {
    override fun newId(): String = id
}
