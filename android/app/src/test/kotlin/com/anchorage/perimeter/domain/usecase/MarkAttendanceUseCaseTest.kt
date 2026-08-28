package com.anchorage.perimeter.domain.usecase

import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.fake.DHAKA_OFFICE
import com.anchorage.perimeter.domain.fake.FakeAttendanceRepository
import com.anchorage.perimeter.domain.fake.FakeLocationTracker
import com.anchorage.perimeter.domain.fake.FakeOfficeAnchorRepository
import com.anchorage.perimeter.domain.fake.FixedTimeProvider
import com.anchorage.perimeter.domain.fake.SequentialIdGenerator
import com.anchorage.perimeter.domain.fake.anchorAt
import com.anchorage.perimeter.domain.fake.fixAt
import com.anchorage.perimeter.domain.geo.HaversineDistanceCalculator
import com.anchorage.perimeter.domain.model.AttendanceRecord
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.policy.GeofenceEvaluator
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.time.Instant

/**
 * The gate that actually decides whether someone is present. Every rejection
 * path is asserted, because each one has a distinct message in the UI and a
 * silent regression here is invisible until someone is wrongly marked absent.
 */
class MarkAttendanceUseCaseTest {

    // 09:30 Asia/Dhaka - comfortably inside the default window.
    private val insideWindow = Instant.parse("2026-08-28T03:30:00Z")

    private val officeRepository = FakeOfficeAnchorRepository(initial = anchorAt())
    private val attendanceRepository = FakeAttendanceRepository()
    private val tracker = FakeLocationTracker()
    private val time = FixedTimeProvider(instant = insideWindow)

    private fun useCase(policy: GeofencePolicy = GeofencePolicy.Default) = MarkAttendanceUseCase(
        officeAnchorRepository = officeRepository,
        attendanceRepository = attendanceRepository,
        locationTracker = tracker,
        geofenceEvaluator = GeofenceEvaluator(HaversineDistanceCalculator, policy),
        timeProvider = time,
        idGenerator = SequentialIdGenerator(),
    )

    /** ~22 m north of the anchor. */
    private val nearPoint = GeoPoint(DHAKA_OFFICE.latitude + 0.0002, DHAKA_OFFICE.longitude)

    /** ~333 m north of the anchor. */
    private val farPoint = GeoPoint(DHAKA_OFFICE.latitude + 0.003, DHAKA_OFFICE.longitude)

    @Test
    fun `records attendance when every gate is open`() = runTest {
        tracker.currentFixResult = Outcome.Success(fixAt(point = nearPoint, accuracyMeters = 7f))

        val result = useCase()()

        assertThat(result).isInstanceOf(Outcome.Success::class.java)
        val record = (result as Outcome.Success).value
        assertThat(record.id).isEqualTo("record-1")
        assertThat(record.markedAtEpochMillis).isEqualTo(insideWindow.toEpochMilli())
        assertThat(record.distanceMeters).isWithin(3.0).of(22.2)
        assertThat(record.accuracyMeters).isEqualTo(7f)
    }

    @Test
    fun `rejects before touching GPS when the window is closed`() = runTest {
        time.instant = Instant.parse("2026-08-28T10:00:00Z") // 16:00 Dhaka

        val result = useCase()()

        assertThat((result as Outcome.Failure).error)
            .isInstanceOf(AppError.Attendance.WindowClosed::class.java)
        assertThat(tracker.currentFixCallCount).isEqualTo(0)
    }

    @Test
    fun `rejects before touching GPS when no office has been configured`() = runTest {
        officeRepository.emit(Outcome.Success(null))

        val result = useCase()()

        assertThat((result as Outcome.Failure).error)
            .isInstanceOf(AppError.Attendance.OfficeNotConfigured::class.java)
        assertThat(tracker.currentFixCallCount).isEqualTo(0)
    }

    @Test
    fun `rejects a second check-in on the same day`() = runTest {
        val existing = AttendanceRecord(
            id = "earlier",
            markedAtEpochMillis = Instant.parse("2026-08-28T03:05:00Z").toEpochMilli(),
            point = DHAKA_OFFICE,
            distanceMeters = 4.0,
            accuracyMeters = 5f,
            anchorLabel = "Head Office",
        )
        val repository = FakeAttendanceRepository(initial = listOf(existing))
        val subject = MarkAttendanceUseCase(
            officeAnchorRepository = officeRepository,
            attendanceRepository = repository,
            locationTracker = tracker,
            geofenceEvaluator = GeofenceEvaluator(HaversineDistanceCalculator),
            timeProvider = time,
            idGenerator = SequentialIdGenerator(),
        )

        val result = subject()

        val error = (result as Outcome.Failure).error
        assertThat(error).isInstanceOf(AppError.Attendance.AlreadyMarked::class.java)
        assertThat((error as AppError.Attendance.AlreadyMarked).markedAtEpochMillis)
            .isEqualTo(existing.markedAtEpochMillis)
        assertThat(tracker.currentFixCallCount).isEqualTo(0)
    }

    @Test
    fun `rejects and reports the distance when the user is outside the fence`() = runTest {
        tracker.currentFixResult = Outcome.Success(fixAt(point = farPoint, accuracyMeters = 6f))

        val result = useCase()()

        val error = (result as Outcome.Failure).error
        assertThat(error).isInstanceOf(AppError.Attendance.OutsideGeofence::class.java)
        with(error as AppError.Attendance.OutsideGeofence) {
            assertThat(distanceMeters).isWithin(5.0).of(333.6)
            assertThat(radiusMeters).isEqualTo(50.0)
        }
    }

    @Test
    fun `rejects a fix too imprecise to trust even when it looks close`() = runTest {
        tracker.currentFixResult = Outcome.Success(fixAt(point = nearPoint, accuracyMeters = 400f))

        val result = useCase()()

        assertThat((result as Outcome.Failure).error)
            .isInstanceOf(AppError.Location.InsufficientAccuracy::class.java)
    }

    @Test
    fun `propagates a permission failure from the tracker`() = runTest {
        tracker.currentFixResult = Outcome.Failure(AppError.Location.PermissionDenied())

        val result = useCase()()

        assertThat((result as Outcome.Failure).error)
            .isInstanceOf(AppError.Location.PermissionDenied::class.java)
    }

    @Test
    fun `surfaces a storage failure instead of pretending the check-in landed`() = runTest {
        tracker.currentFixResult = Outcome.Success(fixAt(point = nearPoint, accuracyMeters = 7f))
        attendanceRepository.appendResult = { Outcome.Failure(AppError.Storage.WriteFailed()) }

        val result = useCase()()

        assertThat((result as Outcome.Failure).error)
            .isInstanceOf(AppError.Storage.WriteFailed::class.java)
    }

    @Test
    fun `hysteresis is not applied to the authoritative decision`() = runTest {
        // 55 m out: the live dial may still read INSIDE thanks to hysteresis,
        // but the check-in itself must judge against the true 50 m radius.
        val fiftyFiveMetres = GeoPoint(DHAKA_OFFICE.latitude + 0.000495, DHAKA_OFFICE.longitude)
        tracker.currentFixResult = Outcome.Success(fixAt(point = fiftyFiveMetres, accuracyMeters = 5f))

        val result = useCase()()

        assertThat((result as Outcome.Failure).error)
            .isInstanceOf(AppError.Attendance.OutsideGeofence::class.java)
    }
}
