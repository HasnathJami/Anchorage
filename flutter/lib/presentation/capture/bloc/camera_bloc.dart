import 'dart:async';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/domain/services/permission_gateway.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/capture_batch.dart';
import 'package:anchorage_harbor/domain/entities/exposure_range.dart';
import 'package:anchorage_harbor/domain/entities/flash_policy.dart';
import 'package:anchorage_harbor/domain/entities/zoom_span.dart';
import 'package:anchorage_harbor/domain/services/camera_port.dart';
import 'package:anchorage_harbor/presentation/capture/bloc/camera_event.dart';
import 'package:anchorage_harbor/presentation/capture/bloc/camera_state.dart';
import 'package:anchorage_harbor/domain/usecases/sync_use_cases.dart';
import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:uuid/uuid.dart';

// Barrel: consumers import the Bloc and get its events and state with it.
export 'package:anchorage_harbor/presentation/capture/bloc/camera_event.dart';
export 'package:anchorage_harbor/presentation/capture/bloc/camera_state.dart';

/// The camera screen's state machine.
///
/// Three things are worth reading closely.
///
/// **Concurrency is declared, not hoped for.** Shutter presses are
/// [droppable]: a user hammering the button must produce one photograph per
/// completed capture, not a queue of twelve. Zoom events are [restartable]:
/// only the newest value matters, and a pinch produces dozens per second.
/// Everything else is [sequential]. Getting this wrong is the difference
/// between a camera that feels solid and one that duplicates frames.
///
/// **The sensor is released on pause.** Android hands the camera to whichever
/// app asked most recently; holding it while backgrounded means a phone call
/// leaves the user with a dead preview on return. [CameraPaused] disposes and
/// [CameraResumed] re-opens, and `previewKey` changes so the widget rebuilds
/// against the new controller rather than a disposed one.
///
/// **A batch is handed over, never shared.** On submit the shots are enqueued
/// and a *fresh* batch is started, so the sync engine and the camera can never
/// mutate the same list.
///
/// **The flash outlives the session.** A controller is thrown away on every
/// lens switch and every pause, and a new one does not inherit the old one's
/// flash mode — it starts at the plugin's own default. So the user's choice
/// lives on [CameraState.flashMode] and is re-applied to whatever controller
/// is open. [FlashPolicy] owns the rules; this class only obeys them.
class CameraBloc extends Bloc<CameraEvent, CameraState> {
  CameraBloc({
    required CameraPort camera,
    required PermissionGateway permissions,
    required EnqueueBatch enqueueBatch,
    Uuid? uuid,
    DateTime Function() clock = DateTime.now,
    // Four seconds, not the 1.2 it was. The reticle is now something the
    // user *operates* - a padlock to hit and a slider to drag - and a control
    // that disappears while you are reaching for it is not a control.
    Duration focusIndicatorDuration = const Duration(seconds: 4),
    FlashPolicy flashPolicy = FlashPolicy.standard,
    Duration zoomSettleDelay = defaultZoomSettleDelay,
  })  : _camera = camera,
        _permissions = permissions,
        _enqueueBatch = enqueueBatch,
        _uuid = uuid ?? const Uuid(),
        _clock = clock,
        _focusIndicatorDuration = focusIndicatorDuration,
        _flashPolicy = flashPolicy,
        _zoomSettleDelay = zoomSettleDelay,
        super(const CameraState()) {
    on<CameraStarted>(_onStarted, transformer: sequential());
    on<CameraPermissionRequested>(_onPermissionRequested, transformer: sequential());
    on<CameraSettingsRequested>(_onSettingsRequested, transformer: sequential());
    on<CameraPaused>(_onPaused, transformer: sequential());
    on<CameraResumed>(_onResumed, transformer: sequential());
    on<CameraLensSelected>(_onLensSelected, transformer: sequential());
    on<CameraZoomChanged>(_onZoomChanged, transformer: restartable());
    on<CameraZoomStopSelected>(_onZoomStopSelected, transformer: sequential());
    on<CameraPinchStarted>(_onPinchStarted, transformer: sequential());
    on<CameraPinchZoomed>(_onPinchZoomed, transformer: restartable());
    on<CameraZoomGestureEnded>(_onZoomGestureEnded, transformer: sequential());
    on<CameraZoomHandoverRequested>(_onZoomHandover, transformer: sequential());
    on<CameraFlashToggled>(_onFlashToggled, transformer: sequential());
    on<CameraGridToggled>(
      (CameraGridToggled event, Emitter<CameraState> emit) =>
          emit(state.copyWith(showsGrid: !state.showsGrid)),
    );
    on<CameraTorchTimedOut>(_onTorchTimedOut, transformer: sequential());
    on<CameraFocusRequested>(_onFocusRequested, transformer: restartable());
    on<CameraFocusLockToggled>(_onFocusLockToggled, transformer: sequential());
    on<CameraExposureOffsetChanged>(
      _onExposureOffsetChanged,
      // Like zoom: a drag emits dozens a second and only the newest matters.
      transformer: restartable(),
    );
    on<CameraFocusIndicatorExpired>(_onFocusExpired, transformer: sequential());
    on<CameraShutterPressed>(_onShutterPressed, transformer: droppable());
    on<CameraShotDiscarded>(_onShotDiscarded, transformer: sequential());
    on<CameraBatchSubmitted>(_onBatchSubmitted, transformer: droppable());
    on<CameraErrorDismissed>(
      (CameraErrorDismissed event, Emitter<CameraState> emit) =>
          emit(state.copyWith(clearNotice: true, clearFailure: true)),
    );
  }

