package com.anchorage.perimeter.presentation.officepicker

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.GeoPoint
import com.anchorage.perimeter.domain.model.TileCoordinate
import com.anchorage.perimeter.domain.port.LocationTracker
import com.anchorage.perimeter.domain.port.MapTileSource
import com.anchorage.perimeter.domain.port.OfficeAnchorRepository
import com.anchorage.perimeter.domain.usecase.PlaceOfficeAnchorUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * The office picker's state holder.
 *
 * Same discipline as [com.anchorage.perimeter.presentation.attendance.AttendanceViewModel]:
 * it translates intents into use-case calls and projects the result. It owns
 * no geofence arithmetic - the radius, the distance and the inside/outside
 * decision all come from the domain, so the ring on this screen and the dial
 * on the previous one can never disagree.
 *
 * Two things here are worth reading closely.
 *
 * **Tile failures are not screen failures.** A tile that will not load sets
 * [OfficePickerUiState.isMapImageryDegraded] and nothing else. The pin, the
 * perimeter, the coordinates and the confirm button all keep working with a
 * plain grid behind them, because a picker that refuses to open without a
 * network is useless in exactly the basements and car parks where people need
 * to set an office.
 *
 * **Only one location request is ever in flight.** "Find me" is idempotent
 * while it is running; a user jabbing the button cannot stack fifteen
 * high-accuracy GPS requests, each holding the radio awake.
 */
