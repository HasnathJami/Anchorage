import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/capture_batch.dart';
import 'package:anchorage_harbor/domain/services/camera_port.dart';
import 'package:equatable/equatable.dart';

/// Where the camera screen is in its lifecycle.
enum CameraPhase {
  /// Nothing has been asked for yet.
  idle,

  /// Opening the sensor.
  initialising,

  /// Live preview running.
  ready,

  /// Permission has not been granted; the dialog can still be shown.
  permissionRequired,

  /// Permission is permanently denied or policy-blocked; Settings only.
  permissionBlocked,

  /// The camera is unusable on this device or was taken away.
  unavailable,
}

/// A message worth putting in front of the user, with the remedy attached.
///
/// Modelled as data rather than a formatted string so the same notice can
/// render as a banner and as a semantics announcement without the two drifting.
sealed class CameraNotice extends Equatable {
  const CameraNotice();

  @override
  List<Object?> get props => <Object?>[runtimeType];
}

final class CameraPermissionNotice extends CameraNotice {
  const CameraPermissionNotice({required this.blocked});

  final bool blocked;

  @override
  List<Object?> get props => <Object?>[blocked];
}

final class CameraHardwareNotice extends CameraNotice {
  const CameraHardwareNotice(this.detail);

  final String detail;

  @override
  List<Object?> get props => <Object?>[detail];
}

final class CameraStorageNotice extends CameraNotice {
  const CameraStorageNotice();
}

/// The chosen flash mode is not available on the sensor that is open.
final class CameraFlashUnavailableNotice extends CameraNotice {
  const CameraFlashUnavailableNotice();
}

/// The torch switched itself off after its idle deadline.
///
/// Announced rather than done silently: a light going out on its own is
/// confusing unless the app says it was deliberate.
final class TorchTimedOutNotice extends CameraNotice {
  const TorchTimedOutNotice();
}

final class BatchQueuedNotice extends CameraNotice {
  const BatchQueuedNotice(this.count);

  final int count;

  @override
  List<Object?> get props => <Object?>[count];
}

class CameraState extends Equatable {
  const CameraState({
    this.phase = CameraPhase.idle,
    this.session,
    this.batch,
    this.focusPoint,
    this.flashMode = CaptureFlashMode.off,
    this.isCapturing = false,
    this.isSubmitting = false,
    this.notice,
    this.lastFailure,
  });

  final CameraPhase phase;

  /// Null until the sensor is open; the widget layer must not assume a
  /// preview exists just because the screen is mounted.
  final CameraSession? session;

  final CaptureBatch? batch;

  /// The reticle position, cleared after a short dwell.
  final FocusPoint? focusPoint;

  /// The flash mode the *user* has chosen.
  ///
  /// Deliberately outside [session]: the session is destroyed every time the
  /// sensor is released, and this must not be. It is re-applied to each new
  /// controller, which is what stops a chosen mode from quietly reverting to
  /// off after a lens switch or a trip to another app.
  final CaptureFlashMode flashMode;

  final bool isCapturing;
  final bool isSubmitting;
  final CameraNotice? notice;
  final Failure? lastFailure;

  bool get isReady => phase == CameraPhase.ready && session != null;

  int get shotCount => batch?.count ?? 0;

  bool get hasShots => shotCount > 0;

  CameraSettings get settings => session?.settings ?? CameraSettings.initial;

  List<CameraLens> get lenses => session?.availableLenses ?? const <CameraLens>[];

  /// Only the back cameras get a zoom pill; the front camera is reached from
  /// the flip button instead, matching the reference design.
  List<CameraLens> get selectableLenses => lenses
      .where((CameraLens lens) => lens.kind != CameraLensKind.front)
      .toList(growable: false);

  bool get canSubmitBatch => hasShots && !isSubmitting && !isCapturing;

  CameraState copyWith({
    CameraPhase? phase,
    CameraSession? session,
    bool clearSession = false,
    CaptureBatch? batch,
    FocusPoint? focusPoint,
    bool clearFocusPoint = false,
    CaptureFlashMode? flashMode,
    bool? isCapturing,
    bool? isSubmitting,
    CameraNotice? notice,
    bool clearNotice = false,
    Failure? lastFailure,
    bool clearFailure = false,
  }) {
    return CameraState(
      phase: phase ?? this.phase,
      session: clearSession ? null : (session ?? this.session),
      batch: batch ?? this.batch,
      focusPoint: clearFocusPoint ? null : (focusPoint ?? this.focusPoint),
      flashMode: flashMode ?? this.flashMode,
      isCapturing: isCapturing ?? this.isCapturing,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      notice: clearNotice ? null : (notice ?? this.notice),
      lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
    );
  }

  @override
  List<Object?> get props => <Object?>[
        phase,
        session?.previewKey,
        session?.settings,
        session?.activeLens,
        batch,
        focusPoint,
        flashMode,
        isCapturing,
        isSubmitting,
        notice,
        lastFailure,
      ];
}