  final CameraPort _camera;
  final PermissionGateway _permissions;
  final EnqueueBatch _enqueueBatch;
  final Uuid _uuid;
  final DateTime Function() _clock;
  final Duration _focusIndicatorDuration;
  final FlashPolicy _flashPolicy;

  /// Zoom the current pinch gesture is measured against.
  double _pinchBaseZoom = 1;

  /// How long the zoom must sit still before another camera is opened for it.
  ///
  /// A pinch produces dozens of values a second and a slider drag produces
  /// one per frame. Opening a sensor takes a few hundred milliseconds and
  /// blanks the preview while it does, so acting on every value that crosses
  /// 1.0x reopened the camera over and over - the "screen loads" flicker.
  /// Waiting for the finger to settle turns any number of crossings into
  /// exactly one hand-over, at the moment the user has decided where they
  /// want to be.
  static const Duration defaultZoomSettleDelay = Duration(milliseconds: 300);

  final Duration _zoomSettleDelay;

  /// Armed while a zoom is asking for a camera that is not the open one.
  Timer? _zoomSettle;

  /// The zoom that timer is waiting to deliver.
  double? _pendingEffectiveZoom;

  /// True from the moment a hand-over starts until the new sensor is live.
  ///
  /// Zoom values that arrive in that window are dropped rather than queued:
  /// they were measured against a camera that is already gone.
  bool _handoverInFlight = false;

  /// The torch's idle deadline, and the moment it was armed.
  ///
  /// A cancellable [Timer] rather than an awaited delay: the flash handler is
  /// [sequential], so awaiting a two-minute timeout inside it would stall
  /// every other sequential event behind it for two minutes.
  Timer? _torchDeadline;
  DateTime? _torchArmedAt;

  /// The reticle's dwell timer. A field rather than an awaited delay, because
  /// it has to be re-armed from the exposure handler and cancelled outright by
  /// the padlock.
  Timer? _reticleDeadline;

  Future<void> _onStarted(CameraStarted event, Emitter<CameraState> emit) async {
    emit(
      state.copyWith(
        phase: CameraPhase.initialising,
        batch: state.batch ?? _newBatch(),
        clearNotice: true,
      ),
    );

    final PermissionOutcome outcome = await _permissions.cameraStatus();
    if (outcome != PermissionOutcome.granted) {
      // Asking straight away rather than showing a pre-prompt: the screen has
      // exactly one purpose and the user opened it deliberately.
      return _requestPermissionThenOpen(emit);
    }

    await _openCamera(emit);
  }

  Future<void> _onPermissionRequested(
    CameraPermissionRequested event,
    Emitter<CameraState> emit,
  ) =>
      _requestPermissionThenOpen(emit);

  Future<void> _requestPermissionThenOpen(Emitter<CameraState> emit) async {
    final PermissionOutcome outcome = await _permissions.requestCamera();

    switch (outcome) {
      case PermissionOutcome.granted:
        await _openCamera(emit);
      case PermissionOutcome.denied:
        emit(
          state.copyWith(
            phase: CameraPhase.permissionRequired,
            notice: const CameraPermissionNotice(blocked: false),
          ),
        );
      case PermissionOutcome.blocked:
        emit(
          state.copyWith(
            phase: CameraPhase.permissionBlocked,
            notice: const CameraPermissionNotice(blocked: true),
          ),
        );
    }
  }

