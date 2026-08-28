import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/features/capture/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/features/capture/domain/entities/capture_batch.dart';
import 'package:anchorage_harbor/features/capture/domain/services/camera_port.dart';
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
        isCapturing,
        isSubmitting,
        notice,
        lastFailure,
      ];
}
