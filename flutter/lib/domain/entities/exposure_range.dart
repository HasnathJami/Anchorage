import 'package:equatable/equatable.dart';

/// The exposure compensation a sensor will accept, and the arithmetic the
/// brightness slider needs.
///
/// Exposure compensation is not a free-form double. Android reports a range in
/// *steps* — commonly ±2 EV in 1/3 EV increments — and a value off that grid is
/// either rejected or silently rounded, which makes the slider drift away from
/// the number the app thinks it set. Snapping is therefore a rule, not a
/// nicety, and it lives here where it can be tested without a camera.
class ExposureRange extends Equatable {
  const ExposureRange({
    required this.min,
    required this.max,
    required this.step,
  });

  /// A sensor that will not budge. Rendered as no slider at all rather than a
  /// dead one.
  static const ExposureRange fixed = ExposureRange(min: 0, max: 0, step: 0);

  factory ExposureRange.fromSensor({
    required double min,
    required double max,
    required double step,
  }) {
    if (!min.isFinite || !max.isFinite || max <= min) return fixed;

    // A zero or negative step means "continuous" on some devices and "broken"
    // on others. Treating it as continuous is the safe reading: the value is
    // still clamped, it simply is not snapped.
    return ExposureRange(
      min: min,
      max: max,
      step: step.isFinite && step > 0 ? step : 0,
    );
  }

  final double min;
  final double max;

  /// 0 means the sensor accepts any value in range.
  final double step;

  bool get canAdjust => max > min;

  /// Clamped and snapped to the sensor's grid.
  double normalise(double ev) {
    final double clamped = ev.clamp(min, max).toDouble();
    if (step <= 0) return clamped;

    // Snap relative to zero, not to [min]: 0 EV is the neutral exposure the
    // user expects the slider to be able to return to exactly, and a grid
    // anchored at an asymmetric minimum can miss it.
    final double snapped = (clamped / step).roundToDouble() * step;
    return snapped.clamp(min, max).toDouble();
  }

  /// Where [ev] sits along the track, 0.0 (darkest) to 1.0 (brightest).
  double fractionOf(double ev) {
    if (!canAdjust) return 0.5;
    return ((ev - min) / (max - min)).clamp(0.0, 1.0);
  }

  /// The exposure at [fraction] along the track, snapped to the grid.
  double evAt(double fraction) {
    if (!canAdjust) return 0;
    return normalise(min + fraction.clamp(0.0, 1.0) * (max - min));
  }

  @override
  List<Object?> get props => <Object?>[min, max, step];
}