  Future<void> _onSettingsRequested(
    CameraSettingsRequested event,
    Emitter<CameraState> emit,
  ) async {
    await _permissions.openSettings();
  }

  Future<void> _openCamera(Emitter<CameraState> emit) async {
    emit(state.copyWith(phase: CameraPhase.initialising, clearNotice: true));

    final Result<CameraSession> result = await _camera.initialise();

    result.fold(
      (CameraSession session) => emit(
        state.copyWith(
          phase: CameraPhase.ready,
          session: session,
          batch: state.batch ?? _newBatch(),
          clearNotice: true,
          clearFailure: true,
        ),
      ),
      (Failure failure) => emit(_failureState(failure)),
    );

    if (state.isReady) await _restoreFlash(emit);
  }

  Future<void> _onPaused(CameraPaused event, Emitter<CameraState> emit) async {
    _cancelTorchDeadline();
    _cancelReticleDeadline();
    _cancelPendingHandover();
    await _camera.dispose();
    emit(
      state.copyWith(
        phase: CameraPhase.idle,
        clearSession: true,
        // A new controller starts at auto metering and 0 EV, so the state that
        // described the old one must not survive it.
        clearFocusPoint: true,
        isMeteringLocked: false,
        exposureOffset: 0,
        // Disposing the controller has already darkened the LED. Recording
        // that in the state is what stops the torch coming back lit on resume.
        flashMode: _flashPolicy.afterInterruption(state.flashMode),
      ),
    );
  }

  Future<void> _onResumed(CameraResumed event, Emitter<CameraState> emit) async {
    // Permission can have been revoked from Settings while we were away, so
    // resume goes through the same gate as a cold start rather than assuming.
    if (await _permissions.cameraStatus() != PermissionOutcome.granted) {
      emit(
        state.copyWith(
          phase: CameraPhase.permissionRequired,
          clearSession: true,
          notice: const CameraPermissionNotice(blocked: false),
        ),
      );
      return;
    }

    await _openCamera(emit);
  }

  Future<void> _onLensSelected(
    CameraLensSelected event,
    Emitter<CameraState> emit,
  ) async {
    if (!state.isReady) return;
    await _openLens(event.lens, emit);
  }

  /// Swaps the open sensor and re-applies the settings that outlive it.
  ///
  /// [handover] marks the case where the user did not ask for a *camera*, they
  /// asked for a zoom that only another camera can show. The work is identical
  /// either way; the flag only tells the UI not to throw a cold-start spinner
  /// over the chrome for it.
  Future<void> _openLens(
    CameraLens lens,
    Emitter<CameraState> emit, {
    bool handover = false,
  }) async {
    // A reticle belongs to a frame on a sensor, and that sensor is about to be
    // disposed. Left armed, its dwell timer would fire across the switch and
    // clear the *next* one.
    _cancelReticleDeadline();

    emit(
      state.copyWith(
        phase: CameraPhase.initialising,
        isSwitchingLens: handover,
      ),
    );

    final Result<CameraSession> result = await _camera.selectLens(lens);

    result.fold(
      (CameraSession session) => emit(
        state.copyWith(
          phase: CameraPhase.ready,
          session: session,
          isSwitchingLens: false,
          // The same rule [_onPaused] obeys, and for the same reason: a lens
          // switch throws the controller away and builds another, and a fresh
          // one starts at auto metering and 0 EV. Carrying these across left a
          // closed padlock drawn over a sensor that was not locked at all -
          // the inverse of the bug the padlock exists to prevent, and worse,
          // because the user has been told something untrue.
          clearFocusPoint: true,
          isMeteringLocked: false,
          exposureOffset: 0,
        ),
      ),
      (Failure failure) =>
          emit(_failureState(failure).copyWith(isSwitchingLens: false)),
    );

    if (state.isReady) await _restoreFlash(emit);
  }

  Future<void> _onZoomChanged(
    CameraZoomChanged event,
    Emitter<CameraState> emit,
  ) async {
    // The slider is a drag: treat it like the pinch and let the value settle
    // before opening anything.
    await _applyEffectiveZoom(event.zoom, emit, continuous: true);
  }

