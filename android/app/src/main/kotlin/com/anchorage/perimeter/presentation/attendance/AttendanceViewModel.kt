package com.anchorage.perimeter.presentation.attendance

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.AttendanceStatus
import com.anchorage.perimeter.domain.model.LocationFix
import com.anchorage.perimeter.domain.policy.ProximityStatus
import com.anchorage.perimeter.domain.usecase.CaptureOfficeAnchorUseCase
import com.anchorage.perimeter.domain.usecase.ClearOfficeAnchorUseCase
import com.anchorage.perimeter.domain.usecase.MarkAttendanceUseCase
import com.anchorage.perimeter.domain.usecase.ObserveAttendanceStatusUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * The Attendance screen's state holder.
 *
 * Responsibilities, and firmly nothing else:
 *
 *  * translate [AttendanceIntent]s into use-case calls,
 *  * project [AttendanceStatus] onto [AttendanceUiState],
 *  * decide whether a failure deserves a persistent banner or a one-shot
 *    message.
 *
 * It contains no geofence arithmetic and no window rules - those live in the
 * domain, where they are covered by fast JVM tests and cannot diverge between
 * "what the button looked like" and "what the use case allowed".
 *
 * ### Why the observation job is started and stopped explicitly
 *
 * Location streaming is the single most expensive thing this app does, so the
 * collection is tied to an explicit [observationJob] rather than to a
 * `stateIn(WhileSubscribed)` that would keep the GPS warm whenever anything
 * happened to hold a reference.
 *
 * It runs only while **both** conditions hold: the app has permission, *and*
 * the screen is in the foreground. Those are different questions, and gating
 * on the first alone was a real battery bug - `viewModelScope` outlives the
 * screen being visible, so opening Attendance and pressing home left the
 * receiver running at the full update interval, indefinitely, for a reading
 * nobody could see.
 */
