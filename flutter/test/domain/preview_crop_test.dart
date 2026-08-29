import 'package:anchorage_harbor/domain/entities/preview_crop.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rules in [PreviewCrop]'s doc comment, one group each.
///
/// The numbers below are the real ones: a 4:3 sensor on a 20:9 phone. Held in
/// portrait that is a source of 0.75 painted into a viewport of 0.45, and 40%
/// of the sensor's *width* never reaches the screen — covering a tall narrow
/// viewport with a squarer image crops the sides, not the top.
void main() {
  /// A 4:3 sensor, portrait: 3 wide by 4 tall.
  const double sensor = 3 / 4;

  /// A 20:9 phone, portrait.
  const double phone = 9 / 20;

  const PreviewCrop tall = PreviewCrop(
    sourceAspect: sensor,
    viewportAspect: phone,
  );

  group('what survives the crop', () {
    test('a source squarer than the viewport is cropped at the sides', () {
      expect(tall.visibleWidth, closeTo(0.6, 0.001));
      expect(tall.visibleHeight, 1, reason: 'nothing is lost top or bottom');
    });

    test('a source taller than the viewport is cropped top and bottom', () {
      const PreviewCrop wide = PreviewCrop(sourceAspect: 0.45, viewportAspect: 0.75);

      expect(wide.visibleHeight, closeTo(0.6, 0.001));
      expect(wide.visibleWidth, 1);
    });

    test('a matching shape loses nothing', () {
      const PreviewCrop exact = PreviewCrop(sourceAspect: 0.75, viewportAspect: 0.75);

      expect(exact.visibleWidth, 1);
      expect(exact.visibleHeight, 1);
    });
  });

  group('a tap travelling in to the sensor', () {
    test('the middle of the screen is the middle of the sensor', () {
      final ({double x, double y}) point = tall.toSensor(x: 0.5, y: 0.5);

      expect(point.x, closeTo(0.5, 0.001));
      expect(point.y, closeTo(0.5, 0.001));
    });

    test('the left edge of the screen is a fifth of the way into the sensor',
        () {
      // This is the whole bug: passing 0.0 straight through told the camera to
      // focus on the very edge of a frame the user could not even see.
      expect(tall.toSensor(x: 0, y: 0.5).x, closeTo(0.2, 0.001));
    });

    test('the right edge stops well short of the sensor edge', () {
      expect(tall.toSensor(x: 1, y: 0.5).x, closeTo(0.8, 0.001));
    });

    test('the uncropped axis is passed straight through', () {
      expect(tall.toSensor(x: 0.5, y: 0.25).y, closeTo(0.25, 0.001));
    });
  });

  group('a sensor point coming back out to the screen', () {
    test('round-trips whatever went in', () {
      // The reticle has to land under the finger, so the two directions have
      // to agree exactly.
      for (final double x in <double>[0, 0.25, 0.5, 0.75, 1]) {
        final ({double x, double y}) sensorPoint = tall.toSensor(x: x, y: 0.3);
        final ({double x, double y}) back =
            tall.toViewport(x: sensorPoint.x, y: sensorPoint.y);

        expect(back.x, closeTo(x, 0.0001));
        expect(back.y, closeTo(0.3, 0.0001));
      }
    });

    test('a point outside the crop maps off screen rather than being clamped',
        () {
      // Honest: the caller decides what to do about it. Silently clamping
      // would draw a reticle somewhere the user never tapped.
      expect(tall.toViewport(x: 0.05, y: 0.5).x, lessThan(0));
    });
  });

  group('degrading safely', () {
    test('a zero-sized layout pass changes nothing', () {
      // Happens in the ordinary course of a camera opening. An identity
      // mapping is a far better wrong answer than a division by zero.
      final PreviewCrop crop =
          PreviewCrop.of(sourceAspect: 0, viewportAspect: 0.45);

      expect(crop, PreviewCrop.none);
      expect(crop.toSensor(x: 0.3, y: 0.7), (x: 0.3, y: 0.7));
    });

    test('a controller with no preview size yet changes nothing', () {
      final PreviewCrop crop =
          PreviewCrop.of(sourceAspect: double.nan, viewportAspect: 0.45);

      expect(crop, PreviewCrop.none);
    });

    test('the identity crop round-trips', () {
      expect(PreviewCrop.none.toViewport(x: 0.1, y: 0.9), (x: 0.1, y: 0.9));
    });
  });
}
