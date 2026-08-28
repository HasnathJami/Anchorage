package com.anchorage.perimeter.domain.usecase

import app.cash.turbine.test
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.fake.DHAKA_OFFICE
import com.anchorage.perimeter.domain.fake.FakeAttendanceRepository
import com.anchorage.perimeter.domain.fake.FakeLocationTracker
import com.anchorage.perimeter.domain.fake.FakeOfficeAnchorRepository
import com.anchorage.perimeter.domain.fake.FixedTimeProvider
import com.anchorage.perimeter.domain.fake.anchorAt
import com.anchorage.perimeter.domain.fake.fixAt
import com.anchorage.perimeter.domain.geo.HaversineDistanceCalculator
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.policy.GeofenceEvaluator
import com.anchorage.perimeter.domain.policy.ProximityStatus
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.time.Instant

class ObserveAttendanceStatusUseCaseTest {

    private val officeRepository = FakeOfficeAnchorRepository()
    private val attendanceRepository = FakeAttendanceRepository()
    private val tracker = FakeLocationTracker()
    private val time = FixedTimeProvider(instant = Instant.parse("2026-08-28T03:30:00Z"))

    private val useCase = ObserveAttendanceStatusUseCase(
        officeAnchorRepository = officeRepository,
        locationTracker = tracker,
        attendanceRepository = attendanceRepository,
        geofenceEvaluator = GeofenceEvaluator(HaversineDistanceCalculator),
        timeProvider = time,
    )

    private val nearPoint = GeoPoint(DHAKA_OFFICE.latitude + 0.0002, DHAKA_OFFICE.longitude)
    private val farPoint = GeoPoint(DHAKA_OFFICE.latitude + 0.003, DHAKA_OFFICE.longitude)

    @Test
    fun `emits immediately without waiting for the first GPS fix`() = runTest {
        useCase().test {
            val first = awaitItem()

            assertThat(first.anchor).isNull()
            assertThat(first.reading).isNull()
            assertThat(first.isWindowOpen).isTrue()
            assertThat(first.canMarkAttendance).isFalse()
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `permits check-in once an anchor and a close trusted fix are present`() = runTest {
        officeRepository.emit(Outcome.Success(anchorAt()))

        useCase().test {
            awaitItem() // seeded emission, no fix yet
            tracker.emit(Outcome.Success(fixAt(point = nearPoint, accuracyMeters = 6f)))

            val status = awaitItem()
            assertThat(status.reading?.status).isEqualTo(ProximityStatus.INSIDE)
            assertThat(status.canMarkAttendance).isTrue()
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `keeps the last known reading when a fix fails mid-stream`() = runTest {
        officeRepository.emit(Outcome.Success(anchorAt()))

        useCase().test {
            awaitItem()
            tracker.emit(Outcome.Success(fixAt(point = farPoint, accuracyMeters = 6f)))
            val withFix = awaitItem()
            assertThat(withFix.reading).isNotNull()

            tracker.emit(Outcome.Failure(AppError.Location.PositionUnavailable()))
            val afterFailure = awaitItem()

            assertThat(afterFailure.locationError)
                .isInstanceOf(AppError.Location.PositionUnavailable::class.java)
            // The distance the user last saw is preserved rather than blanked.
            assertThat(afterFailure.reading?.distanceMeters)
                .isEqualTo(withFix.reading?.distanceMeters)
            assertThat(afterFailure.canMarkAttendance).isFalse()
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `applies exit hysteresis across successive emissions`() = runTest {
        officeRepository.emit(Outcome.Success(anchorAt()))
        // ~55 m north: past the 50 m entry threshold, inside the 58 m exit one.
        val fiftyFive = GeoPoint(DHAKA_OFFICE.latitude + 0.000495, DHAKA_OFFICE.longitude)

        useCase().test {
            awaitItem()

            tracker.emit(Outcome.Success(fixAt(point = nearPoint, accuracyMeters = 5f)))
            assertThat(awaitItem().reading?.status).isEqualTo(ProximityStatus.INSIDE)

            tracker.emit(Outcome.Success(fixAt(point = fiftyFive, accuracyMeters = 5f)))
            assertThat(awaitItem().reading?.status).isEqualTo(ProximityStatus.INSIDE)

            tracker.emit(Outcome.Success(fixAt(point = farPoint, accuracyMeters = 5f)))
            assertThat(awaitItem().reading?.status).isEqualTo(ProximityStatus.OUTSIDE)

            // Now that we are outside, 55 m must no longer count as inside.
            tracker.emit(Outcome.Success(fixAt(point = fiftyFive, accuracyMeters = 5f)))
            assertThat(awaitItem().reading?.status).isEqualTo(ProximityStatus.OUTSIDE)

            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `closes the gate outside the attendance window`() = runTest {
        officeRepository.emit(Outcome.Success(anchorAt()))
        time.instant = Instant.parse("2026-08-28T10:00:00Z") // 16:00 Dhaka

        useCase().test {
            awaitItem()
            tracker.emit(Outcome.Success(fixAt(point = nearPoint, accuracyMeters = 5f)))

            val status = awaitItem()
            assertThat(status.isWindowOpen).isFalse()
            assertThat(status.canMarkAttendance).isFalse()
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `reports a storage failure without crashing the stream`() = runTest {
        useCase().test {
            awaitItem()
            officeRepository.emit(Outcome.Failure(AppError.Storage.ReadFailed()))

            val status = awaitItem()
            assertThat(status.storageError).isInstanceOf(AppError.Storage.ReadFailed::class.java)
            assertThat(status.anchor).isNull()
            cancelAndIgnoreRemainingEvents()
        }
    }
}
