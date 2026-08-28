import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:equatable/equatable.dart';

/// Everything the user (or the OS) can do to the camera screen.
///
/// Lifecycle events are first-class members here rather than side channels:
/// on Android the sensor is reclaimed the moment the app is backgrounded, so
/// "the app was paused" is as much an input to this Bloc as "the shutter was
/// tapped", and modelling it any other way produces the classic black-preview-
/// on-resume bug.
sealed class CameraEvent extends Equatable {
  const CameraEvent();

  @override
  List<Object?> get props => <Object?>[];
}

/// Screen mounted: check permission, then open the camera.
final class CameraStarted extends CameraEvent {
  const CameraStarted();
}

/// The user answered the permission prompt (or we asked again).
final class CameraPermissionRequested extends CameraEvent {
  const CameraPermissionRequested();
}

/// Send the user to system settings after a permanent denial.
final class CameraSettingsRequested extends CameraEvent {
  const CameraSettingsRequested();
}

/// App went to the background - release the sensor for other apps.
final class CameraPaused extends CameraEvent {
  const CameraPaused();
}

/// App came back - re-acquire the sensor and rebuild the preview.
final class CameraResumed extends CameraEvent {
  const CameraResumed();
}

final class CameraLensSelected extends CameraEvent {
  const CameraLensSelected(this.lens);

  final CameraLens lens;

  @override
  List<Object?> get props => <Object?>[lens];
}

/// Absolute zoom, from the slider or a lens pill.
final class CameraZoomChanged extends CameraEvent {
  const CameraZoomChanged(this.zoom);

  final double zoom;

  @override
  List<Object?> get props => <Object?>[zoom];
}

/// Relative zoom from a pinch gesture; [scale] is the gesture's cumulative
/// scale since it began.
final class CameraPinchZoomed extends CameraEvent {
  const CameraPinchZoomed(this.scale);

  final double scale;

  @override
  List<Object?> get props => <Object?>[scale];
}

/// Pinch started - the Bloc records the zoom the gesture is relative to.
final class CameraPinchStarted extends CameraEvent {
  const CameraPinchStarted();
}

final class CameraFlashToggled extends CameraEvent {
  const CameraFlashToggled();
}

/// Tap-to-focus at a normalised preview coordinate.
final class CameraFocusRequested extends CameraEvent {
  const CameraFocusRequested({required this.x, required this.y});

  final double x;
  final double y;

  @override
  List<Object?> get props => <Object?>[x, y];
}

/// The focus reticle's dwell time elapsed.
final class CameraFocusIndicatorExpired extends CameraEvent {
  const CameraFocusIndicatorExpired(this.requestedAt);

  final DateTime requestedAt;

  @override
  List<Object?> get props => <Object?>[requestedAt];
}

final class CameraShutterPressed extends CameraEvent {
  const CameraShutterPressed();
}

/// Remove a shot from the working batch before it is handed to the queue.
final class CameraShotDiscarded extends CameraEvent {
  const CameraShotDiscarded(this.shotId);

  final String shotId;

  @override
  List<Object?> get props => <Object?>[shotId];
}

/// Hand the current batch to the sync engine and start a fresh one.
final class CameraBatchSubmitted extends CameraEvent {
  const CameraBatchSubmitted();
}

/// Dismiss the inline error banner.
final class CameraErrorDismissed extends CameraEvent {
  const CameraErrorDismissed();
}

/// The torch's idle deadline elapsed.
///
/// Carries [armedAt] for the same reason [CameraFocusIndicatorExpired] carries
/// its timestamp: a deadline that fires must only switch off the torch it was
/// scheduled for. Without the token, toggling the torch off and straight back
/// on would leave an older timer in flight that darkens the new one early.
final class CameraTorchTimedOut extends CameraEvent {
  const CameraTorchTimedOut(this.armedAt);

  final DateTime armedAt;

  @override
  List<Object?> get props => <Object?>[armedAt];
}