@HiltViewModel
class OfficePickerViewModel @Inject constructor(
    private val locationTracker: LocationTracker,
    private val officeAnchorRepository: OfficeAnchorRepository,
    private val placeOfficeAnchor: PlaceOfficeAnchorUseCase,
    private val tileSource: MapTileSource,
) : ViewModel() {

    private val _uiState = MutableStateFlow(OfficePickerUiState())
    val uiState: StateFlow<OfficePickerUiState> = _uiState.asStateFlow()

    private val _effects = MutableSharedFlow<OfficePickerEffect>(
        replay = 0,
        extraBufferCapacity = 8,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val effects: Flow<OfficePickerEffect> = _effects.asSharedFlow()

    val attribution: String get() = tileSource.attribution

    private var locateJob: Job? = null
    private var startupObservation: Job? = null

    /** True once the saved anchor (or its absence) is known. */
    private var startupResolved = false
    private var autoLocateWhenReady = false
    private var hasAppliedInitialCentre = false
    private var hasLocationPermission = false
    private val tilesInFlight = mutableSetOf<TileCoordinate>()

    fun onIntent(intent: OfficePickerIntent) {
        when (intent) {
            OfficePickerIntent.ScreenStarted -> onStarted()
            is OfficePickerIntent.PermissionStateChanged -> onPermissionState(intent.granted)
            is OfficePickerIntent.PermissionResult -> onPermissionResult(intent)
            is OfficePickerIntent.CentreMoved -> _uiState.update {
                it.copy(centre = intent.point, hasCentredOnSomething = true)
            }

            is OfficePickerIntent.ZoomChanged -> _uiState.update {
                it.copy(
                    zoom = intent.zoom.coerceIn(
                        OfficePickerUiState.MIN_ZOOM,
                        OfficePickerUiState.MAX_ZOOM,
                    ),
                )
            }

            is OfficePickerIntent.TilesRequested -> ensureTiles(intent.tiles)
            OfficePickerIntent.FindMeClicked -> onFindMe()
            OfficePickerIntent.ConfirmClicked -> onConfirm()
            OfficePickerIntent.NoticeActionClicked -> onNoticeAction()
            OfficePickerIntent.NoticeDismissed -> _uiState.update { it.copy(notice = null) }
        }
    }

    // ---------------------------------------------------------------- startup

    /**
     * Reads the saved office and centres on it.
     *
     * The anchor is *observed*, not read once: the flag has to stay correct
     * after this screen's own save, or the confirm button goes on offering to
     * "Set" an office that already exists.
     *
     * [startupResolved] exists because this read is asynchronous while
     * `PermissionStateChanged` arrives synchronously from `repeatOnLifecycle`.
     * Without the gate the two race, permission wins, and the picker helpfully
     * flies away from the office the user opened it to adjust - which is
     * exactly what it did on a real device before this flag existed.
     */
    private fun onStarted() {
        if (startupObservation?.isActive == true) return

        startupObservation = officeAnchorRepository.observe()
            .onEach { outcome ->
                val existing = (outcome as? Outcome.Success)?.value

                _uiState.update { state ->
                    state.copy(
                        hasExistingAnchor = existing != null,
                        centre = if (existing != null && !hasAppliedInitialCentre) {
                            existing.point
                        } else {
                            state.centre
                        },
                        zoom = if (existing != null && !hasAppliedInitialCentre) {
                            OfficePickerUiState.PLACE_ZOOM
                        } else {
                            state.zoom
                        },
                        hasCentredOnSomething = state.hasCentredOnSomething || existing != null,
                    )
                }

                if (existing != null) hasAppliedInitialCentre = true

                if (!startupResolved) {
                    startupResolved = true
                    // Honour a "find me" that arrived while this was still in
                    // flight, but only when there is no office to preserve.
                    if (autoLocateWhenReady && existing == null) locate(recentre = true)
                    autoLocateWhenReady = false
                }
            }
            .launchIn(viewModelScope)
    }

    private fun onPermissionState(granted: Boolean) {
        hasLocationPermission = granted
        if (!granted) return

        if (_uiState.value.notice == PickerNotice.PermissionRequired ||
            _uiState.value.notice == PickerNotice.PermissionBlocked
        ) {
            _uiState.update { it.copy(notice = null) }
        }

        // A first fix on entry is a convenience, not a requirement: it is what
        // makes the common case ("my office is where I am standing") a single
        // tap of Confirm. It must never override an office already saved, so
        // it waits until the saved anchor is known.
        if (!startupResolved) {
            autoLocateWhenReady = true
            return
        }
        if (!_uiState.value.hasExistingAnchor) locate(recentre = true)
    }

    private fun onPermissionResult(intent: OfficePickerIntent.PermissionResult) {
        hasLocationPermission = intent.granted
        when {
            intent.granted -> locate(recentre = true)
            intent.canAskAgain -> _uiState.update { it.copy(notice = PickerNotice.PermissionRequired) }
            else -> _uiState.update { it.copy(notice = PickerNotice.PermissionBlocked) }
        }
    }

    // ----------------------------------------------------------------- actions

    private fun onFindMe() {
        if (!hasLocationPermission) {
            emitEffect(OfficePickerEffect.RequestLocationPermission)
            return
        }
        locate(recentre = true)
    }

    /**
     * One high-accuracy fix.
     *
     * [recentre] moves the pin to the user; a background refresh (used to keep
     * the perimeter's colour honest) leaves the pin where the user put it.
     */
    private fun locate(recentre: Boolean) {
        if (locateJob?.isActive == true) return

        _uiState.update { it.copy(isLocating = true, notice = null) }
        locateJob = viewModelScope.launch {
            when (val result = locationTracker.currentFix()) {
                is Outcome.Success -> {
                    val fix = result.value
                    _uiState.update {
                        it.copy(
                            isLocating = false,
                            userLocation = fix.point,
                            userAccuracyMeters = fix.accuracyMeters,
                            centre = if (recentre) fix.point else it.centre,
                            zoom = if (recentre) {
                                maxOf(it.zoom, OfficePickerUiState.PLACE_ZOOM)
                            } else {
                                it.zoom
                            },
                            hasCentredOnSomething = it.hasCentredOnSomething || recentre,
                        )
                    }
                }

                is Outcome.Failure -> _uiState.update {
                    it.copy(isLocating = false, notice = result.error.toNotice())
                }
            }
        }
    }

    private fun onConfirm() {
        val state = _uiState.value
        if (state.isSaving) return
        if (!state.hasCentredOnSomething) {
            emitEffect(OfficePickerEffect.ShowMessage(PickerMessage.NothingToSave))
            return
        }

        _uiState.update { it.copy(isSaving = true, notice = null) }
        viewModelScope.launch {
            when (val result = placeOfficeAnchor(state.centre)) {
                is Outcome.Success -> {
                    _uiState.update { it.copy(isSaving = false) }
                    emitEffect(OfficePickerEffect.Saved(result.value.point))
                }

                is Outcome.Failure -> _uiState.update {
                    it.copy(isSaving = false, notice = PickerNotice.SaveFailed)
                }
            }
        }
    }

    private fun onNoticeAction() {
        when (_uiState.value.notice) {
            PickerNotice.PermissionRequired ->
                emitEffect(OfficePickerEffect.RequestLocationPermission)

            PickerNotice.PermissionBlocked -> emitEffect(OfficePickerEffect.OpenAppSettings)
            PickerNotice.ServicesDisabled -> emitEffect(OfficePickerEffect.OpenLocationSettings)

            PickerNotice.PositionUnavailable,
            PickerNotice.LocationTimeout,
            -> {
                _uiState.update { it.copy(notice = null) }
                locate(recentre = true)
            }

            PickerNotice.MapImageryUnavailable -> {
                // Clearing the flag *and* the in-flight set is what makes the
                // retry real: without the second, every tile would still be
                // marked as "already asked for" and nothing would refetch.
                tilesInFlight.clear()
                _uiState.update {
                    it.copy(notice = null, isMapImageryDegraded = false, tiles = emptyMap())
                }
            }

            PickerNotice.SaveFailed -> {
                _uiState.update { it.copy(notice = null) }
                onConfirm()
            }

            null -> Unit
        }
    }

    // ------------------------------------------------------------------- tiles

    private fun ensureTiles(requested: List<TileCoordinate>) {
        val known = _uiState.value.tiles
        val missing = requested
            .map { it.wrapped() }
            .filter { it.isValid && !known.containsKey(it) && tilesInFlight.add(it) }

        if (missing.isEmpty()) return

        viewModelScope.launch {
            missing.forEach { tile ->
                when (val result = tileSource.load(tile)) {
                    is Outcome.Success -> _uiState.update {
                        it.copy(tiles = it.tiles + (tile to result.value))
                    }

                    is Outcome.Failure -> {
                        tilesInFlight.remove(tile)
                        // One dialog for the whole failure, not one per tile:
                        // a dropped connection fails a dozen requests at once
                        // and the user needs to be told once.
                        if (result.error is AppError.MapTiles.Offline ||
                            result.error is AppError.MapTiles.Timeout
                        ) {
                            _uiState.update {
                                it.copy(
                                    isMapImageryDegraded = true,
                                    notice = it.notice ?: PickerNotice.MapImageryUnavailable,
                                )
                            }
                        } else {
                            _uiState.update { it.copy(isMapImageryDegraded = true) }
                        }
                    }
                }
            }
        }
    }

    private fun emitEffect(effect: OfficePickerEffect) {
        viewModelScope.launch { _effects.emit(effect) }
    }

    private fun AppError.toNotice(): PickerNotice = when (this) {
        is AppError.Location.PermissionDenied -> PickerNotice.PermissionRequired
        is AppError.Location.PermissionPermanentlyDenied -> PickerNotice.PermissionBlocked
        is AppError.Location.ServicesDisabled -> PickerNotice.ServicesDisabled
        is AppError.Location.Timeout -> PickerNotice.LocationTimeout
        is AppError.Location.PositionUnavailable -> PickerNotice.PositionUnavailable
        // An accuracy too poor to *anchor* is irrelevant here: nothing is being
        // measured, so a coarse fix is still a perfectly good place to start
        // panning from.
        is AppError.Location.InsufficientAccuracy -> PickerNotice.PositionUnavailable
        is AppError.MapTiles -> PickerNotice.MapImageryUnavailable
        is AppError.Storage -> PickerNotice.SaveFailed
        is AppError.Attendance -> PickerNotice.PositionUnavailable
        is AppError.Unexpected -> PickerNotice.PositionUnavailable
    }
}
