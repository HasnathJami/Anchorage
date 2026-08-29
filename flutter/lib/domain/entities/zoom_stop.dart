import 'package:equatable/equatable.dart';

/// One of the round quick-zoom buttons under the preview - `0.5`, `1`, `2`.
///
/// A stop is a *zoom ratio*, not a camera. That distinction is the whole point
/// of this file, and it is the fix for a bug the reference design made
/// obvious: the buttons used to be built from the list of physical back
/// cameras `availableCameras()` reports, and on Android that list is almost
/// always exactly one back camera even on a phone with three lenses, because
/// the platform publishes a single *logical* camera whose zoom range spans
/// them. The result was a row of buttons that rendered on nobody's device.
///
/// Driving them from the sensor's real zoom range instead means the row is
/// always correct: it offers 0.5x only on hardware that can genuinely go that
/// wide, and it reaches 2x whether that is an optical telephoto or a crop of
/// the main sensor - which is exactly what the user means when they tap "2".
class ZoomStop extends Equatable {
  const ZoomStop({required this.ratio, required this.label});

  /// The zoom level to hand to the sensor: 0.5, 1.0, 2.0.
  final double ratio;

  /// What the button reads when it is *not* selected: "0.5", "1", "2".
  final String label;

  @override
  List<Object?> get props => <Object?>[ratio, label];
}

/// Chooses which quick-zoom buttons a given sensor deserves.
///
/// Pure, so the rules below are asserted on the JVM in microseconds rather
/// than discovered on a reviewer's phone.
abstract final class ZoomLadder {
  /// The ratios worth offering, in the order a camera app conventionally
  /// shows them. Anything past 10x on a phone is upscaling, not zoom.
  static const List<double> candidates = <double>[0.5, 1, 2, 3, 5, 10];

  /// The reference design shows three buttons; more than four is a row of
  /// targets too small to hit with a thumb while holding the phone one-handed.
  static const int defaultMaxStops = 3;

  /// Below this, a sensor is a genuine ultra-wide and earns a wide button.
  ///
  /// Not an exact `< 1`: devices report 0.5, 0.6 and 0.9999998 for what is
  /// really the same "this is as wide as I go" answer, and a threshold that
  /// treated 0.9999998 as an ultra-wide would put a meaningless second button
  /// next to the 1x on ordinary hardware.
  static const double ultraWideBelow = 0.95;

  /// How close the live zoom must be to a stop before the button claims to be
  /// *at* that stop rather than showing the live value.
  static const double snapTolerance = 0.05;

  /// Builds the ladder for a sensor that zooms between [minZoom] and
  /// [maxZoom].
  ///
  /// 1x is always included, even on a fixed-focus sensor that cannot zoom at
  /// all: it is the frame the user is looking at, and a camera whose current
  /// framing has no button is disorienting. Everything else has to be earned
  /// by the hardware actually reaching it.
  static List<ZoomStop> forRange({
    required double minZoom,
    required double maxZoom,
    int maxStops = defaultMaxStops,
  }) {
    final double low = minZoom.isFinite && minZoom > 0 ? minZoom : 1;
    final double high = maxZoom.isFinite && maxZoom >= low ? maxZoom : low;

    // The wide button is aimed at the sensor's *actual* minimum rather than at
    // a round 0.5, so tapping it lands exactly where the hardware stops
    // instead of being silently clamped. Its label follows the ratio, so a
    // 0.6x ultra-wide honestly reads "0.6".
    final ZoomStop? wide = low < ultraWideBelow
        ? ZoomStop(ratio: low, label: _label(low))
        : null;

    final List<ZoomStop> stops = <ZoomStop>[
      ?wide,
      const ZoomStop(ratio: 1, label: '1'),
      // `>= low` as well as `<= high`, so a garbled range from a
      // misbehaving driver degrades to the bare 1x rather than to a row of
      // buttons the sensor would refuse.
      for (final double ratio in candidates)
        if (ratio > 1 && ratio >= low && ratio <= high)
          ZoomStop(ratio: ratio, label: _label(ratio)),
    ];

    return stops.take(maxStops).toList(growable: false);
  }

  /// Which stop the button row should light up for a live [zoom].
  ///
  /// The greatest stop at or below the current zoom, so pinching from 1x
  /// towards 2x keeps "1" lit until 2x is actually reached - the same
  /// behaviour as the platform camera apps, and the reason the selected pill
  /// can honestly show a live "1.7x" read-out.
  static ZoomStop? activeStop(List<ZoomStop> stops, double zoom) {
    if (stops.isEmpty) return null;

    ZoomStop active = stops.first;
    for (final ZoomStop stop in stops) {
      if (zoom + snapTolerance >= stop.ratio) active = stop;
    }
    return active;
  }

  /// True when [zoom] is close enough to [stop] that the button should read
  /// its own label rather than the live value.
  static bool isAt(ZoomStop stop, double zoom) =>
      (zoom - stop.ratio).abs() <= snapTolerance;

  /// "0.5", "1", "2" - one decimal at most, because the button is 34 dp wide.
  static String _label(double ratio) => ratio == ratio.roundToDouble()
      ? ratio.toStringAsFixed(0)
      : ratio.toStringAsFixed(1);
}
