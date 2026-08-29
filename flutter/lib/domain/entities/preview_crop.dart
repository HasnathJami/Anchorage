import 'package:equatable/equatable.dart';

/// Where a tap on the *visible* preview lands on the *sensor* image.
///
/// These are not the same point, and assuming they were is why tap-to-focus
/// missed. The preview is painted to **cover** the viewport, and on a tall
/// phone that crops the *sides*: a 3:4 portrait preview scaled until it fills
/// a 9:20 screen is half again too wide, so about 40% of the sensor's width
/// never reaches the glass. The middle of the screen is still the middle of
/// the sensor, but a tap at the left edge is a fifth of the way in, not at
/// the edge at all.
///
/// `setFocusPoint` and `setExposurePoint` take sensor coordinates. Handing
/// them viewport coordinates focuses somewhere the user did not touch, and the
/// error grows the further from centre they tap. On a tall phone that is most
/// of the frame.
///
/// Both directions are needed: the tap has to travel *in* to the sensor, and
/// the reticle has to be drawn back *out* at the place the finger actually
/// landed.
class PreviewCrop extends Equatable {
  const PreviewCrop({required this.sourceAspect, required this.viewportAspect});

  /// A crop that changes nothing — for a preview whose shape already matches
  /// the space it is painted into, and as the safe answer when either aspect
  /// is unknown.
  static const PreviewCrop none =
      PreviewCrop(sourceAspect: 1, viewportAspect: 1);

  /// Width / height of the camera preview, as it is laid out.
  final double sourceAspect;

  /// Width / height of the area it is painted into.
  final double viewportAspect;

  /// Builds a crop, falling back to [none] on any nonsense input.
  ///
  /// A zero-sized layout pass and a controller with no preview size yet both
  /// happen in the ordinary course of a camera opening. Neither is worth an
  /// exception, and an identity mapping is a far better wrong answer than a
  /// division by zero.
  factory PreviewCrop.of({
    required double sourceAspect,
    required double viewportAspect,
  }) {
    final bool usable = sourceAspect.isFinite &&
        viewportAspect.isFinite &&
        sourceAspect > 0 &&
        viewportAspect > 0;

    return usable
        ? PreviewCrop(
            sourceAspect: sourceAspect,
            viewportAspect: viewportAspect,
          )
        : none;
  }

  /// The fraction of the source's width that survives the crop.
  ///
  /// A source wider than the viewport is cropped at the sides; a source
  /// narrower than it is not cropped horizontally at all.
  double get visibleWidth =>
      sourceAspect > viewportAspect ? viewportAspect / sourceAspect : 1;

  /// The fraction of the source's height that survives the crop.
  double get visibleHeight =>
      sourceAspect < viewportAspect ? sourceAspect / viewportAspect : 1;

  /// A point on the viewport, both axes normalised, as a point on the sensor.
  ({double x, double y}) toSensor({required double x, required double y}) => (
        x: _in(x, visibleWidth),
        y: _in(y, visibleHeight),
      );

  /// The inverse: a point on the sensor, back to where it sits on screen.
  ///
  /// A sensor point outside the visible crop maps outside 0..1, which is
  /// correct — the caller decides whether to clamp it or leave it off screen.
  ({double x, double y}) toViewport({required double x, required double y}) => (
        x: _out(x, visibleWidth),
        y: _out(y, visibleHeight),
      );

  /// The crop is centred, so half of what is lost sits before the visible
  /// window and half after.
  static double _in(double value, double visible) =>
      ((1 - visible) / 2) + (value * visible);

  static double _out(double value, double visible) =>
      visible == 0 ? value : (value - ((1 - visible) / 2)) / visible;

  @override
  List<Object?> get props => <Object?>[sourceAspect, viewportAspect];
}