  /// A quick-zoom button. Its ratio is an *effective* zoom, exactly like the
  /// slider's, so both go through the same placement.
  Future<void> _onZoomStopSelected(
    CameraZoomStopSelected event,
    Emitter<CameraState> emit,
  ) async {
    // A tap is a decision, not a drag. There is nothing to wait for.
    await _applyEffectiveZoom(event.stop.ratio, emit, continuous: false);
  }

  /// The finger left the glass.
  ///
  /// Whatever the gesture was reaching for, now is the moment to go and get
  /// it: no more values are coming, so a hand-over here cannot be undone by
  /// the next one.
  Future<void> _onZoomGestureEnded(
    CameraZoomGestureEnded event,
    Emitter<CameraState> emit,
  ) async {
    final double? pending = _pendingEffectiveZoom;
    _cancelPendingHandover();
    if (pending == null) return;

    add(CameraZoomHandoverRequested(pending));
  }

  /// Opens the camera a zoom needs, then sets it there.
  ///
  /// Resolves the placement again from current state rather than trusting the
  /// event: by the time this runs the open camera may already be the right
  /// one, and re-asking is cheaper than reasoning about whether it is.
  Future<void> _onZoomHandover(
    CameraZoomHandoverRequested event,
    Emitter<CameraState> emit,
  ) async {
    if (!state.isReady) return;

    final ZoomPlacement placement = state.zoomSpan.place(event.effective);

    if (placement.lens.id == state.session?.activeLens.id) {
      await _applyZoom(placement.sensorZoom, emit);
      return;
    }

    _handoverInFlight = true;
    try {
      await _openLens(placement.lens, emit, handover: true);
      if (!state.isReady) return;

      // The new sensor reports its own band, so the same request has to be
      // resolved again against it - on an ultra-wide, the user's 0.5x is that
      // camera's own 1.0.
      await _applyZoom(state.zoomSpan.place(event.effective).sensorZoom, emit);
    } finally {
      _handoverInFlight = false;
    }
  }

  Future<void> _onPinchStarted(
    CameraPinchStarted event,
    Emitter<CameraState> emit,
  ) async {
    _pinchBaseZoom = state.effectiveZoom;
    // A new gesture supersedes whatever the last one was about to do.
    _cancelPendingHandover();
  }

  Future<void> _onPinchZoomed(
    CameraPinchZoomed event,
    Emitter<CameraState> emit,
  ) async {
    // Multiplying the gesture scale by the zoom the pinch *started* from is
    // what makes the gesture feel anchored. Multiplying by the current zoom
    // instead compounds every frame and the preview rockets to maximum.
    await _applyEffectiveZoom(
      _pinchBaseZoom * event.scale,
      emit,
      continuous: true,
    );
  }

  /// Sets the zoom the *user* asked for, opening another rear camera first if
  /// that is the only way to reach it.
  ///
  /// The slider, the pinch and the quick-zoom pills all speak effective zoom -
  /// the field of view relative to the main camera - because that is what
  /// "0.5x" means to the person holding the phone. [ZoomSpan] owns the two
  /// rules that turn it back into a camera and a sensor zoom; this method only
  /// obeys them.
  Future<void> _applyEffectiveZoom(
    double effective,
    Emitter<CameraState> emit, {
    required bool continuous,
  }) async {
    // A value measured against a camera that is being replaced is meaningless
    // by the time it could be applied.
    if (!state.isReady || _handoverInFlight) return;

    final ZoomSpan span = state.zoomSpan;
    final ZoomPlacement placement = span.place(effective);
    final bool needsAnotherCamera =
        placement.lens.id != state.session?.activeLens.id;

    if (!needsAnotherCamera) {
      _cancelPendingHandover();
      await _applyZoom(placement.sensorZoom, emit);
      return;
    }

    if (!continuous) {
      add(CameraZoomHandoverRequested(effective));
      return;
    }

    // Mid-gesture. Go as far as the open camera can honestly go and remember
    // where the finger actually wanted to be, rather than blanking the preview
    // under a moving thumb.
    _pendingEffectiveZoom = effective;
    _zoomSettle?.cancel();
    _zoomSettle = Timer(_zoomSettleDelay, () {
      if (isClosed) return;
      add(const CameraZoomGestureEnded());
    });

    await _applyZoom(span.active.sensorZoomFor(effective), emit);
  }

