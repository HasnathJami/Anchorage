package com.anchorage.perimeter.domain.usecase

import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.fake.DHAKA_OFFICE
import com.anchorage.perimeter.domain.fake.FakeLocationTracker
import com.anchorage.perimeter.domain.fake.FakeOfficeAnchorRepository
import com.anchorage.perimeter.domain.fake.fixAt
import com.anchorage.perimeter.domain.geo.HaversineDistanceCalculator
import com.anchorage.perimeter.domain.policy.GeofenceEvaluator
import com.anchorage.perimeter.domain.policy.GeofencePolicy
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.Test

class CaptureOfficeAnchorUseCaseTest {

    private val policy = GeofencePolicy.Default
    private val tracker = FakeLocationTracker()
    private val repository = FakeOfficeAnchorRepository()
    private val useCase = CaptureOfficeAnchorUseCase(
        locationTracker = tracker,
        officeAnchorRepository = repository,
        geofenceEvaluator = GeofenceEvaluator(HaversineDistanceCalculator, policy),
        policy = policy,
    )

    @Test
    fun `persists the anchor when the fix is precise enough`() = runTest {
        tracker.currentFixResult = Outcome.Success(
            fixAt(point = DHAKA_OFFICE, accuracyMeters = 5f, timestampEpochMillis = 42L),
        )

        val result = useCase(label = "HQ")

        assertThat(result).isInstanceOf(Outcome.Success::class.java)
        val anchor = (result as Outcome.Success).value
        assertThat(anchor.point).isEqualTo(DHAKA_OFFICE)
        assertThat(anchor.accuracyMeters).isEqualTo(5f)
        assertThat(anchor.capturedAtEpochMillis).isEqualTo(42L)
        assertThat(anchor.label).isEqualTo("HQ")
        assertThat(repository.savedAnchors).containsExactly(anchor)
    }

    @Test
    fun `refuses to anchor on an imprecise fix and persists nothing`() = runTest {
        tracker.currentFixResult = Outcome.Success(fixAt(accuracyMeters = 120f))

        val result = useCase()

        val error = (result as Outcome.Failure).error
        assertThat(error).isInstanceOf(AppError.Location.InsufficientAccuracy::class.java)
        with(error as AppError.Location.InsufficientAccuracy) {
            assertThat(reportedAccuracyMeters).isEqualTo(120f)
            assertThat(requiredAccuracyMeters).isEqualTo(policy.maxAnchorAccuracyMeters)
        }
        assertThat(repository.savedAnchors).isEmpty()
    }

    @Test
    fun `propagates a location failure untouched`() = runTest {
        tracker.currentFixResult = Outcome.Failure(AppError.Location.ServicesDisabled())

        val result = useCase()

        assertThat((result as Outcome.Failure).error)
            .isInstanceOf(AppError.Location.ServicesDisabled::class.java)
        assertThat(repository.savedAnchors).isEmpty()
    }

    @Test
    fun `surfaces a storage failure rather than reporting a phantom success`() = runTest {
        tracker.currentFixResult = Outcome.Success(fixAt(accuracyMeters = 5f))
        repository.saveResult = Outcome.Failure(AppError.Storage.WriteFailed())

        val result = useCase()

        assertThat((result as Outcome.Failure).error)
            .isInstanceOf(AppError.Storage.WriteFailed::class.java)
    }

    @Test
    fun `boundary accuracy is accepted`() = runTest {
        tracker.currentFixResult = Outcome.Success(
            fixAt(accuracyMeters = policy.maxAnchorAccuracyMeters),
        )

        assertThat(useCase()).isInstanceOf(Outcome.Success::class.java)
    }
}
