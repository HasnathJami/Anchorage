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
 * The Attendance screen's state holder — the translator between the user and
 * the domain.
 *
 * ## What it does, and firmly nothing else
 *
 * 1. Turns [AttendanceIntent]s (taps) into use-case calls.
 * 2. Projects [AttendanceStatus] (domain) onto [AttendanceUiState] (pixels).
 * 3. Decides whether a failure deserves a persistent banner or a one-shot
 *    message.
 *
 * It contains **no geofence arithmetic and no window rules.** Those live in
 * the domain, where they are covered by fast JVM tests and cannot diverge
 * between "what the button looked like" and "what the use case allowed". If
 * you find yourself writing `if (distance < 50)` in here, it belongs in
 * [com.anchorage.perimeter.domain.policy.GeofencePolicy] instead.
 *
 * ## The two gates on the GPS
 *
 * Location streaming is the single most expensive thing this app does, so
 * collection is tied to an explicit [observationJob] rather than to a
 * `stateIn(WhileSubscribed)` that would keep the GPS warm whenever anything
 * happened to hold a reference.
 *
 * It runs only while **both** of these hold:
 *
 * ```
 * hasLocationPermission  &&  isScreenVisible
 * ```
 *
 * Those are genuinely different questions — permission says whether the app
 * *may* read the position, visibility says whether it has any *reason* to —
 * and gating on the first alone was a real battery bug. `viewModelScope`
 * outlives the screen being visible, so opening Attendance and pressing home
 * left the receiver running at the full update interval, indefinitely, for a
 * reading nobody could see.
 *
 * @param observeAttendanceStatus The live status stream (the dial).
 * @param captureOfficeAnchor "Set Office Location".
 * @param markAttendance The check-in itself.
 * @param clearOfficeAnchor "Clear office".
 */
