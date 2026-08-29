import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/zoom_range.dart';
import 'package:equatable/equatable.dart';

/// Which camera to have open, and what to set *its* zoom to, in order to
/// deliver the zoom the user asked for.
typedef ZoomPlacement = ({CameraLens lens, double sensorZoom});

/// One rear camera's contribution to the band, expressed in the numbers the
/// user reads rather than the ones the sensor takes.
///
/// A lens whose [CameraLens.zoomFactor] is 0.5 and which accepts 1x - 8x of
/// its own zoom covers **0.5x - 4x** of what the user sees.
class LensBand extends Equatable {
  const LensBand({required this.lens, required this.range});

  final CameraLens lens;

  /// The lens's own zoom band, in the numbers `setZoomLevel` takes.
  final ZoomRange range;

  double get min => lens.zoomFactor * range.min;
  double get max => lens.zoomFactor * range.max;

  bool contains(double effective) => effective >= min && effective <= max;

  /// What to set this lens's own zoom to in order to show [effective].
  double sensorZoomFor(double effective) =>
      range.clampZoom(effective / lens.zoomFactor);

  @override
  List<Object?> get props => <Object?>[lens, range];
}

/// The single zoom scale the user drags along, across every rear camera.
///
/// This exists because "zoom" means two different numbers and conflating them
/// is what put a **1x - 8x** slider on a phone whose camera app offers 0.5x:
///
///  * **Sensor zoom** is what `setZoomLevel` takes. Every camera on a Galaxy
///    A54 reports 1.0 - 8.0 for it, the ultra-wide included — on that sensor
///    1.0 already *is* the wide view.
///  * **Effective zoom** is what the user means by "0.5x": the field of view
///    relative to the main camera. It is the lens's own factor multiplied by
///    its sensor zoom.
///
/// Everything the user touches — the slider, its end labels, the quick-zoom
/// pills — is in effective zoom. [place] is the one place that converts back,
/// and it is the only thing that decides a lens switch is needed.
///
/// **What is assumed.** A camera's zoom band is only knowable once it is open,
/// and opening one to ask is a visible half-second of black preview. So a lens
/// that has not been opened is assumed to take the same *sensor-side* band as
/// the one that is. That is true on every device checked and it is
/// self-correcting: the moment a lens is opened, its real range replaces the
/// assumption.
class ZoomSpan extends Equatable {
  const ZoomSpan({required this.bands, required this.active});

  /// How far past a lens's native factor the zoom must travel before the app
  /// will open that lens.
  ///
  /// Without it a finger resting exactly on 1.0x sits on the boundary between
  /// the ultra-wide and the main camera and reopens one of them on every
  /// frame. Same reasoning as the geofence dial's hysteresis: the threshold is
  /// real, but a value sitting *on* it must not oscillate.
  static const double switchMargin = 0.04;

  /// Every rear camera, widest first.
  final List<LensBand> bands;

  /// The one currently open.
  final LensBand active;

  /// Builds the span from the cameras this device lists and the band the open
  /// one reports.
  factory ZoomSpan.across({
    required List<CameraLens> lenses,
    required CameraLens activeLens,
    required ZoomRange activeRange,
  }) {
    // The open camera is always one of the bands. [lenses] is the *rear*
    // ladder, and the front camera is not on it - so when the front camera is
    // open it is a span of one, and cannot borrow a range that belongs to
    // sensors pointing the other way.
    //
    // Without this, a pinch on a selfie resolved to the rear ultra-wide and
    // opened it: the user asked to see more of their own face and the phone
    // showed them the room behind it.
    final bool activeIsListed =
        lenses.any((CameraLens lens) => lens.id == activeLens.id);

    final List<CameraLens> usable =
        activeIsListed ? lenses : <CameraLens>[activeLens];

    final List<LensBand> bands = <LensBand>[
      for (final CameraLens lens in usable)
        // The open lens's range is the one the platform actually reported;
        // every other lens borrows it. See "What is assumed" above.
        LensBand(lens: lens, range: activeRange),
    ]..sort((LensBand a, LensBand b) => a.min.compareTo(b.min));

    final LensBand active = bands.firstWhere(
      (LensBand band) => band.lens.id == activeLens.id,
      orElse: () => LensBand(lens: activeLens, range: activeRange),
    );

    return ZoomSpan(bands: bands, active: active);
  }

