import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/zoom_range.dart';
import 'package:anchorage_harbor/domain/entities/zoom_span.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rules in [ZoomSpan]'s doc comment, one group each.
///
/// The device these were written against is a Galaxy A54: it publishes its
/// ultra-wide as a separate camera, and *every* one of its cameras reports a
/// sensor zoom range of 1.0 - 8.0. So the ultra-wide's own "1.0" is the user's
/// "0.5x", and a slider built from the open sensor's numbers can never offer
/// it. That is the whole reason this file exists.
void main() {
  const CameraLens ultraWide = CameraLens(
    id: 'uw',
    zoomFactor: 0.5,
    label: '0.5',
    kind: CameraLensKind.ultraWide,
  );
  const CameraLens main = CameraLens(
    id: 'main',
    zoomFactor: 1,
    label: '1',
    kind: CameraLensKind.wide,
  );
  const CameraLens tele = CameraLens(
    id: 'tele',
    zoomFactor: 2,
    label: '2',
    kind: CameraLensKind.telephoto,
  );

  /// Every camera reports 1.0 - 8.0 of its own zoom, as the A54's do.
  const ZoomRange sensor = ZoomRange(min: 1, max: 8);

  ZoomSpan spanOn(CameraLens active, {List<CameraLens>? lenses}) =>
      ZoomSpan.across(
        lenses: lenses ?? const <CameraLens>[ultraWide, main, tele],
        activeLens: active,
        activeRange: sensor,
      );

  group('the offered band', () {
    test('spans every rear camera, not just the open one', () {
      // The open camera stops at 1x, but the device as a whole starts at 0.5x.
      final ZoomRange offered = spanOn(main).offered;

      expect(offered.min, 0.5);
      expect(offered.max, 8);
    });

    test('is still capped by the product ceiling', () {
      // The telephoto alone would reach 2 x 8 = 16x.
      expect(spanOn(main).offered.max, ZoomRange.preferredMax);
    });

    test('a single-camera device offers exactly what that camera does', () {
      final ZoomRange offered = spanOn(main, lenses: <CameraLens>[main]).offered;

      expect(offered.min, 1);
      expect(offered.max, 8);
    });
  });

  group('effective zoom', () {
    test('is the sensor zoom scaled by what the lens sees', () {
      expect(spanOn(main).effectiveOf(2), 2);
      // The ultra-wide sitting at its own 1.0 is the user's 0.5x.
      expect(spanOn(ultraWide).effectiveOf(1), 0.5);
      expect(spanOn(ultraWide).effectiveOf(4), 2);
    });
  });

  group('placing a zoom the open lens cannot reach', () {
    test('0.5x from the main camera opens the ultra-wide at its own 1.0', () {
      final ZoomPlacement placement = spanOn(main).place(0.5);

      expect(placement.lens, ultraWide);
      expect(placement.sensorZoom, 1);
    });

    test('a value between the two is delivered by the wider lens', () {
      final ZoomPlacement placement = spanOn(main).place(0.75);

      expect(placement.lens, ultraWide);
      expect(placement.sensorZoom, 1.5);
    });

    test('a request below the widest lens is clamped, not refused', () {
      final ZoomPlacement placement = spanOn(main).place(0.1);

      expect(placement.lens, ultraWide);
      expect(placement.sensorZoom, 1);
    });
  });

  group('keeping the open lens', () {
    test('a value the open lens can reach does not open a camera', () {
      final ZoomPlacement placement = spanOn(main).place(3);

      expect(placement.lens, main,
          reason: 'reopening a camera to show 3x is half a second of black '
              'preview for no gain');
      expect(placement.sensorZoom, 3);
    });

    test('a longer lens is never taken automatically', () {
      // 2x is the telephoto's native factor and the open camera can only crop
      // to it - but a rear camera's role is inferred from list order, and on
      // this very device the third one is a macro. A switch nobody asked for,
      // to a lens that might be the wrong lens, is not worth a black preview.
      expect(spanOn(main).place(2).lens, main);
      expect(spanOn(main).place(5).lens, main);
    });

    test('a longer lens is opened when nothing wider can reach the value', () {
      // A main camera that stops at 2x, on a device whose telephoto does not.
      final ZoomSpan span = ZoomSpan.across(
        lenses: const <CameraLens>[main, tele],
        activeLens: main,
        activeRange: const ZoomRange(min: 1, max: 2),
      );

      expect(span.place(2).lens, main, reason: 'still within reach');
      expect(span.place(3).lens, tele, reason: 'nothing wider can show 3x');
    });

    test('a single-camera device never switches', () {
      final ZoomPlacement placement =
          spanOn(main, lenses: <CameraLens>[main]).place(0.5);

      expect(placement.lens, main);
      expect(placement.sensorZoom, 1, reason: 'clamped, not refused');
    });
  });

  group('the switch margin', () {
    test('a finger resting on 1.0x does not reopen the main camera', () {
      // Sitting exactly on the boundary is the oscillation this margin exists
      // to stop: the ultra-wide can still show 1.0x, so it keeps it.
      expect(spanOn(ultraWide).place(1).lens, ultraWide);
    });

    test('clearing the boundary hands over to the main camera', () {
      final ZoomPlacement placement = spanOn(ultraWide).place(1.2);

      expect(placement.lens, main);
      expect(placement.sensorZoom, 1.2);
    });

    test('1.5x belongs on the main camera, not as a crop of the ultra-wide',
        () {
      expect(spanOn(ultraWide).place(1.5).lens, main);
    });

    test('the ultra-wide keeps values it is the right lens for', () {
      expect(spanOn(ultraWide).place(0.8).lens, ultraWide);
    });
  });

  group('the front camera', () {
    const CameraLens front = CameraLens(
      id: 'front',
      zoomFactor: 1,
      label: 'Front',
      kind: CameraLensKind.front,
    );

    /// The rear ladder is what the span is built from, and the front camera is
    /// not on it - so it arrives as a lens the list does not contain.
    ZoomSpan frontSpan() => ZoomSpan.across(
          lenses: const <CameraLens>[ultraWide, main, tele],
          activeLens: front,
          activeRange: sensor,
        );

    test('offers only what the selfie camera itself can do', () {
      // Not 0.5x. Borrowing the rear ladder would put a wide button on a
      // camera that has never been able to reach it.
      expect(frontSpan().offered.min, 1);
      expect(frontSpan().offered.max, 8);
    });

    test('never resolves to a camera pointing the other way', () {
      // The bug this guards: a pinch wider than the selfie camera can manage
      // opened the rear ultra-wide. The user asked to see more of their own
      // face and the phone showed them the room behind it.
      expect(frontSpan().place(0.5).lens, front);
      expect(frontSpan().place(3).lens, front);
    });

    test('still zooms within itself', () {
      expect(frontSpan().place(4).sensorZoom, 4);
      expect(frontSpan().effectiveOf(2), 2);
    });
  });

  group('degrading safely', () {
    test('no lenses at all still answers with the open one', () {
      final ZoomSpan span = ZoomSpan.across(
        lenses: const <CameraLens>[],
        activeLens: main,
        activeRange: sensor,
      );

      final ZoomPlacement placement = span.place(4);
      expect(placement.lens, main);
      expect(placement.sensorZoom, 4);
    });

    test('a camera that cannot zoom offers a single point', () {
      final ZoomSpan span = ZoomSpan.across(
        lenses: const <CameraLens>[main],
        activeLens: main,
        activeRange: ZoomRange.fixed,
      );

      expect(span.offered.canZoom, isFalse);
      expect(span.place(5).sensorZoom, 1);
    });
  });
}
