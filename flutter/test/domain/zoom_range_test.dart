import 'package:anchorage_harbor/domain/entities/zoom_range.dart';
import 'package:flutter_test/flutter_test.dart';

/// The camera offers 0.5x - 8x, intersected with what the sensor admits.
/// Both halves of that sentence get tests.
void main() {
  ZoomRange range(double min, double max) =>
      ZoomRange.fromSensor(sensorMin: min, sensorMax: max);

  group('the product ceiling', () {
    test('a sensor that reports 30x is offered up to 8x', () {
      // Past roughly 8x a phone upscales rather than zooms, and mapping 1-30x
      // onto a 230 dp slider makes the band people use untouchable.
      expect(range(1, 30).max, ZoomRange.preferredMax);
    });

    test('a sensor that stops below the ceiling keeps its own maximum', () {
      expect(range(1, 4).max, 4);
    });

    test('exactly 8x is offered whole', () {
      expect(range(0.5, 8), const ZoomRange(min: 0.5, max: 8));
    });
  });

  group('the optical floor', () {
    test('an ultra-wide sensor is offered from 0.5x', () {
      expect(range(0.5, 10).min, 0.5);
    });

    test('a sensor that starts at 1x is offered from 1x, not 0.5x', () {
      // You cannot see wider than the lens. Offering 0.5x here would put a
      // control on screen that the platform rejects.
      expect(range(1, 8).min, 1);
    });

    test('a sensor wider than the app offers is pinned to 0.5x', () {
      expect(range(0.25, 8).min, ZoomRange.preferredMin);
    });

    test('an odd ultra-wide minimum is kept exactly', () {
      // Devices report 0.5, 0.6 and 0.5999999 for the same physical lens; the
      // offered minimum has to be the one the hardware will actually accept.
      expect(range(0.6, 8).min, 0.6);
    });
  });

  group('degrading safely', () {
    test('a fixed-focus sensor can be described, and cannot zoom', () {
      expect(range(1, 1), ZoomRange.fixed);
      expect(range(1, 1).canZoom, isFalse);
    });

    test('an inverted range collapses rather than inventing a band', () {
      expect(range(10, 1).canZoom, isFalse);
    });

    test('non-finite and non-positive values fall back to 1x', () {
      expect(range(double.nan, double.infinity), ZoomRange.fixed);
      expect(range(0, 0), ZoomRange.fixed);
      expect(range(-1, 5).min, 1);
    });
  });

  group('using the range', () {
    test('a zoom outside the band is clamped, never thrown', () {
      // The platform raises on an out-of-range zoom and a pinch will produce
      // one on every gesture that reaches an end stop.
      final ZoomRange band = range(0.5, 8);

      expect(band.clampZoom(0.1), 0.5);
      expect(band.clampZoom(99), 8);
      expect(band.clampZoom(2.5), 2.5);
    });

    test('the camera opens at 1x when 1x is in the band', () {
      expect(range(0.5, 8).openingZoom, 1);
    });

    test('a camera that cannot reach 1x opens as close as it can', () {
      expect(range(2, 8).openingZoom, 2);
    });
  });
}