  void _cancelPendingHandover() {
    _zoomSettle?.cancel();
    _zoomSettle = null;
    _pendingEffectiveZoom = null;
  }

  Future<void> _applyZoom(double requested, Emitter<CameraState> emit) async {
    final CameraSession? session = state.session;
    if (session == null) return;

    final CameraSettings settings = session.settings;
    final double clamped =
        requested.clamp(settings.minZoom, settings.maxZoom).toDouble();

    // A pinch held against either end of the range produces dozens of
    // identical values a second, and every one of them used to cross the
    // platform channel to set the zoom it was already at. The sensor ignores
    // the write; the wake-ups are pure battery. Nothing has moved, so there is
    // nothing to say.
    if (clamped == settings.zoom) return;

    // Optimistic: the slider must track the finger, not the platform channel.
    emit(
      state.copyWith(
        session: session.copyWith(settings: settings.copyWith(zoom: clamped)),
      ),
    );

    final Result<void> result = await _camera.setZoom(clamped);
    final Failure? failure = result.failureOrNull;
    if (failure != null) emit(_failureState(failure));
  }

  Future<void> _onFlashToggled(
    CameraFlashToggled event,
    Emitter<CameraState> emit,
  ) async {
    if (state.session == null) return;
    await _applyFlashMode(_flashPolicy.next(state.flashMode), emit);
  }

  Future<void> _onTorchTimedOut(
    CameraTorchTimedOut event,
    Emitter<CameraState> emit,
  ) async {
    // Only the deadline belonging to the torch that is currently lit may put
    // it out. Toggling the torch off and straight back on arms a new one, and
    // the older timer must not darken its successor.
    if (event.armedAt != _torchArmedAt) return;
    if (!_flashPolicy.drawsContinuously(state.flashMode)) return;

    await _applyFlashMode(
      CaptureFlashMode.off,
      emit,
      notice: const TorchTimedOutNotice(),
    );
  }

  /// Re-applies the user's chosen mode to a freshly opened controller.
  ///
  /// Called after *every* successful open, including when the chosen mode is
  /// `off`. A new `CameraController` does not start where the last one left
  /// off — it starts at the plugin's own default, which is `auto` — so
  /// skipping this for `off` would leave the hardware firing a flash while the
  /// button on screen reads "off".
  Future<void> _restoreFlash(Emitter<CameraState> emit) =>
      _applyFlashMode(state.flashMode, emit);

  /// The single path through which the flash ever changes.
  ///
  /// Optimistic, like zoom: the icon must answer the tap immediately rather
  /// than wait for a platform channel. If the sensor then refuses the mode,
  /// the state is corrected back to `off` — showing a lit flash icon over a
  /// dark LED is worse than showing nothing.
  Future<void> _applyFlashMode(
    CaptureFlashMode mode,
    Emitter<CameraState> emit, {
    CameraNotice? notice,
  }) async {
    emit(
      notice == null
          ? state.copyWith(flashMode: mode)
          : state.copyWith(flashMode: mode, notice: notice),
    );

    final Failure? failure = (await _camera.setFlashMode(mode)).failureOrNull;

    if (failure == null) {
      if (_flashPolicy.drawsContinuously(mode)) {
        _armTorchDeadline();
      } else {
        _cancelTorchDeadline();
      }
      return;
    }

    _cancelTorchDeadline();

    if (failure is FlashUnavailableFailure) {
      // This sensor has no LED. Retrying will not grow one, so say so once and
      // fall back rather than leaving the UI in a state the hardware refused.
      emit(
        state.copyWith(
          flashMode: CaptureFlashMode.off,
          notice: const CameraFlashUnavailableNotice(),
          lastFailure: failure,
        ),
      );
      return;
    }

    emit(_failureState(failure));
  }

  void _armTorchDeadline() {
    _cancelTorchDeadline();
    final DateTime armedAt = _clock();
    _torchArmedAt = armedAt;
    _torchDeadline = Timer(_flashPolicy.torchIdleTimeout, () {
      if (!isClosed) add(CameraTorchTimedOut(armedAt));
    });
  }

  void _cancelTorchDeadline() {
    _torchDeadline?.cancel();
    _torchDeadline = null;
    _torchArmedAt = null;
  }

