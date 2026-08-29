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
import com.anchorage.perimeter.domain.policy.AttendanceWindow
import com.anchorage.perimeter.domain.policy.GeofenceEvaluator
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.anchorage.perimeter.domain.policy.ProximityStatus
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.time.Instant
import java.time.LocalTime

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
    fun `setting the office re-measures at once, without waiting for a new fix`() =
        runTest {
            // The behaviour the whole screen is judged on. GPS updates arrive
            // every few seconds; if the dial waited for the next one, pressing
            // "Set Office Location" would leave it reading "--" or, worse, the
            // distance to the *old* office, for as long as it took a satellite
            // to answer. The fix is carried forward precisely so the new
            // anchor can be measured against it immediately.
            useCase().test {
                awaitItem() // no office, no fix

                tracker.emit(Outcome.Success(fixAt(point = farPoint, accuracyMeters = 6f)))
                awaitItem() // a position, but still nowhere to measure it from

                officeRepository.emit(Outcome.Success(anchorAt()))

                val measured = awaitItem()
                assertThat(measured.reading).isNotNull()
                assertThat(measured.reading?.status).isEqualTo(ProximityStatus.OUTSIDE)
                cancelAndIgnoreRemainingEvents()
            }
        }

    @Test
    fun `moving the office re-measures from the same position`() = runTest {
        // Re-anchoring while standing still: the distance must be recomputed
        // against the new office rather than reported from a reading that was
        // an answer about the old one.
        officeRepository.emit(Outcome.Success(anchorAt(point = farPoint)))

        useCase().test {
            awaitItem()
            tracker.emit(Outcome.Success(fixAt(point = nearPoint, accuracyMeters = 6f)))

            val beforeMove = awaitItem()
            assertThat(beforeMove.reading?.status).isEqualTo(ProximityStatus.OUTSIDE)

            // The user presses "Set Office Location" where they are standing.
            officeRepository.emit(Outcome.Success(anchorAt(point = nearPoint)))

            val afterMove = awaitItem()
            assertThat(afterMove.reading?.status).isEqualTo(ProximityStatus.INSIDE)
            assertThat(afterMove.reading?.distanceMeters).isLessThan(1.0)
            assertThat(afterMove.canMarkAttendance).isTrue()
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
    fun `reports the fence it is actually enforcing, not the default`() = runTest {
        // The screen prints this number ("move within N metres"), so it must be
        // the same one the decision uses. In production the radius is a
        // property of the *site* and would arrive from a server - a 200 m
        // campus must not be described to the user as 50 m.
        val wideSite = ObserveAttendanceStatusUseCase(
            officeAnchorRepository = officeRepository,
            locationTracker = tracker,
            attendanceRepository = attendanceRepository,
            geofenceEvaluator = GeofenceEvaluator(
                HaversineDistanceCalculator,
                GeofencePolicy(radiusMeters = 200.0),
            ),
            timeProvider = time,
        )

        officeRepository.emit(Outcome.Success(anchorAt()))

        wideSite().test {
            val status = awaitItem()
            assertThat(status.radiusMeters).isEqualTo(200.0)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a fix beyond 50 m is inside a wider site`() = runTest {
        // The radius is not decoration: widening it changes the answer.
        val wideSite = ObserveAttendanceStatusUseCase(
            officeAnchorRepository = officeRepository,
            locationTracker = tracker,
            attendanceRepository = attendanceRepository,
            geofenceEvaluator = GeofenceEvaluator(
                HaversineDistanceCalculator,
                GeofencePolicy(radiusMeters = 500.0),
            ),
            timeProvider = time,
        )

        officeRepository.emit(Outcome.Success(anchorAt()))

        wideSite().test {
            awaitItem()
            tracker.emit(Outcome.Success(fixAt(point = farPoint, accuracyMeters = 5f)))

            val status = awaitItem()
            assertThat(status.reading?.status).isEqualTo(ProximityStatus.INSIDE)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `closes the gate outside the attendance window`() = runTest {
        // The shipped default now spans the whole day, so this builds a
        // use case with the reference design's morning window instead: a
        // gate that nothing can be outside of tests nothing.
        val narrowUseCase = ObserveAttendanceStatusUseCase(
            officeAnchorRepository = officeRepository,
            locationTracker = tracker,
            attendanceRepository = attendanceRepository,
            geofenceEvaluator = GeofenceEvaluator(HaversineDistanceCalculator),
            timeProvider = time,
            window = AttendanceWindow(
                opensAt = LocalTime.of(9, 0),
                closesAt = LocalTime.of(10, 30),
            ),
        )

        officeRepository.emit(Outcome.Success(anchorAt()))
        time.instant = Instant.parse("2026-08-28T10:00:00Z") // 16:00 Dhaka

        narrowUseCase().test {
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
