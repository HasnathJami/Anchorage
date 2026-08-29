import 'package:anchorage_harbor/domain/entities/exposure_range.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exposure compensation is reported in *steps*. A value off the sensor's grid
/// is rejected or silently rounded, and either way the slider ends up showing
/// a number the hardware is not using — so snapping is a rule with a test, not
/// a nicety.
void main() {
  const ExposureRange thirds = ExposureRange(min: -2, max: 2, step: 1 / 3);
  const ExposureRange halves = ExposureRange(min: -3, max: 3, step: 0.5);

  group('reading the sensor', () {
    test('a usable range is kept as reported', () {
      expect(
        ExposureRange.fromSensor(min: -2, max: 2, step: 0.5),
        const ExposureRange(min: -2, max: 2, step: 0.5),
      );
    });

    test('a sensor with no compensation at all is fixed', () {
      expect(ExposureRange.fromSensor(min: 0, max: 0, step: 0),
          ExposureRange.fixed);
      expect(ExposureRange.fixed.canAdjust, isFalse);
    });

    test('a non-finite or inverted range degrades rather than throwing', () {
      expect(ExposureRange.fromSensor(min: 2, max: -2, step: 0.5),
          ExposureRange.fixed);
      expect(
        ExposureRange.fromSensor(
            min: double.nan, max: double.infinity, step: 0.5),
        ExposureRange.fixed,
      );
    });

    test('a zero step means continuous, not broken', () {
      // Some devices report 0 for a continuously variable sensor. Clamping
      // still applies; snapping simply does not.
      final ExposureRange range =
          ExposureRange.fromSensor(min: -1, max: 1, step: 0);

      expect(range.canAdjust, isTrue);
      expect(range.normalise(0.137), 0.137);
      expect(range.normalise(9), 1);
    });
  });

  group('snapping to the grid', () {
    test('lands on the nearest step', () {
      expect(halves.normalise(0.7), 0.5);
      expect(halves.normalise(0.8), 1.0);
    });

    test('zero is always exactly reachable', () {
      // The neutral exposure is the one value the user must be able to get
      // back to precisely, so the grid is anchored at 0 rather than at `min`.
      expect(thirds.normalise(0.1), 0);
      expect(halves.normalise(-0.2), 0);
    });

    test('clamps to the ends before snapping', () {
      expect(halves.normalise(99), 3);
      expect(halves.normalise(-99), -3);
    });

    test('a snapped value never escapes the range', () {
      const ExposureRange awkward = ExposureRange(min: -1.9, max: 1.9, step: 1);
      expect(awkward.normalise(1.9), lessThanOrEqualTo(1.9));
      expect(awkward.normalise(-1.9), greaterThanOrEqualTo(-1.9));
    });
  });

  group('slider arithmetic', () {
    test('the ends of the track map to the ends of the range', () {
      expect(halves.evAt(0), -3);
      expect(halves.evAt(1), 3);
    });

    test('the middle of the track is neutral exposure', () {
      expect(halves.evAt(0.5), 0);
    });

    test('a position round-trips back to itself', () {
      expect(halves.fractionOf(halves.evAt(0.75)), closeTo(0.75, 0.01));
    });

    test('an out-of-range value still reports a position on the track', () {
      expect(halves.fractionOf(99), 1);
      expect(halves.fractionOf(-99), 0);
    });

    test('a fixed sensor parks the knob in the middle and stays at 0', () {
      // Rendered as no slider at all, but the arithmetic must not divide by a
      // zero-width range on the way to deciding that.
      expect(ExposureRange.fixed.fractionOf(0), 0.5);
      expect(ExposureRange.fixed.evAt(1), 0);
    });
  });
}