  /// A camera with nothing to zoom and nowhere to go.
  static const ZoomSpan none = ZoomSpan(
    bands: <LensBand>[],
    active: LensBand(
      lens: CameraLens(
        id: '',
        zoomFactor: 1,
        label: '1',
        kind: CameraLensKind.wide,
      ),
      range: ZoomRange.fixed,
    ),
  );

  /// The whole offered band, run through [ZoomRange] so the 0.5x - 8x product
  /// decision is still made in exactly one place.
  ZoomRange get offered {
    if (bands.isEmpty) return active.range;

    double widest = bands.first.min;
    double longest = bands.first.max;
    for (final LensBand band in bands) {
      if (band.min < widest) widest = band.min;
      if (band.max > longest) longest = band.max;
    }

    return ZoomRange.fromSensor(sensorMin: widest, sensorMax: longest);
  }

  /// What the user is currently looking at, given the open lens's own zoom.
  double effectiveOf(double sensorZoom) => active.lens.zoomFactor * sensorZoom;

  /// Resolves a zoom the user asked for onto a camera and a sensor zoom.
  ///
  /// Two rules, in order:
  ///  1. A lens that cannot reach the value at all is left. There is no choice
  ///     to make — staying would clamp the request and light a control that
  ///     did nothing, which is the bug this whole file exists to fix.
  ///  2. Otherwise the open lens is kept unless a better one has been cleared
  ///     by [switchMargin]. "Better" means the longest lens at or below the
  ///     target that is still no longer than the main camera: 1.5x belongs on
  ///     the main camera rather than as a 3x crop of the ultra-wide, but 3x
  ///     does *not* jump to a telephoto - see [_idealFor].
  ZoomPlacement place(double effective) {
    final double target = offered.clampZoom(effective);
    final LensBand ideal = _idealFor(target);

    final bool mustLeave = !active.contains(target);
    final bool worthLeaving = ideal.lens.id != active.lens.id &&
        (target - ideal.lens.zoomFactor).abs() >
            ideal.lens.zoomFactor * switchMargin;

    final LensBand chosen = mustLeave || worthLeaving ? ideal : active;

    return (lens: chosen.lens, sensorZoom: chosen.sensorZoomFor(target));
  }

  /// The lens to show [target] on, when a choice has to be made.
  ///
  /// Candidates are capped at the **main** camera's factor, so the app will
  /// automatically switch *wider* but never automatically switch *longer*.
  /// Two reasons, and the first is the one that bites:
  ///
  ///  * A rear camera's role is inferred from the order the platform lists it
  ///    in, because `availableCameras()` publishes no focal length. On a phone
  ///    whose third rear camera is a macro - the Galaxy A54 among them - that
  ///    inference calls it a 2x telephoto, and jumping to it at 3x would show
  ///    a subject 4 cm away in perfect focus and everything else as mud.
  ///  * Going wider than 1x is impossible without the ultra-wide, so that
  ///    switch is forced by physics. Going longer is only ever an optical
  ///    *improvement* over a crop, and an improvement that cannot be verified
  ///    is not worth a black preview and a jump in framing nobody asked for.
  ///    The pills still select a longer lens explicitly.
  ///
  /// A target the capped candidates genuinely cannot reach still falls through
  /// to the nearest band, so a telephoto is opened when it is the only camera
  /// that can do the job.
  LensBand _idealFor(double target) {
    if (bands.isEmpty) return active;

    /// The main camera's factor: the longest lens taken automatically.
    const double reference = 1;

    LensBand? best;
    for (final LensBand band in bands) {
      if (!band.contains(target)) continue;
      // At or below the target, so the lens is cropping in rather than being
      // asked for a field of view it does not have.
      if (band.lens.zoomFactor > target) continue;
      if (band.lens.zoomFactor > reference) continue;
      if (best == null || band.lens.zoomFactor > best.lens.zoomFactor) {
        best = band;
      }
    }
    if (best != null) return best;

    // Nothing sits at or below the target - the target is wider than the
    // widest lens, or a gap between two bands. Take whichever band comes
    // closest to holding it.
    return bands.reduce(
      (LensBand closest, LensBand band) =>
          _distanceTo(band, target) < _distanceTo(closest, target)
              ? band
              : closest,
    );
  }

  double _distanceTo(LensBand band, double target) {
    if (band.contains(target)) return 0;
    return target < band.min ? band.min - target : target - band.max;
  }

  @override
  List<Object?> get props => <Object?>[bands, active];
}
