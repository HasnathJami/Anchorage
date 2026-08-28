package com.anchorage.perimeter.presentation.attendance

import app.cash.turbine.test
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.geo.HaversineDistanceCalculator
import com.anchorage.perimeter.domain.policy.GeofenceEvaluator
import com.anchorage.perimeter.domain.usecase.CaptureOfficeAnchorUseCase
import com.anchorage.perimeter.domain.usecase.ClearOfficeAnchorUseCase
import com.anchorage.perimeter.domain.usecase.MarkAttendanceUseCase
import com.anchorage.perimeter.domain.usecase.ObserveAttendanceStatusUseCase
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.time.Instant

@OptIn(ExperimentalCoroutinesApi::class)
class AttendanceViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    private lateinit var officeRepository: FakeOfficeRepository
    private lateinit var attendanceRepository: FakeAttendanceRepo
    private lateinit var tracker: FakeTracker
    private lateinit var time: MutableTimeProvider
    private lateinit var viewModel: AttendanceViewModel

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        officeRepository = FakeOfficeRepository()
        attendanceRepository = FakeAttendanceRepo()
        tracker = FakeTracker()
        time = MutableTimeProvider()
        viewModel = buildViewModel()
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun buildViewModel(): AttendanceViewModel {
        val evaluator = GeofenceEvaluator(HaversineDistanceCalculator)
        return AttendanceViewModel(
            observeAttendanceStatus = ObserveAttendanceStatusUseCase(
                officeAnchorRepository = officeRepository,
                locationTracker = tracker,
                attendanceRepository = attendanceRepository,
                geofenceEvaluator = evaluator,
                timeProvider = time,
            ),
            captureOfficeAnchor = CaptureOfficeAnchorUseCase(
                locationTracker = tracker,
                officeAnchorRepository = officeRepository,
                geofenceEvaluator = evaluator,
            ),
            markAttendance = MarkAttendanceUseCase(
                officeAnchorRepository = officeRepository,
                attendanceRepository = attendanceRepository,
                locationTracker = tracker,
                geofenceEvaluator = evaluator,
                timeProvider = time,
                idGenerator = FixedIdGenerator(),
            ),
            clearOfficeAnchor = ClearOfficeAnchorUseCase(officeRepository),
        )
    }

    private fun grantPermission() {
        viewModel.onIntent(AttendanceIntent.PermissionStateChanged(granted = true))
    }

    // ------------------------------------------------------------- permissions

    @Test
    fun `starts with the permission banner and no observation`() = runTest(dispatcher) {
        viewModel.onIntent(AttendanceIntent.PermissionStateChanged(granted = false))
        advanceUntilIdle()

        val state = viewModel.uiState.value
        assertThat(state.notice).isEqualTo(AttendanceNotice.PermissionRequired)
        assertThat(state.isBootstrapping).isFalse()
        assertThat(state.canMarkAttendance).isFalse()
    }

    @Test
    fun `a hard denial escalates the banner to blocked`() = runTest(dispatcher) {
        viewModel.onIntent(
            AttendanceIntent.PermissionResult(granted = false, canAskAgain = false),
        )
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.notice).isEqualTo(AttendanceNotice.PermissionBlocked)
    }

    @Test
    fun `granting permission clears the banner and starts observing`() = runTest(dispatcher) {
        viewModel.onIntent(AttendanceIntent.PermissionStateChanged(granted = false))
        advanceUntilIdle()

        grantPermission()
        officeRepository.emit(Outcome.Success(officeAnchor()))
        tracker.emit(Outcome.Success(fix(point = NEAR)))
        advanceUntilIdle()

        val state = viewModel.uiState.value
        assertThat(state.notice).isNull()
        assertThat(state.reading).isNotNull()
    }

    @Test
    fun `tapping the blocked banner asks the screen to open settings`() = runTest(dispatcher) {
        viewModel.onIntent(
            AttendanceIntent.PermissionResult(granted = false, canAskAgain = false),
        )
        advanceUntilIdle()

        viewModel.effects.test {
            viewModel.onIntent(AttendanceIntent.NoticeActionClicked)
            advanceUntilIdle()

            assertThat(awaitItem()).isEqualTo(AttendanceEffect.OpenAppSettings)
            cancelAndIgnoreRemainingEvents()
        }
    }

    // ------------------------------------------------------------- projection

    @Test
    fun `projects an in-range reading and unlocks the button`() = runTest(dispatcher) {
        grantPermission()
        officeRepository.emit(Outcome.Success(officeAnchor()))
        tracker.emit(Outcome.Success(fix(point = NEAR)))
        advanceUntilIdle()

        val state = viewModel.uiState.value
        assertThat(state.proximity).isEqualTo(ProximityUi.InRange)
        assertThat(state.canMarkAttendance).isTrue()
        assertThat(state.windowLabel).isEqualTo("09:00 AM - 10:30 AM")
    }

    @Test
    fun `projects an out-of-range reading and keeps the button locked`() = runTest(dispatcher) {
        grantPermission()
        officeRepository.emit(Outcome.Success(officeAnchor()))
        tracker.emit(Outcome.Success(fix(point = FAR)))
        advanceUntilIdle()

        val state = viewModel.uiState.value
        assertThat(state.proximity).isEqualTo(ProximityUi.OutOfRange)
        assertThat(state.canMarkAttendance).isFalse()
        assertThat(state.reading?.distanceMeters).isWithin(5.0).of(333.6)
    }

    @Test
    fun `a wide error radius is reported as low confidence, not as out of range`() =
        runTest(dispatcher) {
            grantPermission()
            officeRepository.emit(Outcome.Success(officeAnchor()))
            tracker.emit(Outcome.Success(fix(point = NEAR, accuracyMeters = 300f)))
            advanceUntilIdle()

            val state = viewModel.uiState.value
            assertThat(state.proximity).isEqualTo(ProximityUi.LowConfidence)
            assertThat(state.canMarkAttendance).isFalse()
        }

    @Test
    fun `a mock provider raises a notice but does not lock the button`() = runTest(dispatcher) {
        grantPermission()
        officeRepository.emit(Outcome.Success(officeAnchor()))
        tracker.emit(Outcome.Success(fix(point = NEAR, isMock = true)))
        advanceUntilIdle()

        val state = viewModel.uiState.value
        assertThat(state.notice).isEqualTo(AttendanceNotice.MockLocationActive)
        assertThat(state.canMarkAttendance).isTrue()
    }

    @Test
    fun `a services-disabled stream error surfaces the matching banner`() = runTest(dispatcher) {
        grantPermission()
        tracker.emit(Outcome.Failure(AppError.Location.ServicesDisabled()))
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.notice).isEqualTo(AttendanceNotice.LocationServicesOff)
    }

    @Test
    fun `the window closing locks the button even while in range`() = runTest(dispatcher) {
        grantPermission()
        officeRepository.emit(Outcome.Success(officeAnchor()))
        time.instant = Instant.parse("2026-08-28T10:00:00Z") // 16:00 Dhaka
        tracker.emit(Outcome.Success(fix(point = NEAR)))
        advanceUntilIdle()

        val state = viewModel.uiState.value
        assertThat(state.proximity).isEqualTo(ProximityUi.InRange)
        assertThat(state.isWindowOpen).isFalse()
        assertThat(state.canMarkAttendance).isFalse()
    }

    // ---------------------------------------------------------------- actions

    @Test
    fun `anchoring the office emits a confirmation and clears the spinner`() = runTest(dispatcher) {
        grantPermission()
        tracker.currentFixResult = Outcome.Success(fix(point = OFFICE, accuracyMeters = 4f))

        viewModel.effects.test {
            viewModel.onIntent(AttendanceIntent.SetOfficeLocationClicked)
            advanceUntilIdle()

            assertThat(awaitItem()).isEqualTo(AttendanceEffect.OfficeAnchored(4f))
            assertThat(viewModel.uiState.value.isCapturingOffice).isFalse()
            assertThat(viewModel.uiState.value.anchor).isNotNull()
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a coarse fix is refused with an explanatory banner and nothing is saved`() =
        runTest(dispatcher) {
            grantPermission()
            tracker.currentFixResult = Outcome.Success(fix(point = OFFICE, accuracyMeters = 90f))

            viewModel.onIntent(AttendanceIntent.SetOfficeLocationClicked)
            advanceUntilIdle()

            val notice = viewModel.uiState.value.notice
            assertThat(notice).isInstanceOf(AttendanceNotice.AnchorRejected::class.java)
            assertThat((notice as AttendanceNotice.AnchorRejected).reportedAccuracyMeters)
                .isEqualTo(90f)
            assertThat(viewModel.uiState.value.anchor).isNull()
        }

    @Test
    fun `setting the office without permission asks for permission instead`() = runTest(dispatcher) {
        viewModel.onIntent(AttendanceIntent.PermissionStateChanged(granted = false))
        advanceUntilIdle()

        viewModel.effects.test {
            viewModel.onIntent(AttendanceIntent.SetOfficeLocationClicked)
            advanceUntilIdle()

            assertThat(awaitItem()).isEqualTo(AttendanceEffect.RequestLocationPermission)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `marking attendance in range emits the record`() = runTest(dispatcher) {
        grantPermission()
        officeRepository.emit(Outcome.Success(officeAnchor()))
        tracker.currentFixResult = Outcome.Success(fix(point = NEAR))
        tracker.emit(Outcome.Success(fix(point = NEAR)))
        advanceUntilIdle()

        viewModel.effects.test {
            viewModel.onIntent(AttendanceIntent.MarkAttendanceClicked)
            advanceUntilIdle()

            val effect = awaitItem()
            assertThat(effect).isInstanceOf(AttendanceEffect.AttendanceMarked::class.java)
            assertThat((effect as AttendanceEffect.AttendanceMarked).record.id).isEqualTo("record-1")
            cancelAndIgnoreRemainingEvents()
        }

        advanceUntilIdle()
        assertThat(viewModel.uiState.value.isAlreadyMarkedToday).isTrue()
        assertThat(viewModel.uiState.value.canMarkAttendance).isFalse()
    }

    @Test
    fun `walking out of range between render and tap is rejected with a message`() =
        runTest(dispatcher) {
            grantPermission()
            officeRepository.emit(Outcome.Success(officeAnchor()))
            tracker.emit(Outcome.Success(fix(point = NEAR)))
            advanceUntilIdle()
            assertThat(viewModel.uiState.value.canMarkAttendance).isTrue()

            // The authoritative fix taken at tap time says otherwise.
            tracker.currentFixResult = Outcome.Success(fix(point = FAR))

            viewModel.effects.test {
                viewModel.onIntent(AttendanceIntent.MarkAttendanceClicked)
                advanceUntilIdle()

                assertThat(awaitItem())
                    .isEqualTo(AttendanceEffect.ShowMessage(FailureReason.OutsideGeofence))
                cancelAndIgnoreRemainingEvents()
            }
            assertThat(viewModel.uiState.value.isMarkingAttendance).isFalse()
        }

    @Test
    fun `a second tap while a mark is in flight is ignored`() = runTest(dispatcher) {
        grantPermission()
        officeRepository.emit(Outcome.Success(officeAnchor()))
        tracker.currentFixResult = Outcome.Success(fix(point = NEAR))
        tracker.emit(Outcome.Success(fix(point = NEAR)))
        advanceUntilIdle()

        viewModel.onIntent(AttendanceIntent.MarkAttendanceClicked)
        // No advanceUntilIdle: the first call is still suspended here.
        viewModel.onIntent(AttendanceIntent.MarkAttendanceClicked)
        advanceUntilIdle()

        // The busy guard must collapse the double tap into a single record.
        assertThat(attendanceRepository.snapshot).hasSize(1)
        assertThat(viewModel.uiState.value.todayRecord).isNotNull()
    }

    @Test
    fun `clearing the office returns the screen to the unconfigured state`() = runTest(dispatcher) {
        grantPermission()
        officeRepository.emit(Outcome.Success(officeAnchor()))
        tracker.emit(Outcome.Success(fix(point = NEAR)))
        advanceUntilIdle()
        assertThat(viewModel.uiState.value.isOfficeConfigured).isTrue()

        viewModel.onIntent(AttendanceIntent.ClearOfficeClicked)
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.isOfficeConfigured).isFalse()
    }

    @Test
    fun `a storage read failure surfaces without wiping the screen`() = runTest(dispatcher) {
        grantPermission()
        officeRepository.emit(Outcome.Failure(AppError.Storage.ReadFailed()))
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.notice).isEqualTo(AttendanceNotice.StorageProblem)
        assertThat(viewModel.uiState.value.isBootstrapping).isFalse()
    }
}
