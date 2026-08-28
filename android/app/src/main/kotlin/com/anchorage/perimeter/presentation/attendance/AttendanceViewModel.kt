package com.anchorage.perimeter.presentation.attendance

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.anchorage.perimeter.core.common.error.AppError
import com.anchorage.perimeter.core.common.outcome.Outcome
import com.anchorage.perimeter.domain.model.AttendanceStatus
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
 * Location streaming is the single most expensive thing this app does. The
 * collection is therefore tied to an explicit [observationJob] that only runs
 * while the screen holds permission, rather than a `stateIn(WhileSubscribed)`
 * that would silently keep the GPS warm whenever anything happened to hold a
 * reference.
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

    fun onIntent(intent: AttendanceIntent) {
        when (intent) {
            AttendanceIntent.ScreenStarted -> Unit // permission state arrives separately
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
        if (granted) {
            if (_uiState.value.notice.isPermissionNotice()) {
                _uiState.update { it.copy(notice = null) }
            }
            startObserving()
        } else {
            stopObserving()
            _uiState.update {
                it.copy(
                    isBootstrapping = false,
                    notice = it.notice ?: AttendanceNotice.PermissionRequired,
                )
            }
        }
    }

    private fun onPermissionResult(intent: AttendanceIntent.PermissionResult) {
        when {
            intent.granted -> onPermissionStateChanged(granted = true)

            // Denied and the OS will not ask again: only Settings can help, so
            // the banner has to change its offer rather than repeat itself.
            !intent.canAskAgain -> _uiState.update {
                it.copy(isBootstrapping = false, notice = AttendanceNotice.PermissionBlocked)
            }

            else -> _uiState.update {
                it.copy(isBootstrapping = false, notice = AttendanceNotice.PermissionRequired)
            }
        }
    }

    private fun onNoticeAction() {
        when (_uiState.value.notice) {
            AttendanceNotice.PermissionRequired -> emitEffect(AttendanceEffect.RequestLocationPermission)
            AttendanceNotice.PermissionBlocked -> emitEffect(AttendanceEffect.OpenAppSettings)
            AttendanceNotice.LocationServicesOff -> emitEffect(AttendanceEffect.OpenLocationSettings)
            AttendanceNotice.PositionUnavailable,
            is AttendanceNotice.WeakSignal,
            -> restartObserving()

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

    private fun startObserving() {
        if (observationJob?.isActive == true) return

        observationJob = observeAttendanceStatus()
            .onEach { status -> _uiState.update { it.reduce(status) } }
            .launchIn(viewModelScope)
    }

    private fun stopObserving() {
        observationJob?.cancel()
        observationJob = null
    }

    private fun restartObserving() {
        _uiState.update { it.copy(notice = null) }
        stopObserving()
        startObserving()
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
        is AppError.Location.PermissionDenied -> AttendanceNotice.PermissionRequired
        is AppError.Location.PermissionPermanentlyDenied -> AttendanceNotice.PermissionBlocked
        is AppError.Location.ServicesDisabled -> AttendanceNotice.LocationServicesOff
        is AppError.Location.PositionUnavailable -> AttendanceNotice.PositionUnavailable
        is AppError.Location.InsufficientAccuracy -> AttendanceNotice.AnchorRejected(
            reportedAccuracyMeters = reportedAccuracyMeters,
            requiredAccuracyMeters = requiredAccuracyMeters,
        )

        is AppError.Storage -> AttendanceNotice.StorageProblem

        // Timeouts and rule rejections are momentary: they get a snackbar, not
        // a banner that would linger after the condition has passed.
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
        this == AttendanceNotice.PermissionRequired || this == AttendanceNotice.PermissionBlocked

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
