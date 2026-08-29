import 'package:equatable/equatable.dart';

/// The zoom band the camera screen *offers*, which is not the same thing as
/// the band the sensor will *admit*.
///
/// Two separate decisions meet here, and keeping them apart is the point:
///
///  * **The product wants 0.5x – 8x.** That is the range the controls are
///    designed around: three quick-zoom stops and a slider whose travel is
///    worth dragging.
///  * **The hardware has the last word.** You cannot see wider than the lens,
///    so a sensor that starts at 1x is offered from 1x — offering 0.5x on it
///    would put a button on screen that the platform rejects.
///
/// So this is an *intersection*, computed once when a camera opens, and every
/// control downstream reads it rather than the raw sensor numbers.
class ZoomRange extends Equatable {
  const ZoomRange({required this.min, required this.max});

  /// A camera that cannot zoom at all.
  static const ZoomRange fixed = ZoomRange(min: 1, max: 1);

  /// The widest the app offers. A sensor that reports something wider is
  /// pinned here: below about 0.5x the barrel distortion is severe enough that
  /// the frame stops being a usable record of a site, which is what these
  /// photographs are for.
  static const double preferredMin = 0.5;

  /// The longest the app offers, and the answer to "why not the 30x the
  /// platform reports?".
  ///
  /// Past roughly 8x a phone is upscaling, not zooming — the extra numbers buy
  /// mush. They also cost something real: the reference design's slider is a
  /// ~230 dp column, and mapping 1x–30x onto it makes the 1x–3x band people
  /// actually use about twenty pixels tall.
  static const double preferredMax = 8;

  /// Builds the offered range from what the open sensor reports.
  factory ZoomRange.fromSensor({
    required double sensorMin,
    required double sensorMax,
  }) {
    // Defend against the values a misbehaving driver can return. A zero or
    // negative minimum is not "very wide", it is a broken answer.
    final double low = sensorMin.isFinite && sensorMin > 0 ? sensorMin : 1;
    final double high = sensorMax.isFinite && sensorMax >= low ? sensorMax : low;

    final double min = low < preferredMin ? preferredMin : low;
    final double max = high > preferredMax ? preferredMax : high;

    // `max < min` only happens for nonsense input (a sensor claiming to start
    // at 10x). Collapsing to a fixed range is the safe reading: no slider, no
    // stops beyond 1x, nothing that can be tapped into an exception.
    return ZoomRange(min: min, max: max < min ? min : max);
  }

  final double min;
  final double max;

  bool get canZoom => max > min;

  /// Clamped, never thrown. The platform raises on an out-of-range zoom and a
  /// pinch gesture will absolutely produce one.
  double clampZoom(double zoom) => zoom.clamp(min, max).toDouble();

  /// Where the app opens: 1x when it is inside the range.
  ///
  /// Not the minimum. On a phone whose rear camera spans an ultra-wide the
  /// minimum is 0.5, and opening there means the preview starts on a distorted
  /// wide-angle frame the user did not ask for. 1x is the framing everyone
  /// expects a camera to open on.
  double get openingZoom => clampZoom(1);

  @override
  List<Object?> get props => <Object?>[min, max];
}
