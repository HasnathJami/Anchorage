import 'package:anchorage_harbor/domain/entities/zoom_stop.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rules in [ZoomLadder]'s doc comment, one test each.
void main() {
  List<double> ratios(double min, double max) =>
      ZoomLadder.forRange(minZoom: min, maxZoom: max)
          .map((ZoomStop stop) => stop.ratio)
          .toList();

  group('building the ladder', () {
    test('a sensor that cannot zoom at all still offers 1x', () {
      // The frame the user is looking at always has a button. Anything else
      // reads as a camera that has lost its bearings.
      expect(ratios(1, 1), <double>[1]);
    });

    test('an ultra-wide sensor earns the 0.5 button', () {
      expect(ratios(0.5, 8), <double>[0.5, 1, 2]);
    });

    test('a sensor that stops at 1x is never offered a wide button', () {
      expect(ratios(1, 8), <double>[1, 2, 3]);
    });

    test('a ratio the hardware cannot reach is not offered', () {
      // The regression this prevents: a "2" button on a sensor whose maximum
      // is 1.5, which silently clamps and looks broken.
      expect(ratios(1, 1.5), <double>[1]);
    });

    test('the row never grows past the reference design width', () {
      expect(
        ZoomLadder.forRange(minZoom: 0.5, maxZoom: 30).length,
        ZoomLadder.defaultMaxStops,
      );
    });

    test('an odd ultra-wide minimum still gets a button, aimed where it works',
        () {
      // Devices report 0.5, 0.6 and 0.5999999 for what is physically the same
      // lens. The button targets the reported minimum rather than a round 0.5,
      // so the tap lands exactly where the sensor stops instead of clamping.
      final List<ZoomStop> stops =
          ZoomLadder.forRange(minZoom: 0.5999, maxZoom: 8);

      expect(stops.first.ratio, 0.5999);
      expect(stops.first.label, '0.6');
    });

    test('a nonsensical range degrades to the single 1x stop', () {
      expect(ratios(8, 1), <double>[1]);
      expect(ratios(double.nan, double.infinity), <double>[1]);
      expect(ratios(0, 0), <double>[1]);
    });
  });

  group('which stop is lit', () {
    final List<ZoomStop> stops =
        ZoomLadder.forRange(minZoom: 0.5, maxZoom: 8);

    test('an exact match lights its own stop', () {
      expect(ZoomLadder.activeStop(stops, 2)?.ratio, 2);
    });

    test('a zoom between stops keeps the lower one lit', () {
      // Pinching from 1x towards 2x must not light "2" until 2x is reached -
      // otherwise the row claims a framing the preview is not showing.
      expect(ZoomLadder.activeStop(stops, 1.7)?.ratio, 1);
    });

    test('a zoom below the widest stop still lights it', () {
      expect(ZoomLadder.activeStop(stops, 0.4)?.ratio, 0.5);
    });

    test('a stop only claims to be "at" a zoom within its snap tolerance', () {
      const ZoomStop one = ZoomStop(ratio: 1, label: '1');
      expect(ZoomLadder.isAt(one, 1.02), isTrue);
      expect(ZoomLadder.isAt(one, 1.7), isFalse);
    });

    test('an empty ladder lights nothing rather than throwing', () {
      expect(ZoomLadder.activeStop(const <ZoomStop>[], 1), isNull);
    });
  });
}
