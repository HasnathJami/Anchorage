import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/capture_batch.dart';
import 'package:anchorage_harbor/domain/entities/exposure_range.dart';
import 'package:anchorage_harbor/domain/entities/zoom_range.dart';
import 'package:anchorage_harbor/domain/entities/zoom_span.dart';
import 'package:anchorage_harbor/domain/entities/zoom_stop.dart';
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
    this.isMeteringLocked = false,
    this.isSwitchingLens = false,
    this.exposureOffset = 0,
    this.flashMode = CaptureFlashMode.off,
    this.showsGrid = false,
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

  /// The reticle position, cleared after a short dwell - unless the metering
  /// is locked, in which case it stays until the user unlocks it.
  final FocusPoint? focusPoint;

  /// Focus and exposure are held where the user put them.
  ///
  /// Belongs beside [focusPoint] rather than on the session: a lock is about a
  /// point on a frame, and both die when the sensor is released.
  final bool isMeteringLocked;

  /// A rear camera is being handed over to another one.
  ///
  /// Distinct from a cold start even though both leave the app briefly without
  /// a sensor, because they deserve different screens. A cold start has earned
  /// a spinner; a hand-over between two rear cameras is a few hundred
  /// milliseconds in the middle of a gesture, and covering the chrome with a
  /// full-screen loading state for it is the "screen loads" flicker that
  /// pinching past 1x used to produce.
  final bool isSwitchingLens;

  /// Exposure compensation in EV, as set by the brightness slider.
  final double exposureOffset;

  /// The flash mode the *user* has chosen.
  ///
  /// Deliberately outside [session]: the session is destroyed every time the
  /// sensor is released, and this must not be. It is re-applied to each new
  /// controller, which is what stops a chosen mode from quietly reverting to
  /// off after a lens switch or a trip to another app.
  final CaptureFlashMode flashMode;

  /// Rule-of-thirds overlay. A user preference like [flashMode], so it also
  /// lives outside the session and survives every sensor restart.
  final bool showsGrid;

  final bool isCapturing;
  final bool isSubmitting;
  final CameraNotice? notice;
  final Failure? lastFailure;

  bool get isReady => phase == CameraPhase.ready && session != null;

  int get shotCount => batch?.count ?? 0;

  bool get hasShots => shotCount > 0;

  CameraSettings get settings => session?.settings ?? CameraSettings.initial;

  List<CameraLens> get lenses => session?.availableLenses ?? const <CameraLens>[];

  /// The rear sensors. The front camera is reached from the flip button, never
  /// from the zoom row, so it is excluded here.
  List<CameraLens> get backLenses => lenses
      .where((CameraLens lens) => lens.kind != CameraLensKind.front)
      .toList(growable: false);

  bool get isFrontFacing =>
      session?.activeLens.kind == CameraLensKind.front ||
      settings.isFrontFacing;

  /// Every rear camera on one scale, so the slider and the pills can speak in
  /// the numbers the user means rather than in the open sensor's own.
  ZoomSpan get zoomSpan => ZoomSpan.across(
        lenses: backLenses,
        activeLens: session?.activeLens ?? _fallbackLens,
        activeRange: ZoomRange(min: settings.minZoom, max: settings.maxZoom),
      );

  /// A camera with no session yet still has to answer "what zoom am I at?".
  static const CameraLens _fallbackLens = CameraLens(
    id: '',
    zoomFactor: 1,
    label: '1',
    kind: CameraLensKind.wide,
  );

  /// The zoom the user is actually looking at: the open lens's own zoom scaled
  /// by what that lens sees. On an ultra-wide, 1.0 of sensor zoom is 0.5x.
  double get effectiveZoom => zoomSpan.effectiveOf(settings.zoom);

  /// What the *device* can reach, across every rear camera — not just the one
  /// that happens to be open.
  ///
  /// On most phones this is simply the open camera's range, because the
  /// platform publishes one logical rear camera that already spans every
  /// sensor. On the minority that publish each sensor separately it is wider,
  /// and the difference matters: there, the main camera stops at 1x, so a row
  /// built from its range alone would never show a 0.5 button and the
  /// lens-switching fallback behind that button could never be reached.
  ZoomRange get reachableZoomRange => zoomSpan.offered;

  /// The `0.5 / 1 / 2` buttons, derived from what the device can actually
  /// reach rather than from how many cameras the platform happens to list.
  List<ZoomStop> get zoomStops => ZoomLadder.forRange(
        minZoom: reachableZoomRange.min,
        maxZoom: reachableZoomRange.max,
      );

  /// Which of [zoomStops] is currently lit.
  ZoomStop? get activeZoomStop => ZoomLadder.activeStop(zoomStops, effectiveZoom);

  /// What the open sensor will accept as exposure compensation.
  ExposureRange get exposureRange => session?.exposureRange ?? ExposureRange.fixed;

  bool get canSubmitBatch => hasShots && !isSubmitting && !isCapturing;

  CameraState copyWith({
    CameraPhase? phase,
    CameraSession? session,
    bool clearSession = false,
    CaptureBatch? batch,
    FocusPoint? focusPoint,
    bool clearFocusPoint = false,
    bool? isMeteringLocked,
    bool? isSwitchingLens,
    double? exposureOffset,
    CaptureFlashMode? flashMode,
    bool? showsGrid,
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
      isMeteringLocked: isMeteringLocked ?? this.isMeteringLocked,
      isSwitchingLens: isSwitchingLens ?? this.isSwitchingLens,
      exposureOffset: exposureOffset ?? this.exposureOffset,
      flashMode: flashMode ?? this.flashMode,
      showsGrid: showsGrid ?? this.showsGrid,
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
        isMeteringLocked,
        isSwitchingLens,
        exposureOffset,
        flashMode,
        showsGrid,
        isCapturing,
        isSubmitting,
        notice,
        lastFailure,
      ];
}
