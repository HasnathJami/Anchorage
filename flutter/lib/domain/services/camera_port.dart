import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/capture_batch.dart';

/// The domain's view of the camera hardware.
///
/// Everything the `camera` plugin exposes is hidden behind this port, for one
/// concrete reason: `CameraController` cannot be constructed on the Dart VM,
/// so a Bloc that touched it directly could only be tested on a physical
/// device. With this seam, every capture rule - zoom clamping, lens switching,
/// batching, error recovery - is covered by fast `flutter test` runs.
abstract interface class CameraPort {
  /// Opens the default back camera and starts the preview.
  Future<Result<CameraSession>> initialise();

  /// Switches to [lens] (or the front camera) and restarts the preview.
  Future<Result<CameraSession>> selectLens(CameraLens lens);

  /// Clamped to the session's supported range by the implementation.
  Future<Result<void>> setZoom(double zoom);

  Future<Result<void>> setFlashMode(CaptureFlashMode mode);

  /// Focus and exposure at a normalised preview point.
  Future<Result<void>> focusAt(FocusPoint point);

  /// Takes a picture and persists it to app-private storage.
  Future<Result<CapturedShot>> capture({required double zoomLevel});

  /// Deletes a shot the user dropped before the batch was handed over.
  ///
  /// Removing it from the in-memory batch is not enough: the file is on disk
  /// the instant the shutter fires - that ordering is the app's whole
  /// durability story - so a discard that only forgot the entry would leave
  /// every rejected frame on the device for good.
  ///
  /// Returns nothing, deliberately. A file that is already gone is the outcome
  /// the caller wanted, and there is no remedy to offer for a delete that
  /// fails, so there is nothing worth interrupting the user with.
  Future<void> discard(CapturedShot shot);

  /// Releases the sensor - called when the app is backgrounded so another app
  /// (or a phone call) can take it.
  Future<void> dispose();
}

/// An open camera session: the live preview plus what it can do.
class CameraSession {
  const CameraSession({
    required this.previewAspectRatio,
    required this.settings,
    required this.availableLenses,
    required this.activeLens,
    required this.previewKey,
  });

  final double previewAspectRatio;
  final CameraSettings settings;
  final List<CameraLens> availableLenses;
  final CameraLens activeLens;

  /// Changes whenever the underlying controller is replaced, so the widget
  /// layer knows to rebuild the platform preview rather than reuse a dead one.
  final int previewKey;

  CameraSession copyWith({
    double? previewAspectRatio,
    CameraSettings? settings,
    List<CameraLens>? availableLenses,
    CameraLens? activeLens,
    int? previewKey,
  }) {
    return CameraSession(
      previewAspectRatio: previewAspectRatio ?? this.previewAspectRatio,
      settings: settings ?? this.settings,
      availableLenses: availableLenses ?? this.availableLenses,
      activeLens: activeLens ?? this.activeLens,
      previewKey: previewKey ?? this.previewKey,
    );
  }
}
