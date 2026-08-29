package com.anchorage.perimeter.presentation.officepicker

import app.cash.turbine.test
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.fake.DHAKA_OFFICE
import com.anchorage.perimeter.domain.fake.FakeLocationTracker
import com.anchorage.perimeter.domain.fake.FakeOfficeAnchorRepository
import com.anchorage.perimeter.domain.fake.FixedTimeProvider
import com.anchorage.perimeter.domain.fake.anchorAt
import com.anchorage.perimeter.domain.fake.fixAt
import com.anchorage.perimeter.domain.model.AnchorSource
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.TileCoordinate
import com.anchorage.perimeter.domain.port.MapTileSource
import com.anchorage.perimeter.domain.usecase.PlaceOfficeAnchorUseCase
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test

/**
 * The picker's rules, in particular the ones about failing without breaking.
 *
 * The screen's whole reason for existing is that a user can be standing in a
 * basement car park with no signal and still need to set an office, so most of
 * these tests are about what happens when something is unavailable.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class OfficePickerViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private lateinit var tracker: FakeLocationTracker
    private lateinit var anchors: FakeOfficeAnchorRepository
    private lateinit var tiles: FakeTileSource

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        tracker = FakeLocationTracker()
        anchors = FakeOfficeAnchorRepository()
        tiles = FakeTileSource()
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    private fun viewModel() = OfficePickerViewModel(
        locationTracker = tracker,
        officeAnchorRepository = anchors,
        placeOfficeAnchor = PlaceOfficeAnchorUseCase(anchors, FixedTimeProvider()),
        tileSource = tiles,
    )

    // ------------------------------------------------------------------ start

    @Test
    fun `an existing office opens the map on it rather than on the world`() = runTest(dispatcher) {
        anchors.emit(Outcome.Success(anchorAt(DHAKA_OFFICE)))
        val viewModel = viewModel()

        viewModel.onIntent(OfficePickerIntent.ScreenStarted)
        runCurrent()

        assertThat(viewModel.uiState.value.centre).isEqualTo(DHAKA_OFFICE)
        assertThat(viewModel.uiState.value.hasExistingAnchor).isTrue()
        assertThat(viewModel.uiState.value.zoom).isEqualTo(OfficePickerUiState.PLACE_ZOOM)
    }

    @Test
    fun `granting permission centres the map on the user for a first office`() =
        runTest(dispatcher) {
            val viewModel = viewModel()
            viewModel.onIntent(OfficePickerIntent.ScreenStarted)
            runCurrent()
            viewModel.onIntent(OfficePickerIntent.PermissionStateChanged(granted = true))
            runCurrent()

            assertThat(viewModel.uiState.value.centre).isEqualTo(DHAKA_OFFICE)
            assertThat(viewModel.uiState.value.userLocation).isEqualTo(DHAKA_OFFICE)
        }

    @Test
    fun `an existing office is not dragged away by the first fix`() = runTest(dispatcher) {
        // Opening "update" must not silently move the office the user came to
        // adjust; the fix is offered through Find Me, not applied behind them.
        val office = GeoPoint(23.9, 90.5)
        anchors.emit(Outcome.Success(anchorAt(office)))
        val viewModel = viewModel()

        viewModel.onIntent(OfficePickerIntent.ScreenStarted)
        runCurrent()
        viewModel.onIntent(OfficePickerIntent.PermissionStateChanged(granted = true))
        runCurrent()

        assertThat(viewModel.uiState.value.centre).isEqualTo(office)
    }

    @Test
    fun `permission arriving before the saved office is read still keeps the office`() =
        runTest(dispatcher) {
            // The order a real device produces: `repeatOnLifecycle` delivers
            // the permission state synchronously while the anchor read is
            // still in flight. Asserting only the convenient order is what let
            // this ship - on the phone the picker flew away from the office
            // the user had opened it to adjust.
            val office = GeoPoint(23.9, 90.5)
            anchors.emit(Outcome.Success(anchorAt(office)))
            val viewModel = viewModel()

            viewModel.onIntent(OfficePickerIntent.PermissionStateChanged(granted = true))
            viewModel.onIntent(OfficePickerIntent.ScreenStarted)
            runCurrent()

            assertThat(viewModel.uiState.value.centre).isEqualTo(office)
            assertThat(viewModel.uiState.value.hasExistingAnchor).isTrue()
            // The fix is still taken - the ring needs it - but it lands in the
            // read-out, not in the camera. Asserting "no fix at all" would
            // have locked in a picker that can never colour its own perimeter.
            assertThat(viewModel.uiState.value.userLocation).isEqualTo(DHAKA_OFFICE)
        }

    @Test
    fun `an existing office plots the user's dot without moving the map`() = runTest(dispatcher) {
        // Both halves matter. The blue "you are here" dot cannot be drawn
        // without a fix, and taking that fix must not cost the user the office
        // they opened the screen to adjust.
        val office = GeoPoint(23.9, 90.5)
        anchors.emit(Outcome.Success(anchorAt(office)))
        val viewModel = viewModel()

        viewModel.onIntent(OfficePickerIntent.ScreenStarted)
        runCurrent()
        viewModel.onIntent(OfficePickerIntent.PermissionStateChanged(granted = true))
        runCurrent()

        assertThat(viewModel.uiState.value.centre).isEqualTo(office)
        assertThat(viewModel.uiState.value.zoom).isEqualTo(OfficePickerUiState.PLACE_ZOOM)
        assertThat(viewModel.uiState.value.userLocation).isEqualTo(DHAKA_OFFICE)
    }

    @Test
    fun `a first visit asks for location permission instead of opening on the world`() =
        runTest(dispatcher) {
            val viewModel = viewModel()

            viewModel.effects.test {
                viewModel.onIntent(OfficePickerIntent.ScreenStarted)
                runCurrent()
                assertThat(awaitItem())
                    .isEqualTo(OfficePickerEffect.RequestLocationPermission)
            }
        }

    @Test
    fun `an office already saved is not a reason to prompt for permission`() =
        runTest(dispatcher) {
            // Nudging a pin does not require knowing where the user is. The
            // prompt is the price of the first visit's convenience, and it
            // should not be charged twice.
            anchors.emit(Outcome.Success(anchorAt(DHAKA_OFFICE)))
            val viewModel = viewModel()

            viewModel.effects.test {
                viewModel.onIntent(OfficePickerIntent.ScreenStarted)
                runCurrent()
                expectNoEvents()
            }
        }

    @Test
    fun `a declined prompt is not re-fired every time the screen resumes`() =
        runTest(dispatcher) {
            val viewModel = viewModel()

            viewModel.effects.test {
                viewModel.onIntent(OfficePickerIntent.ScreenStarted)
                runCurrent()
                assertThat(awaitItem())
                    .isEqualTo(OfficePickerEffect.RequestLocationPermission)

                // The system dialog pauses the activity, so declining it
                // produces exactly this sequence. Re-prompting here is an
                // inescapable loop: the user cannot leave the screen without
                // answering, and answering re-asks.
                viewModel.onIntent(
                    OfficePickerIntent.PermissionResult(granted = false, canAskAgain = true),
                )
                repeat(3) {
                    viewModel.onIntent(OfficePickerIntent.PermissionStateChanged(granted = false))
                }
                runCurrent()

                expectNoEvents()
            }
        }

    @Test
    fun `a resume does not drag the map back off the spot the user panned to`() =
        runTest(dispatcher) {
            val viewModel = viewModel()
            viewModel.onIntent(OfficePickerIntent.ScreenStarted)
            runCurrent()
            viewModel.onIntent(OfficePickerIntent.PermissionStateChanged(granted = true))
            runCurrent()

            // The user rejects the fix and pans to the actual front door.
            val chosen = GeoPoint(23.75, 90.42)
            viewModel.onIntent(OfficePickerIntent.CentreMoved(chosen))

            // Glancing at another app and coming back re-delivers the
            // permission state; it must not re-centre.
            viewModel.onIntent(OfficePickerIntent.PermissionStateChanged(granted = true))
            runCurrent()

            assertThat(viewModel.uiState.value.centre).isEqualTo(chosen)
        }

    // ------------------------------------------------------------------- zoom

    @Test
    fun `zoom cannot be pushed past the range the tile server serves`() = runTest(dispatcher) {
        val viewModel = viewModel()

        viewModel.onIntent(OfficePickerIntent.ZoomChanged(OfficePickerUiState.MAX_ZOOM + 5))
        assertThat(viewModel.uiState.value.zoom).isEqualTo(OfficePickerUiState.MAX_ZOOM)

        viewModel.onIntent(OfficePickerIntent.ZoomChanged(OfficePickerUiState.MIN_ZOOM - 5))
        assertThat(viewModel.uiState.value.zoom).isEqualTo(OfficePickerUiState.MIN_ZOOM)
    }

    @Test
    fun `zooming keeps the pin on the spot it was framing`() = runTest(dispatcher) {
        // The crosshair is the office-to-be. A zoom that shifted the centre
        // would move the office every time the user tried to look closer at it.
        val viewModel = viewModel()
        viewModel.onIntent(OfficePickerIntent.CentreMoved(DHAKA_OFFICE))

        viewModel.onIntent(OfficePickerIntent.ZoomChanged(OfficePickerUiState.PLACE_ZOOM + 1))

        assertThat(viewModel.uiState.value.centre).isEqualTo(DHAKA_OFFICE)
        assertThat(viewModel.uiState.value.zoom).isEqualTo(OfficePickerUiState.PLACE_ZOOM + 1)
    }

    @Test
    fun `with no saved office, permission arriving early still centres on the user`() =
        runTest(dispatcher) {
            // The other half of the gate: deferring the auto-locate must not
            // lose it altogether.
            val viewModel = viewModel()

            viewModel.onIntent(OfficePickerIntent.PermissionStateChanged(granted = true))
            viewModel.onIntent(OfficePickerIntent.ScreenStarted)
            runCurrent()

            assertThat(viewModel.uiState.value.centre).isEqualTo(DHAKA_OFFICE)
            assertThat(viewModel.uiState.value.userLocation).isEqualTo(DHAKA_OFFICE)
        }

    @Test
    fun `saving keeps the confirm button offering an update, not a fresh set`() =
        runTest(dispatcher) {
            val viewModel = viewModel()
            viewModel.onIntent(OfficePickerIntent.ScreenStarted)
            runCurrent()
            viewModel.onIntent(OfficePickerIntent.CentreMoved(DHAKA_OFFICE))

            viewModel.onIntent(OfficePickerIntent.ConfirmClicked)
            runCurrent()

            // The anchor is observed rather than read once, so this screen's
            // own write is reflected back into its own state.
            assertThat(viewModel.uiState.value.hasExistingAnchor).isTrue()
        }

    // ---------------------------------------------------------------- saving

    @Test
    fun `an office far outside the perimeter saves without complaint`() = runTest(dispatcher) {
        // The picker imposes no geofence on itself. People set the office up
        // from home, from the car park, from the wrong floor - and the 50 m
        // rule is a question for check-in, asked against the anchor this
        // screen writes. Refusing here would make the app unusable for the
        // exact person it is being set up for.
        val viewModel = viewModel()
        viewModel.onIntent(OfficePickerIntent.ScreenStarted)
        runCurrent()
        viewModel.onIntent(OfficePickerIntent.PermissionStateChanged(granted = true))
        runCurrent()

        // ~110 km from the fix the tracker just returned.
        val farAway = GeoPoint(DHAKA_OFFICE.latitude + 1.0, DHAKA_OFFICE.longitude)
        viewModel.onIntent(OfficePickerIntent.CentreMoved(farAway))

        assertThat(viewModel.uiState.value.canConfirm).isTrue()

        viewModel.effects.test {
            viewModel.onIntent(OfficePickerIntent.ConfirmClicked)
            runCurrent()
            assertThat(awaitItem()).isEqualTo(OfficePickerEffect.Saved(farAway))
        }

        assertThat(anchors.savedAnchors.single().point).isEqualTo(farAway)
    }

    @Test
    fun `confirming saves the pin as a hand-placed anchor, not as a fix`() =
        runTest(dispatcher) {
            val viewModel = viewModel()
            val chosen = GeoPoint(23.7, 90.4)
            viewModel.onIntent(OfficePickerIntent.CentreMoved(chosen))

            viewModel.effects.test {
                viewModel.onIntent(OfficePickerIntent.ConfirmClicked)
                runCurrent()
                assertThat(awaitItem()).isEqualTo(OfficePickerEffect.Saved(chosen))
            }

            val saved = anchors.savedAnchors.single()
            assertThat(saved.point).isEqualTo(chosen)
            assertThat(saved.source).isEqualTo(AnchorSource.ManualPlacement)
        }

    @Test
    fun `confirming before the map has moved refuses rather than saving the world centre`() =
        runTest(dispatcher) {
            val viewModel = viewModel()

            viewModel.effects.test {
                viewModel.onIntent(OfficePickerIntent.ConfirmClicked)
                runCurrent()
                assertThat(awaitItem())
                    .isEqualTo(OfficePickerEffect.ShowMessage(PickerMessage.NothingToSave))
            }

            assertThat(anchors.savedAnchors).isEmpty()
        }

    @Test
    fun `a failed write offers a retry instead of pretending it saved`() = runTest(dispatcher) {
        anchors.saveResult = Outcome.Failure(AppError.Storage.WriteFailed())
        val viewModel = viewModel()
        viewModel.onIntent(OfficePickerIntent.CentreMoved(DHAKA_OFFICE))

        viewModel.onIntent(OfficePickerIntent.ConfirmClicked)
        runCurrent()

        assertThat(viewModel.uiState.value.notice).isEqualTo(PickerNotice.SaveFailed)
        assertThat(viewModel.uiState.value.isSaving).isFalse()
    }

    // ------------------------------------------------------- location failures

    @Test
    fun `each location failure maps to the dialog that can actually fix it`() =
        runTest(dispatcher) {
            val cases = mapOf(
                AppError.Location.PermissionDenied() to PickerNotice.PermissionRequired,
                AppError.Location.PermissionPermanentlyDenied() to PickerNotice.PermissionBlocked,
                AppError.Location.ServicesDisabled() to PickerNotice.ServicesDisabled,
                AppError.Location.Timeout(waitedMillis = 15_000) to PickerNotice.LocationTimeout,
                AppError.Location.PositionUnavailable() to PickerNotice.PositionUnavailable,
            )

            cases.forEach { (error, expected) ->
                tracker = FakeLocationTracker(currentFixResult = Outcome.Failure(error))
                val viewModel = viewModel()
                viewModel.onIntent(OfficePickerIntent.ScreenStarted)
                runCurrent()
                viewModel.onIntent(OfficePickerIntent.PermissionStateChanged(granted = true))
                runCurrent()

                assertThat(viewModel.uiState.value.notice).isEqualTo(expected)
                assertThat(viewModel.uiState.value.isLocating).isFalse()
            }
        }

    @Test
    fun `find me without permission asks for it instead of failing`() = runTest(dispatcher) {
        val viewModel = viewModel()

        viewModel.effects.test {
            viewModel.onIntent(OfficePickerIntent.FindMeClicked)
            runCurrent()
            assertThat(awaitItem()).isEqualTo(OfficePickerEffect.RequestLocationPermission)
        }
    }

    @Test
    fun `a jabbed find me button does not stack GPS requests`() = runTest(dispatcher) {
        val viewModel = viewModel()
        viewModel.onIntent(OfficePickerIntent.PermissionStateChanged(granted = true))

        repeat(5) { viewModel.onIntent(OfficePickerIntent.FindMeClicked) }
        runCurrent()

        // Each request holds the radio awake; five in flight is five times the
        // battery for one answer.
        assertThat(tracker.currentFixCallCount).isEqualTo(1)
    }

    // ----------------------------------------------------------- tile failures

    @Test
    fun `an offline map degrades the imagery but never blocks placing the office`() =
        runTest(dispatcher) {
            tiles.result = Outcome.Failure(AppError.MapTiles.Offline())
            val viewModel = viewModel()

            viewModel.onIntent(
                OfficePickerIntent.TilesRequested(listOf(TileCoordinate(1, 1, 2))),
            )
            runCurrent()

            assertThat(viewModel.uiState.value.isMapImageryDegraded).isTrue()
            assertThat(viewModel.uiState.value.notice)
                .isEqualTo(PickerNotice.MapImageryUnavailable)

            // The important half: the office can still be set.
            viewModel.onIntent(OfficePickerIntent.CentreMoved(DHAKA_OFFICE))
            assertThat(viewModel.uiState.value.canConfirm).isTrue()
        }

    @Test
    fun `retrying the map clears the failure and asks for the tiles again`() =
        runTest(dispatcher) {
            tiles.result = Outcome.Failure(AppError.MapTiles.Offline())
            val viewModel = viewModel()
            val tile = TileCoordinate(1, 1, 2)

            viewModel.onIntent(OfficePickerIntent.TilesRequested(listOf(tile)))
            runCurrent()

            // The network comes back.
            tiles.result = Outcome.Success(byteArrayOf(1, 2, 3))
            viewModel.onIntent(OfficePickerIntent.NoticeActionClicked)
            runCurrent()
            viewModel.onIntent(OfficePickerIntent.TilesRequested(listOf(tile)))
            runCurrent()

            assertThat(viewModel.uiState.value.notice).isNull()
            assertThat(viewModel.uiState.value.tiles).containsKey(tile)
        }

    @Test
    fun `a tile is fetched once, not on every pan frame`() = runTest(dispatcher) {
        val viewModel = viewModel()
        val tile = TileCoordinate(2, 3, 4)

        repeat(6) { viewModel.onIntent(OfficePickerIntent.TilesRequested(listOf(tile))) }
        runCurrent()

        assertThat(tiles.loadCount).isEqualTo(1)
    }

    /** A tile source that answers instantly and records what was asked of it. */
    private class FakeTileSource : MapTileSource {
        var result: Outcome<ByteArray> = Outcome.Success(byteArrayOf(0))
        var loadCount: Int = 0

        override val attribution: String = "fake"

        override suspend fun load(tile: TileCoordinate): Outcome<ByteArray> {
            loadCount++
            return result
        }
    }
}
