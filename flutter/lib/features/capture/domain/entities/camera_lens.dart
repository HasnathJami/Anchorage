import 'package:equatable/equatable.dart';

/// One physical back camera, described in the terms the UI needs.
///
/// The reference design shows "0.5 / 1 / 2" pills. Those numbers are *not*
/// invented: each maps to a real sensor whose focal length differs, and the
/// [zoomFactor] is the multiplier relative to the device's main lens. Devices
/// with a single back camera get one pill, not three fake ones.
class CameraLens extends Equatable {
  const CameraLens({
    required this.id,
    required this.zoomFactor,
    required this.label,
    required this.kind,
  });

  final String id;

  /// Multiplier relative to the main (1x) lens: 0.5 for ultra-wide, 2 or 3
  /// for a telephoto.
  final double zoomFactor;

  /// What the pill reads: "0.5", "1", "2".
  final String label;

  final CameraLensKind kind;

  @override
  List<Object?> get props => <Object?>[id, zoomFactor, label, kind];
}

enum CameraLensKind { ultraWide, wide, telephoto, front, unknown }

/// The camera's live, user-controllable configuration.
class CameraSettings extends Equatable {
  const CameraSettings({
    required this.zoom,
    required this.minZoom,
    required this.maxZoom,
    this.flashMode = CaptureFlashMode.off,
    this.isFrontFacing = false,
  });

  static const CameraSettings initial =
      CameraSettings(zoom: 1, minZoom: 1, maxZoom: 1);

  final double zoom;
  final double minZoom;
  final double maxZoom;
  final CaptureFlashMode flashMode;
  final bool isFrontFacing;

  /// Where the zoom slider knob sits, 0.0 - 1.0.
  ///
  /// Guarded against `maxZoom == minZoom`, which is the case on emulators and
  /// would otherwise divide by zero and render the knob at NaN.
  double get zoomFraction => maxZoom <= minZoom
      ? 0
      : ((zoom - minZoom) / (maxZoom - minZoom)).clamp(0.0, 1.0);

  CameraSettings copyWith({
    double? zoom,
    double? minZoom,
    double? maxZoom,
    CaptureFlashMode? flashMode,
    bool? isFrontFacing,
  }) {
    return CameraSettings(
      zoom: zoom ?? this.zoom,
      minZoom: minZoom ?? this.minZoom,
      maxZoom: maxZoom ?? this.maxZoom,
      flashMode: flashMode ?? this.flashMode,
      isFrontFacing: isFrontFacing ?? this.isFrontFacing,
    );
  }

  @override
  List<Object?> get props =>
      <Object?>[zoom, minZoom, maxZoom, flashMode, isFrontFacing];
}

enum CaptureFlashMode { off, auto, always, torch }

/// A tap-to-focus request in *normalised* preview coordinates (0-1 on both
/// axes), so the domain never has to know the preview's pixel size or
/// rotation.
class FocusPoint extends Equatable {
  const FocusPoint({required this.x, required this.y, required this.requestedAt});

  final double x;
  final double y;
  final DateTime requestedAt;

  @override
  List<Object?> get props => <Object?>[x, y, requestedAt];
}