  Future<void> _onFocusRequested(
    CameraFocusRequested event,
    Emitter<CameraState> emit,
  ) async {
    if (!state.isReady) return;

    final FocusPoint point = FocusPoint(
      x: event.x.clamp(0.0, 1.0),
      y: event.y.clamp(0.0, 1.0),
      requestedAt: _clock(),
    );

    final bool wasLocked = state.isMeteringLocked;
    final bool hadOffset = state.exposureOffset != 0;

    // The reticle appears immediately, before the platform confirms. A focus
    // indicator that waits for the hardware feels broken even when it works.
    //
    // A tap elsewhere is a *new metering decision*, so it releases any lock and
    // returns the brightness to neutral: both of those belonged to the old
    // point, and carrying them to a new one is how a user ends up with a whole
    // batch exposed for a subject they stopped photographing.
    emit(
      state.copyWith(
        focusPoint: point,
        isMeteringLocked: false,
        exposureOffset: 0,
      ),
    );

    if (wasLocked) await _camera.setMeteringLocked(false);
    if (hadOffset) await _camera.setExposureOffset(0);

    final Result<void> result = await _camera.focusAt(point);
    final Failure? failure = result.failureOrNull;
    if (failure != null && failure is! CameraOperationFailure) {
      emit(_failureState(failure));
    }

    _armReticleDeadline(point.requestedAt);
  }

  /// The padlock.
  Future<void> _onFocusLockToggled(
    CameraFocusLockToggled event,
    Emitter<CameraState> emit,
  ) async {
    // Nothing to lock onto without a metering point; the padlock is only ever
    // rendered attached to a reticle, so this is belt and braces.
    if (!state.isReady || state.focusPoint == null) return;

    final bool locked = !state.isMeteringLocked;
    emit(state.copyWith(isMeteringLocked: locked));

    final Failure? failure = (await _camera.setMeteringLocked(locked)).failureOrNull;

    if (failure != null) {
      // Showing a closed padlock over metering that is still drifting is worse
      // than showing nothing, so the state goes back rather than staying
      // optimistic.
      emit(
        _failureState(failure).copyWith(isMeteringLocked: !locked),
      );
      _armReticleDeadline(state.focusPoint!.requestedAt);
      return;
    }

    if (locked) {
      // A lock the user cannot see is a lock they will forget they set, so the
      // reticle loses its deadline for as long as the lock is on.
      _cancelReticleDeadline();
    } else {
      _armReticleDeadline(state.focusPoint!.requestedAt);
    }
  }

  /// The brightness slider under the reticle.
  Future<void> _onExposureOffsetChanged(
    CameraExposureOffsetChanged event,
    Emitter<CameraState> emit,
  ) async {
    if (!state.isReady) return;

    final ExposureRange range = state.exposureRange;
    if (!range.canAdjust) return;

    // Snapped to the sensor's own EV grid before anything else looks at it, so
    // the slider and the hardware can never disagree about where it is.
    final double ev = range.normalise(event.ev);

    // Same argument as zoom: a finger held at either end of the track produces
    // dozens of identical values a second, and the sensor ignores every one.
    if (ev == state.exposureOffset) return;

    emit(state.copyWith(exposureOffset: ev));

    // Dragging is interaction. Without this the reticle - and the slider the
    // user is currently holding - vanishes mid-gesture.
    if (!state.isMeteringLocked && state.focusPoint != null) {
      _armReticleDeadline(state.focusPoint!.requestedAt);
    }

    final Failure? failure = (await _camera.setExposureOffset(ev)).failureOrNull;
    if (failure != null) emit(_failureState(failure));
  }

  Future<void> _onFocusExpired(
    CameraFocusIndicatorExpired event,
    Emitter<CameraState> emit,
  ) async {
    // A locked reticle has no deadline. The lock is the user's to release.
    if (state.isMeteringLocked) return;

    // Only clear the reticle this event was scheduled for; a newer tap must
    // keep its own indicator.
    if (state.focusPoint?.requestedAt != event.requestedAt) return;

    final bool hadOffset = state.exposureOffset != 0;
    emit(state.copyWith(clearFocusPoint: true, exposureOffset: 0));

    // The brightness belonged to the metering point that has just gone. Leaving
    // it applied would be an invisible setting - the one thing a camera must
    // never have.
    if (hadOffset) await _camera.setExposureOffset(0);
  }