@HiltViewModel
class AttendanceViewModel @Inject constructor(
    private val observeAttendanceStatus: ObserveAttendanceStatusUseCase,
    private val captureOfficeAnchor: CaptureOfficeAnchorUseCase,
    private val markAttendance: MarkAttendanceUseCase,
    private val clearOfficeAnchor: ClearOfficeAnchorUseCase,
) : ViewModel() {

    /** Private, mutable. The screen only ever sees the read-only [uiState]. */
    private val _uiState = MutableStateFlow(AttendanceUiState())

    /** What the screen renders. Always holds a current value. */
    val uiState: StateFlow<AttendanceUiState> = _uiState.asStateFlow()

    /**
     * One-shot effects.
     *
     * A buffered [MutableSharedFlow] rather than a `Channel`, so that an
     * effect emitted while the screen is briefly detached (a rotation) is
     * still delivered — while a genuine flood is dropped rather than growing
     * unbounded.
     */
    private val _effects = MutableSharedFlow<AttendanceEffect>(
        replay = 0,
        extraBufferCapacity = 8,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /** What the screen listens to for navigation, dialogs and snackbars. */
    val effects: Flow<AttendanceEffect> = _effects.asSharedFlow()

    /** The running GPS collection, or `null` when stopped. Gate 1 of 2. */
    private var observationJob: Job? = null

    /** Gate 1: may we read the position? */
    private var hasLocationPermission: Boolean = false

    /** Gate 2: is the screen in the foreground? See the class docs. */
    private var isScreenVisible: Boolean = false

    /** @see requestPermissionOnEntry */
    private var hasRequestedPermissionOnEntry: Boolean = false

    /**
     * True between opening the system permission dialog and hearing back.
     *
     * The dialog pauses the activity, so without this the pause it causes
     * would look like the user leaving the screen and would re-arm the ask —
     * producing a dialog that re-opens itself forever.
     */
    private var awaitingPermissionResult: Boolean = false

    /**
     * The last position the stream reported, kept across restarts.
     *
     * Stopping the stream is what saves the battery; losing the position with
     * it is what made the screen blink. Coming back from the office picker
     * tore down the observation and started a fresh one with nothing carried
     * forward, so the dial dropped to `--` and then jumped to the new distance
     * when a satellite next answered — at exactly the moment the user had just
     * moved their office and was watching to see whether it worked.
     *
     * Holding the fix here costs one object and removes the blank frame
     * entirely: the new anchor is measured against it immediately, and the
     * dial animates from the old number to the new one instead of via nothing.
     */
    private var lastKnownFix: LocationFix? = null

    /**
     * The screen's entire public surface: one function, one sealed input.
     *
     * @param intent What the user did.
     */
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

    // ═══════════════════════════════════════════════════════ INTENT HANDLERS

    /**
     * Permission state arrived from the screen's lifecycle observer.
     *
     * @param granted Whether location permission is currently held.
     */
    private fun onPermissionStateChanged(granted: Boolean) {
        hasLocationPermission = granted

        // Arriving on a resume, so the screen is on screen by definition. The
        // permission check is what the lifecycle observer sends when it
        // starts, which makes it a reliable "we are visible" signal.
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
     * Opens the system permission dialog, **once per visit** to the screen.
     *
     * ## Why the guard is not optional
     *
     * `repeatOnLifecycle` re-delivers the permission state every time the
     * screen resumes, and **the permission dialog itself pauses the
     * activity**. So a request driven straight off "not granted" would
     * re-open itself the instant the user declined it — forever. The office
     * picker uses the same flag for the same reason.
     *
     * The flag is cleared when the screen genuinely goes away (see
     * [onScreenStopped]), so a user who declined can come back and be asked
     * again rather than being locked out of a screen with no way to change
     * their mind. Android escalates repeated refusals to "don't ask again" by
     * itself, and at that point [AttendanceNotice.PermissionBlocked] takes
     * over with a route to Settings.
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
     * The permission flag is deliberately *not* cleared: it is still true,
     * and the next resume re-checks it anyway. Only the receiver stops.
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

    /**
     * The user answered the permission dialog. Three outcomes, three
     * different treatments.
     */
    private fun onPermissionResult(intent: AttendanceIntent.PermissionResult) {
        awaitingPermissionResult = false

        when {
            intent.granted -> onPermissionStateChanged(granted = true)

            // Denied and the OS will not ask again. This is the one
            // permission state that still earns a banner, because it is the
            // one the system dialog cannot fix: only Settings can, and an app
            // that does not say so is a dead end.
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

    /**
     * The button inside the notice banner. What it does depends on which
     * notice is showing — which is exactly why each notice is a separate
     * type.
     */
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

    /**
     * "Set Office Location" — capture the current position as the anchor.
     *
     * Both long-running actions follow the same three-step shape: guard
     * against a double-tap, flip a spinner on, then translate the outcome.
     */
    private fun onSetOfficeLocation() {
        // Step 1 - one long-running action at a time.
        if (_uiState.value.isBusy) return
        if (!hasLocationPermission) {
            emitEffect(AttendanceEffect.RequestLocationPermission)
            return
        }

        // Step 2 - spinner on. Clearing the notice here means a retry starts
        // from a clean slate rather than under the previous failure.
        _uiState.update { it.copy(isCapturingOffice = true, notice = null) }

        // Step 3 - call the use case and translate what comes back.
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
                            // `?: it.notice` keeps whatever was showing when
                            // this failure has no banner of its own.
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

    /**
     * The check-in. Same shape as [onSetOfficeLocation].
     *
     * Note there is no permission check and no rule check here — the use case
     * re-validates all five gates itself, because a disabled button is an
     * affordance, not an enforcement boundary.
     */
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

    /**
     * Forget the saved office.
     *
     * No spinner and no result handling: the anchor flow re-emits `null` by
     * itself, and the screen updates from that.
     */
    private fun onClearOffice() {
        viewModelScope.launch { clearOfficeAnchor() }
    }

    // ═════════════════════════════════════════════════════════════ OBSERVATION

    /**
     * The single place that decides whether the GPS should be running.
     *
     * Every path that could change either gate calls this rather than
     * starting or stopping directly, so the two conditions can never get out
     * of step.
     */
    private fun syncObservation() {
        if (hasLocationPermission && isScreenVisible) startObserving() else stopObserving()
    }

    /** Starts the stream, unless one is already running. */
    private fun startObserving() {
        if (observationJob?.isActive == true) return

        // `initialFix` is what removes the blank frame on return - see the
        // note on [lastKnownFix].
        observationJob = observeAttendanceStatus(initialFix = lastKnownFix)
            .onEach { status ->
                // Remembered before the projection, so a restart that happens
                // between two emissions still has somewhere to start from.
                status.lastFix?.let { lastKnownFix = it }
                _uiState.update { it.reduce(status) }
            }
            .launchIn(viewModelScope)
    }

    /** Cancelling the job is what actually switches the GPS off. */
    private fun stopObserving() {
        observationJob?.cancel()
        observationJob = null
    }

    /** Clears the banner and reconnects — the "Retry" path. */
    private fun restartObserving() {
        _uiState.update { it.copy(notice = null) }
        stopObserving()
        syncObservation()
    }

    override fun onCleared() {
        stopObserving()
        super.onCleared()
    }

    // ══════════════════════════════════════════════════════════════ REDUCTION

    /**
     * Projects one domain [AttendanceStatus] onto the UI state.
     *
     * This is the "map domain to pixels" half of the ViewModel's job. Notice
     * how little it decides: [AttendanceStatus.canMarkAttendance] is copied
     * straight across rather than re-derived.
     *
     * @param status The newest domain state.
     * @return The UI state to render.
     */
    private fun AttendanceUiState.reduce(status: AttendanceStatus): AttendanceUiState {
        // Step 1 - collapse (inside/outside + confident) into the three
        // things the user actually needs told apart.
        val reading = status.reading
        val proximity = when {
            reading == null -> ProximityUi.Unknown
            !reading.isConfident -> ProximityUi.LowConfidence
            reading.status == ProximityStatus.INSIDE -> ProximityUi.InRange
            else -> ProximityUi.OutOfRange
        }

        // Step 2 - ambient conditions reported by the stream, in priority
        // order: a location problem outranks a storage problem, which
        // outranks the mock-location note.
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
            // Step 3 - the ownership rule.
            //
            // The stream owns ambient notices and may replace or clear them
            // freely, but it must never overwrite one raised by the
            // permission flow or by an explicit user action. Without this the
            // "fix too coarse to anchor" banner would be wiped by the very
            // next position update, a fraction of a second after appearing.
            notice = if (notice.isOwnedByUserAction()) notice else streamNotice,
        )
    }

    /** The mock-provider note, only when a mock provider is actually active. */
    private fun com.anchorage.perimeter.domain.policy.GeofenceReading.mockNotice() =
        AttendanceNotice.MockLocationActive.takeIf { isMockProvider }

    // ════════════════════════════════════════════════════════════ TRANSLATION

    /**
     * Which failures deserve a **persistent banner**.
     *
     * The rule: a notice must have a remedy the user can act on. `null` here
     * means "this does not get a banner", which is a deliberate answer rather
     * than an oversight — see the two cases called out below.
     */
    private fun AppError.toNotice(): AttendanceNotice? = when (this) {
        // The stream reporting a denial raises nothing: the screen has
        // already asked, and the caption under the dial says why it is empty.
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
        // the last known distance through a dropout and the stream recovers
        // by itself, so a banner offering "Retry" interrupted a screen that
        // was still correct in order to offer a button that changed nothing.
        is AppError.Location.PositionUnavailable,
        is AppError.Location.Timeout,
        is AppError.Attendance,
        is AppError.Unexpected,
        -> null

        // This screen fetches no imagery, so a tile failure cannot originate
        // here. It is listed rather than swept into an `else` so that adding
        // a map to Attendance later trips this branch instead of silently
        // swallowing the failure.
        is AppError.MapTiles -> null
    }

    /** Which failures deserve a **one-shot snackbar**. */
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
     * Notices the ambient location stream is **not** allowed to clear:
     * permission state, and anything the user provoked by pressing a button.
     *
     * Naming this rule as a predicate, rather than inlining the condition, is
     * what stops the next refactor from quietly deleting it.
     */
    private fun AttendanceNotice?.isOwnedByUserAction(): Boolean =
        isPermissionNotice() || this is AttendanceNotice.AnchorRejected

    /** Effects are emitted from a coroutine because `emit` suspends. */
    private fun emitEffect(effect: AttendanceEffect) {
        viewModelScope.launch { _effects.emit(effect) }
    }

    /**
     * A tiny local `update`, so every state change reads the same way:
     * `_uiState.update { it.copy(...) }`.
     */
    private inline fun MutableStateFlow<AttendanceUiState>.update(
        transform: (AttendanceUiState) -> AttendanceUiState,
    ) {
        value = transform(value)
    }
}