@HiltViewModel
class AttendanceViewModel @Inject constructor(
    private val observeAttendanceStatus: ObserveAttendanceStatusUseCase,
    private val captureOfficeAnchor: CaptureOfficeAnchorUseCase,
    private val markAttendance: MarkAttendanceUseCase,
    private val clearOfficeAnchor: ClearOfficeAnchorUseCase,
) : ViewModel() {

    private val _uiState = MutableStateFlow(AttendanceUiState())
    val uiState: StateFlow<AttendanceUiState> = _uiState.asStateFlow()

    /**
     * Effects use a buffered [MutableSharedFlow] rather than a Channel so that
     * an effect emitted while the screen is briefly detached (rotation) is
     * still delivered, while a genuine flood is dropped instead of growing
     * unbounded.
     */
    private val _effects = MutableSharedFlow<AttendanceEffect>(
        replay = 0,
        extraBufferCapacity = 8,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val effects: Flow<AttendanceEffect> = _effects.asSharedFlow()

    private var observationJob: Job? = null
    private var hasLocationPermission: Boolean = false

    /** Whether the screen is in the foreground. See the class doc. */
    private var isScreenVisible: Boolean = false

    /** @see requestPermissionOnEntry */
    private var hasRequestedPermissionOnEntry: Boolean = false

    /**
     * True between opening the system permission dialog and hearing back.
     *
     * The dialog pauses the activity, so without this the pause it causes
     * would look like the user leaving the screen and would re-arm the ask.
     */
    private var awaitingPermissionResult: Boolean = false

    /**
     * The last position the stream reported, kept across restarts.
     *
     * Stopping the stream is what saves the battery; losing the position with
     * it is what made the screen blink. Coming back from the office picker
     * tore down the observation and started a fresh one with nothing carried
     * forward, so the dial dropped to `--` and then jumped to the new distance
     * when a satellite next answered - at exactly the moment the user had just
     * moved their office and was watching to see whether it worked.
     *
     * Holding the fix here costs one object and removes the blank frame
     * entirely: the new anchor is measured against it immediately, and the
     * dial animates from the old number to the new one instead of via nothing.
     */
    private var lastKnownFix: LocationFix? = null

    fun onIntent(intent: AttendanceIntent) {
        when (intent) {
            AttendanceIntent.ScreenStarted -> Unit // permission state arrives separately
            AttendanceIntent.ScreenStopped -> onScreenStopped()
            AttendanceIntent.SetOfficeLocationClicked -> onSetOfficeLocation()
            AttendanceIntent.MarkAttendanceClicked -> onMarkAttendance()
            AttendanceIntent.ClearOfficeClicked -> onClearOffice()
            AttendanceIntent.NoticeActionClicked -> onNoticeAction()
            AttendanceIntent.NoticeDismissed -> _uiState.update { it.copy(notice = null) }
            is AttendanceIntent.PermissionResult -> onPermissionResult(intent)
            is AttendanceIntent.PermissionStateChanged -> onPermissionStateChanged(intent.granted)
        }
    }

    // ---------------------------------------------------------------- intents

    private fun onPermissionStateChanged(granted: Boolean) {
        hasLocationPermission = granted

        // Arriving on a resume, so the screen is on screen by definition. The
        // permission check is what the lifecycle observer sends when it starts.
        isScreenVisible = true

        _uiState.update { it.copy(hasLocationPermission = granted) }

        if (granted) {
            if (_uiState.value.notice.isPermissionNotice()) {
                _uiState.update { it.copy(notice = null) }
            }
            syncObservation()
            return
        }

        stopObserving()
        _uiState.update { it.copy(isBootstrapping = false) }

        // Ask with the real dialog rather than drawing one. See
        // [requestPermissionOnEntry] for why this cannot simply fire whenever
        // permission is missing.
        requestPermissionOnEntry()
    }

    /**
     * Opens the system permission dialog, once per visit to the screen.
     *
     * The guard is not optional. `repeatOnLifecycle` re-delivers the permission
     * state every time the screen resumes, and **the permission dialog itself
     * pauses the activity** - so a request driven straight off "not granted"
     * would re-open itself the instant the user declined it, forever. The same
     * flag is what the office picker uses, for the same reason.
     *
     * It is cleared when the screen genuinely goes away (see [onScreenStopped]),
     * so a user who declined can come back and be asked again, rather than
     * being locked out of a screen with no way to change their mind. Android
     * escalates repeated refusals to "don't ask again" by itself, and at that
     * point [AttendanceNotice.PermissionBlocked] takes over with a route to
     * Settings.
     */
    private fun requestPermissionOnEntry() {
        if (hasLocationPermission || hasRequestedPermissionOnEntry) return
        hasRequestedPermissionOnEntry = true
        awaitingPermissionResult = true
        emitEffect(AttendanceEffect.RequestLocationPermission)
    }

    /**
     * The screen went away. The position stream goes with it.
     *
     * The permission flag is deliberately *not* cleared: it is still true, and
     * the next resume re-checks it anyway. Only the receiver stops.
     */
    private fun onScreenStopped() {
        isScreenVisible = false
        stopObserving()

        // A real departure re-arms the ask, so someone who declined and came
        // back is asked again. The pause caused by the permission dialog is
        // not a departure and must not re-arm it - that is the difference
        // between asking once per visit and asking in a loop.
        if (!awaitingPermissionResult) hasRequestedPermissionOnEntry = false
    }

    private fun onPermissionResult(intent: AttendanceIntent.PermissionResult) {
        awaitingPermissionResult = false

        when {
            intent.granted -> onPermissionStateChanged(granted = true)

            // Denied and the OS will not ask again. This is the one permission
            // state that still earns a banner, because it is the one the
            // system dialog cannot fix: only Settings can, and an app that
            // does not say so is a dead end.
            !intent.canAskAgain -> _uiState.update {
                it.copy(
                    isBootstrapping = false,
                    hasLocationPermission = false,
                    notice = AttendanceNotice.PermissionBlocked,
                )
            }

            // Declined, but Android will still ask. No banner: the caption
            // under the dial explains why it is empty, and leaving the screen
            // re-arms the request.
            else -> _uiState.update {
                it.copy(isBootstrapping = false, hasLocationPermission = false)
            }
        }
    }

    private fun onNoticeAction() {
        when (_uiState.value.notice) {
            AttendanceNotice.PermissionBlocked -> emitEffect(AttendanceEffect.OpenAppSettings)
            AttendanceNotice.LocationServicesOff -> emitEffect(AttendanceEffect.OpenLocationSettings)
            is AttendanceNotice.WeakSignal -> restartObserving()

            is AttendanceNotice.AnchorRejected -> {
                _uiState.update { it.copy(notice = null) }
                onSetOfficeLocation()
            }

            AttendanceNotice.StorageProblem -> restartObserving()
            AttendanceNotice.MockLocationActive, null -> _uiState.update { it.copy(notice = null) }
        }
    }

    private fun onSetOfficeLocation() {
        if (_uiState.value.isBusy) return
        if (!hasLocationPermission) {
            emitEffect(AttendanceEffect.RequestLocationPermission)
            return
        }

        _uiState.update { it.copy(isCapturingOffice = true, notice = null) }
        viewModelScope.launch {
            when (val result = captureOfficeAnchor()) {
                is Outcome.Success -> {
                    _uiState.update { it.copy(isCapturingOffice = false) }
                    emitEffect(AttendanceEffect.OfficeAnchored(result.value.accuracyMeters))
                }

                is Outcome.Failure -> {
                    _uiState.update {
                        it.copy(
                            isCapturingOffice = false,
                            notice = result.error.toNotice() ?: it.notice,
                        )
                    }
                    result.error.toFailureReason()?.let { reason ->
                        emitEffect(AttendanceEffect.ShowMessage(reason))
                    }
                }
            }
        }
    }

    private fun onMarkAttendance() {
        if (_uiState.value.isBusy) return

        _uiState.update { it.copy(isMarkingAttendance = true) }
        viewModelScope.launch {
            when (val result = markAttendance()) {
                is Outcome.Success -> {
                    _uiState.update { it.copy(isMarkingAttendance = false) }
                    emitEffect(AttendanceEffect.AttendanceMarked(result.value))
                }

                is Outcome.Failure -> {
                    _uiState.update {
                        it.copy(
                            isMarkingAttendance = false,
                            notice = result.error.toNotice() ?: it.notice,
                        )
                    }
                    result.error.toFailureReason()?.let { reason ->
                        emitEffect(AttendanceEffect.ShowMessage(reason))
                    }
                }
            }
        }
    }

    private fun onClearOffice() {
        viewModelScope.launch { clearOfficeAnchor() }
    }

    // ------------------------------------------------------------ observation

    /** Runs the position stream if, and only if, both gates are open. */
    private fun syncObservation() {
        if (hasLocationPermission && isScreenVisible) startObserving() else stopObserving()
    }

    private fun startObserving() {
        if (observationJob?.isActive == true) return

        observationJob = observeAttendanceStatus(initialFix = lastKnownFix)
            .onEach { status ->
                // Remembered before the projection, so a restart that happens
                // between two emissions still has somewhere to start from.
                status.lastFix?.let { lastKnownFix = it }
                _uiState.update { it.reduce(status) }
            }
            .launchIn(viewModelScope)
    }

    private fun stopObserving() {
        observationJob?.cancel()
        observationJob = null
    }

    private fun restartObserving() {
        _uiState.update { it.copy(notice = null) }
        stopObserving()
        syncObservation()
    }

    override fun onCleared() {
        stopObserving()
        super.onCleared()
    }

    // -------------------------------------------------------------- reduction

    private fun AttendanceUiState.reduce(status: AttendanceStatus): AttendanceUiState {
        val reading = status.reading
        val proximity = when {
            reading == null -> ProximityUi.Unknown
            !reading.isConfident -> ProximityUi.LowConfidence
            reading.status == ProximityStatus.INSIDE -> ProximityUi.InRange
            else -> ProximityUi.OutOfRange
        }

        // Ambient conditions reported by the stream.
        val streamNotice = status.locationError?.toNotice()
            ?: status.storageError?.toNotice()
            ?: reading?.mockNotice()

        return copy(
            isBootstrapping = false,
            anchor = status.anchor,
            reading = reading,
            todayRecord = status.todayRecord,
            proximity = proximity,
            isWindowOpen = status.isWindowOpen,
            radiusMeters = status.radiusMeters,
            windowLabel = status.window.format(),
            canMarkAttendance = status.canMarkAttendance,
            // Ownership rule: the stream owns ambient notices and may replace
            // or clear them freely, but it must never overwrite one raised by
            // the permission flow or by an explicit user action. Without this
            // the "fix too coarse to anchor" banner would be wiped by the very
            // next position update, a fraction of a second after appearing.
            notice = if (notice.isOwnedByUserAction()) notice else streamNotice,
        )
    }

    private fun com.anchorage.perimeter.domain.policy.GeofenceReading.mockNotice() =
        AttendanceNotice.MockLocationActive.takeIf { isMockProvider }

    // ------------------------------------------------------------ translation

    private fun AppError.toNotice(): AttendanceNotice? = when (this) {
        // The stream reporting a denial raises nothing: the screen has already
        // asked, and the caption under the dial says why it is empty.
        is AppError.Location.PermissionDenied -> null
        is AppError.Location.PermissionPermanentlyDenied -> AttendanceNotice.PermissionBlocked
        is AppError.Location.ServicesDisabled -> AttendanceNotice.LocationServicesOff
        is AppError.Location.InsufficientAccuracy -> AttendanceNotice.AnchorRejected(
            reportedAccuracyMeters = reportedAccuracyMeters,
            requiredAccuracyMeters = requiredAccuracyMeters,
        )

        is AppError.Storage -> AttendanceNotice.StorageProblem

        // Momentary conditions get a snackbar, or nothing at all - never a
        // banner that would linger after the condition has passed.
        //
        // `PositionUnavailable` is deliberately in this group: the dial holds
        // the last known distance through a dropout and the stream recovers by
        // itself, so a banner offering "Retry" interrupted a screen that was
        // still correct in order to offer a button that changed nothing.
        is AppError.Location.PositionUnavailable,
        is AppError.Location.Timeout,
        is AppError.Attendance,
        is AppError.Unexpected,
        -> null

        // This screen fetches no imagery, so a tile failure cannot originate
        // here. It is listed rather than swept into an `else` so that adding a
        // map to Attendance later trips this branch instead of silently
        // swallowing the failure.
        is AppError.MapTiles -> null
    }

    private fun AppError.toFailureReason(): FailureReason? = when (this) {
        is AppError.Attendance.OutsideGeofence -> FailureReason.OutsideGeofence
        is AppError.Attendance.WindowClosed -> FailureReason.WindowClosed
        is AppError.Attendance.AlreadyMarked -> FailureReason.AlreadyMarkedToday
        is AppError.Attendance.OfficeNotConfigured -> FailureReason.OfficeNotConfigured
        is AppError.Location.Timeout -> FailureReason.LocationTimeout
        is AppError.Unexpected -> FailureReason.Unknown
        else -> null
    }

    private fun AttendanceNotice?.isPermissionNotice(): Boolean =
        this == AttendanceNotice.PermissionBlocked

    /**
     * Notices the ambient location stream is not allowed to clear: permission
     * state, and anything the user provoked by pressing a button.
     */
    private fun AttendanceNotice?.isOwnedByUserAction(): Boolean =
        isPermissionNotice() || this is AttendanceNotice.AnchorRejected

    private fun emitEffect(effect: AttendanceEffect) {
        viewModelScope.launch { _effects.emit(effect) }
    }

    private inline fun MutableStateFlow<AttendanceUiState>.update(
        transform: (AttendanceUiState) -> AttendanceUiState,
    ) {
        value = transform(value)
    }
}