  void _armReticleDeadline(DateTime token) {
    _cancelReticleDeadline();
    _reticleDeadline = Timer(_focusIndicatorDuration, () {
      if (!isClosed) add(CameraFocusIndicatorExpired(token));
    });
  }

  void _cancelReticleDeadline() {
    _reticleDeadline?.cancel();
    _reticleDeadline = null;
  }

  Future<void> _onShutterPressed(
    CameraShutterPressed event,
    Emitter<CameraState> emit,
  ) async {
    if (!state.isReady || state.isCapturing) return;

    emit(state.copyWith(isCapturing: true, clearNotice: true));

    final Result<CapturedShot> result =
        await _camera.capture(zoomLevel: state.settings.zoom);

    result.fold(
      (CapturedShot shot) {
        final CaptureBatch batch = (state.batch ?? _newBatch()).add(shot);
        emit(state.copyWith(isCapturing: false, batch: batch));
      },
      (Failure failure) => emit(
        _failureState(failure).copyWith(isCapturing: false),
      ),
    );
  }

  Future<void> _onShotDiscarded(
    CameraShotDiscarded event,
    Emitter<CameraState> emit,
  ) async {
    final CaptureBatch? batch = state.batch;
    if (batch == null) return;

    final CapturedShot? shot = batch.shots
        .cast<CapturedShot?>()
        .firstWhere((CapturedShot? s) => s?.id == event.shotId, orElse: () => null);
    if (shot == null) return;

    // The list first, so the grid answers the tap immediately; the file after,
    // because the user is not waiting on a filesystem unlink.
    emit(state.copyWith(batch: batch.removeById(event.shotId)));
    await _camera.discard(shot);
  }

  Future<void> _onBatchSubmitted(
    CameraBatchSubmitted event,
    Emitter<CameraState> emit,
  ) async {
    final CaptureBatch? batch = state.batch;
    if (batch == null || batch.isEmpty || state.isSubmitting) return;

    emit(state.copyWith(isSubmitting: true, clearNotice: true));

    final Result<int> result = await _enqueueBatch(batch);

    result.fold(
      (int count) => emit(
        state.copyWith(
          isSubmitting: false,
          // A brand-new batch: the handed-over shots now belong to the queue,
          // and the camera must not keep a mutable reference to them.
          batch: _newBatch(),
          notice: BatchQueuedNotice(count),
        ),
      ),
      (Failure failure) => emit(
        state.copyWith(
          isSubmitting: false,
          notice: const CameraStorageNotice(),
          lastFailure: failure,
        ),
      ),
    );
  }

  CaptureBatch _newBatch() => CaptureBatch(id: _uuid.v4(), startedAt: _clock());

  CameraState _failureState(Failure failure) => switch (failure) {
        PermissionDeniedFailure() => state.copyWith(
            phase: CameraPhase.permissionRequired,
            clearSession: true,
            notice: const CameraPermissionNotice(blocked: false),
            lastFailure: failure,
          ),
        PermissionPermanentlyDeniedFailure() || PermissionRestrictedFailure() =>
          state.copyWith(
            phase: CameraPhase.permissionBlocked,
            clearSession: true,
            notice: const CameraPermissionNotice(blocked: true),
            lastFailure: failure,
          ),
        CameraUnavailableFailure() => state.copyWith(
            phase: CameraPhase.unavailable,
            clearSession: true,
            notice: const CameraHardwareNotice('no-camera'),
            lastFailure: failure,
          ),
        CameraInterruptedFailure() => state.copyWith(
            phase: CameraPhase.idle,
            clearSession: true,
            notice: const CameraHardwareNotice('interrupted'),
            lastFailure: failure,
          ),
        StorageWriteFailure() || StorageReadFailure() => state.copyWith(
            notice: const CameraStorageNotice(),
            lastFailure: failure,
          ),
        _ => state.copyWith(
            notice: const CameraHardwareNotice('operation-failed'),
            lastFailure: failure,
          ),
      };

  @override
  Future<void> close() async {
    // Before the sensor goes, so a pending deadline cannot fire an event into
    // a closed Bloc.
    _cancelTorchDeadline();
    _cancelReticleDeadline();
    await _camera.dispose();
    return super.close();
  }
}
