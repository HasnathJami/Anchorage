import 'dart:async';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/permissions/permission_gateway.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/features/capture/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/features/capture/domain/entities/capture_batch.dart';
import 'package:anchorage_harbor/features/capture/domain/services/camera_port.dart';
import 'package:anchorage_harbor/features/capture/presentation/bloc/camera_event.dart';
import 'package:anchorage_harbor/features/capture/presentation/bloc/camera_state.dart';
import 'package:anchorage_harbor/features/sync/domain/usecases/sync_use_cases.dart';
import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:uuid/uuid.dart';

// Barrel: consumers import the Bloc and get its events and state with it.
export 'package:anchorage_harbor/features/capture/presentation/bloc/camera_event.dart';
export 'package:anchorage_harbor/features/capture/presentation/bloc/camera_state.dart';

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
class CameraBloc extends Bloc<CameraEvent, CameraState> {
  CameraBloc({
    required CameraPort camera,
    required PermissionGateway permissions,
    required EnqueueBatch enqueueBatch,
    Uuid? uuid,
    DateTime Function() clock = DateTime.now,
    Duration focusIndicatorDuration = const Duration(milliseconds: 1200),
  })  : _camera = camera,
        _permissions = permissions,
        _enqueueBatch = enqueueBatch,
        _uuid = uuid ?? const Uuid(),
        _clock = clock,
        _focusIndicatorDuration = focusIndicatorDuration,
        super(const CameraState()) {
    on<CameraStarted>(_onStarted, transformer: sequential());
    on<CameraPermissionRequested>(_onPermissionRequested, transformer: sequential());
    on<CameraSettingsRequested>(_onSettingsRequested, transformer: sequential());
    on<CameraPaused>(_onPaused, transformer: sequential());
    on<CameraResumed>(_onResumed, transformer: sequential());
    on<CameraLensSelected>(_onLensSelected, transformer: sequential());
    on<CameraZoomChanged>(_onZoomChanged, transformer: restartable());
    on<CameraPinchStarted>(_onPinchStarted, transformer: sequential());
    on<CameraPinchZoomed>(_onPinchZoomed, transformer: restartable());
    on<CameraFlashToggled>(_onFlashToggled, transformer: sequential());
    on<CameraFocusRequested>(_onFocusRequested, transformer: restartable());
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

  /// Zoom the current pinch gesture is measured against.
  double _pinchBaseZoom = 1;

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
  }

  Future<void> _onPaused(CameraPaused event, Emitter<CameraState> emit) async {
    await _camera.dispose();
    emit(state.copyWith(phase: CameraPhase.idle, clearSession: true));
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

    emit(state.copyWith(phase: CameraPhase.initialising));
    final Result<CameraSession> result = await _camera.selectLens(event.lens);

    result.fold(
      (CameraSession session) =>
          emit(state.copyWith(phase: CameraPhase.ready, session: session)),
      (Failure failure) => emit(_failureState(failure)),
    );
  }

  Future<void> _onZoomChanged(
    CameraZoomChanged event,
    Emitter<CameraState> emit,
  ) async {
    await _applyZoom(event.zoom, emit);
  }

  Future<void> _onPinchStarted(
    CameraPinchStarted event,
    Emitter<CameraState> emit,
  ) async {
    _pinchBaseZoom = state.settings.zoom;
  }

  Future<void> _onPinchZoomed(
    CameraPinchZoomed event,
    Emitter<CameraState> emit,
  ) async {
    // Multiplying the gesture scale by the zoom the pinch *started* from is
    // what makes the gesture feel anchored. Multiplying by the current zoom
    // instead compounds every frame and the preview rockets to maximum.
    await _applyZoom(_pinchBaseZoom * event.scale, emit);
  }

  Future<void> _applyZoom(double requested, Emitter<CameraState> emit) async {
    final CameraSession? session = state.session;
    if (session == null) return;

    final CameraSettings settings = session.settings;
    final double clamped =
        requested.clamp(settings.minZoom, settings.maxZoom).toDouble();

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
    final CameraSession? session = state.session;
    if (session == null) return;

    const List<CaptureFlashMode> cycle = <CaptureFlashMode>[
      CaptureFlashMode.off,
      CaptureFlashMode.auto,
      CaptureFlashMode.always,
    ];
    final int next =
        (cycle.indexOf(session.settings.flashMode) + 1) % cycle.length;
    final CaptureFlashMode mode = cycle[next];

    emit(
      state.copyWith(
        session: session.copyWith(settings: session.settings.copyWith(flashMode: mode)),
      ),
    );

    final Result<void> result = await _camera.setFlashMode(mode);
    final Failure? failure = result.failureOrNull;
    if (failure != null) emit(_failureState(failure));
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

    // The reticle appears immediately, before the platform confirms. A focus
    // indicator that waits for the hardware feels broken even when it works.
    emit(state.copyWith(focusPoint: point));

    final Result<void> result = await _camera.focusAt(point);
    final Failure? failure = result.failureOrNull;
    if (failure != null && failure is! CameraOperationFailure) {
      emit(_failureState(failure));
    }

    await Future<void>.delayed(_focusIndicatorDuration);
    add(CameraFocusIndicatorExpired(point.requestedAt));
  }

  void _onFocusExpired(
    CameraFocusIndicatorExpired event,
    Emitter<CameraState> emit,
  ) {
    // Only clear the reticle this event was scheduled for; a newer tap must
    // keep its own indicator.
    if (state.focusPoint?.requestedAt == event.requestedAt) {
      emit(state.copyWith(clearFocusPoint: true));
    }
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

  void _onShotDiscarded(CameraShotDiscarded event, Emitter<CameraState> emit) {
    final CaptureBatch? batch = state.batch;
    if (batch == null) return;
    emit(state.copyWith(batch: batch.removeById(event.shotId)));
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
    await _camera.dispose();
    return super.close();
  }
}
