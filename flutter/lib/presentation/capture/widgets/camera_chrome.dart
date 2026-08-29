import 'dart:io';
import 'dart:math' as math;

import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/core/utils/formatters.dart';
import 'package:anchorage_harbor/domain/entities/exposure_range.dart';
import 'package:anchorage_harbor/domain/entities/zoom_stop.dart';
import 'package:flutter/material.dart';

/// A circular, translucent control that floats over the live preview.
///
/// Translucent rather than solid so the frame the user is composing stays
/// visible underneath - a solid chrome button on a camera hides exactly the
/// part of the shot it sits on.
class GlassCircleButton extends StatelessWidget {
  const GlassCircleButton({
    required this.icon,
    required this.onPressed,
    this.semanticLabel,
    this.size = 40,
    this.iconSize = 20,
    this.filled = true,
    this.tint,
    super.key,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? semanticLabel;
  final double size;
  final double iconSize;
  final bool filled;

  /// Overrides the icon colour. Only ever *reinforces* a state the glyph
  /// already carries - see [FlashButton].
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final Color scrim = context.harborColors.cameraScrim;

    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: filled ? scrim : Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: iconSize, color: tint ?? Colors.white),
          ),
        ),
      ),
    );
  }
}

/// The rule-of-thirds overlay.
///
/// Off by default and drawn at a very low opacity: composition guides that
/// shout are worse than no guides, because the user starts framing to the
/// lines instead of to the subject.
class CompositionGrid extends StatelessWidget {
  const CompositionGrid({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(size: Size.infinite, painter: _GridPainter()),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 0.6;

    for (int i = 1; i < 3; i++) {
      final double x = size.width * i / 3;
      final double y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => false;
}

/// The vertical zoom slider on the right edge.
///
/// Built by hand rather than with a rotated [Slider] for two reasons: a
/// `RotatedBox`-wrapped Slider inverts its own gesture axis (dragging up
/// decreases the value), and the reference design needs end labels inside the
/// track, which Slider cannot express.
///
/// The visible track is narrow because the reference shows it narrow; the
/// *touchable* area is padded out to a comfortable target, because a 30 dp
/// column against the edge of the screen is not one.
class VerticalZoomSlider extends StatelessWidget {
  const VerticalZoomSlider({
    required this.zoom,
    required this.minZoom,
    required this.maxZoom,
    required this.onZoomChanged,
    this.onZoomSettled,
    this.height = 230,
    super.key,
  });

  final double zoom;
  final double minZoom;
  final double maxZoom;
  final ValueChanged<double> onZoomChanged;

  /// The finger left the track.
  ///
  /// Separate from [onZoomChanged] because a zoom that needs another camera
  /// must not open it mid-drag - see `CameraZoomGestureEnded`.
  final VoidCallback? onZoomSettled;

  final double height;

  static const double _trackWidth = 30;
  static const double _knobSize = 16;
  static const double _labelBox = 18;
  static const double _touchPadding = 12;

  /// 0 at the bottom (min zoom), 1 at the top.
  double get _fraction => maxZoom <= minZoom
      ? 0
      : ((zoom - minZoom) / (maxZoom - minZoom)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    // A sensor that cannot zoom gets no slider rather than a dead one.
    if (maxZoom <= minZoom) return const SizedBox.shrink();

    return Semantics(
      slider: true,
      label: 'Zoom',
      value: Formatters.zoom(zoom),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (DragUpdateDetails details) =>
            _handleDrag(details.localPosition.dy),
        // Same rule as the pinch: the camera a value needs is opened when the
        // finger stops, not on every frame of the drag.
        onVerticalDragEnd: (_) => onZoomSettled?.call(),
        onVerticalDragCancel: () => onZoomSettled?.call(),
        onTapDown: (TapDownDetails details) => _handleDrag(details.localPosition.dy),
        onTapUp: (_) => onZoomSettled?.call(),
        child: Padding(
          // Transparent margin that is still part of the hit target.
          padding: const EdgeInsets.symmetric(horizontal: _touchPadding),
          child: SizedBox(
            width: _trackWidth,
            height: height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.harborColors.cameraScrim,
                borderRadius: BorderRadius.circular(_trackWidth / 2),
              ),
              child: Padding(
                // Keeps the end labels inside the pill's rounded caps.
                padding: const EdgeInsets.symmetric(vertical: _capPadding),
                child: Column(
                  children: <Widget>[
                    _EndLabel(text: Formatters.zoom(maxZoom)),
                    Expanded(child: _Track(fraction: _fraction)),
                    _EndLabel(text: Formatters.zoom(minZoom)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Padding above the top label, mirrored below the bottom one.
  static const double _capPadding = 3;

  void _handleDrag(double localDy) {
    // The gesture box includes the two end labels and the pill's caps, so the
    // usable travel is the box height less those, less the knob's diameter.
    final double travel =
        height - (2 * _labelBox) - (2 * _capPadding) - _knobSize;
    if (travel <= 0) return;

    final double fromTop =
        (localDy - _labelBox - _capPadding - (_knobSize / 2)) / travel;
    final double fraction = (1 - fromTop).clamp(0.0, 1.0);

    onZoomChanged(minZoom + fraction * (maxZoom - minZoom));
  }
}

class _Track extends StatelessWidget {
  const _Track({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double travel = constraints.maxHeight - VerticalZoomSlider._knobSize;

        return Stack(
          alignment: Alignment.topCenter,
          children: <Widget>[
            Center(
              child: Container(
                width: 2,
                height: constraints.maxHeight,
                color: Colors.white.withValues(alpha: 0.18),
              ),
            ),
            Positioned(
              top: (travel * (1 - fraction)).clamp(0.0, travel),
              child: Container(
                width: VerticalZoomSlider._knobSize,
                height: VerticalZoomSlider._knobSize,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: <BoxShadow>[
                    BoxShadow(color: Color(0x66000000), blurRadius: 4),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _EndLabel extends StatelessWidget {
  const _EndLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: VerticalZoomSlider._labelBox,
      child: Center(
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 8,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

/// The round `0.5 / 1 / 2` quick-zoom buttons.
///
/// The selected button inverts to a solid white disc exactly as in the
/// reference; the others stay translucent so they read as available options
/// rather than as disabled ones.
///
/// The selected button shows the *live* zoom rather than its own label
/// whenever the two differ — pinch to 1.7x and the "1" reads "1.7x". That is
/// what every platform camera app does, and it turns the row into an
/// always-correct read-out instead of a set of buttons that lie between stops.
class ZoomStopSelector extends StatelessWidget {
  const ZoomStopSelector({
    required this.stops,
    required this.zoom,
    required this.onSelected,
    super.key,
  });

  final List<ZoomStop> stops;
  final double zoom;
  final ValueChanged<ZoomStop> onSelected;

  @override
  Widget build(BuildContext context) {
    // One option is not a choice; a lone pill that does nothing when tapped is
    // worse than no row at all.
    if (stops.length < 2) return const SizedBox.shrink();

    final ZoomStop? active = ZoomLadder.activeStop(stops, zoom);
    final Color scrim = context.harborColors.cameraScrim;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: stops.map((ZoomStop stop) {
        final bool selected = stop == active;
        final double size = selected ? 42 : 34;
        final String label = selected && !ZoomLadder.isAt(stop, zoom)
            ? Formatters.zoom(zoom)
            : (selected ? '${stop.label}x' : stop.label);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Semantics(
            button: true,
            selected: selected,
            label: '${stop.label} times zoom',
            child: GestureDetector(
              onTap: () => onSelected(stop),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? Colors.white : scrim,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected ? const Color(0xFF101014) : Colors.white,
                    fontSize: selected ? 12 : 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(growable: false),
    );
  }
}

/// The shutter: a filled disc inside a ring.
///
/// It shrinks slightly while a capture is in flight, which is the cheapest
/// possible confirmation that the tap registered - far more legible on a
/// camera screen than a spinner that would obscure the frame.
class ShutterButton extends StatelessWidget {
  const ShutterButton({
    required this.onPressed,
    required this.isCapturing,
    this.enabled = true,
    super.key,
  });

  final VoidCallback onPressed;
  final bool isCapturing;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Capture photograph',
      enabled: enabled,
      child: GestureDetector(
        onTap: enabled ? onPressed : null,
        child: Container(
          width: 74,
          height: 74,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
          ),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: isCapturing ? 52 : 60,
              height: isCapturing ? 52 : 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: enabled ? Colors.white : Colors.white54,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Corner thumbnail of the newest shot with the batch count badge.
///
/// Tapping it opens the batch review sheet rather than jumping straight to the
/// Upload Manager: the shots behind this badge have *not* been handed over
/// yet, and the last cheap moment to drop a blurred frame is before it costs
/// the field operator any bandwidth.
class BatchThumbnail extends StatelessWidget {
  const BatchThumbnail({
    required this.count,
    required this.latestPath,
    required this.onTap,
    super.key,
  });

  final int count;
  final String? latestPath;
  final VoidCallback onTap;

  /// The side of the visible square. It is also the widget's whole footprint,
  /// which is what keeps it on the shutter's centre line — see below.
  static const double _side = 54;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: count == 0
          ? 'No photographs in this batch yet'
          : 'Review $count photograph${count == 1 ? '' : 's'} in this batch',
      child: GestureDetector(
        onTap: onTap,
        // The box is exactly the square, and the badge *overhangs* it rather
        // than being boxed in with it. The earlier version padded the top of a
        // taller box to leave room for the badge, which shifted the square's
        // optical centre down and left it sitting below the shutter and the
        // lens-flip button it is meant to line up with.
        child: SizedBox(
          width: _side,
          height: _side,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Container(
                width: _side,
                height: _side,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white70, width: 1.5),
                ),
                clipBehavior: Clip.antiAlias,
                child: latestPath == null
                    ? const Icon(Icons.photo_library_outlined,
                        color: Colors.white70, size: 20)
                    : Image.file(
                        File(latestPath!),
                        fit: BoxFit.cover,
                        // Decoded at the size it is drawn, not the size it was
                        // shot at - see [thumbnailCacheWidth].
                        cacheWidth: thumbnailCacheWidth(context, _side),
                        // A thumbnail that fails to decode must not take the
                        // camera screen down with it.
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white70,
                          size: 20,
                        ),
                      ),
              ),
              if (count > 0)
                Positioned(
                  right: -6,
                  top: -8,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 20),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: context.harborColors.primary,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Text(
                      '$count',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tap-to-focus reticle: a ring, a padlock, and a brightness slider.
///
/// Modelled on the platform camera apps the user already knows, because the
/// familiarity *is* the feature — nobody reads a manual for a viewfinder. Three
/// parts, each earning its place:
///
///  * **The ring** marks where the sensor is metering. Decorative and
///    non-interactive, so a tap that lands inside it re-meters there rather
///    than being swallowed.
///  * **The padlock**, sitting on the ring at twelve o'clock, holds focus and
///    exposure where they are. Open by default, closed while locked, and the
///    reticle stops fading while it is closed — a lock the user cannot see is
///    a lock they will forget they set.
///  * **The brightness slider** beneath, a sun on a track, sets exposure
///    compensation for this metering point.
///
/// The whole thing is positioned so the **ring** is centred on the tap, not
/// the widget: the padlock overhangs the top and the slider hangs below, and
/// centring the bounding box would put the reticle visibly above the finger.
class FocusReticle extends StatelessWidget {
  const FocusReticle({
    required this.position,
    required this.bounds,
    required this.isLocked,
    required this.exposure,
    required this.exposureOffset,
    required this.onLockToggled,
    required this.onExposureChanged,
    super.key,
  });

  /// Where the user tapped, in preview pixels.
  final Offset position;

  /// The preview's size, used to keep the reticle on screen near an edge.
  final Size bounds;

  final bool isLocked;
  final ExposureRange exposure;
  final double exposureOffset;
  final VoidCallback onLockToggled;
  final ValueChanged<double> onExposureChanged;

  static const double _ring = 68;

  /// The padlock glyph itself.
  static const double _lockGlyph = 18;

  /// Its touch target. A glyph this small is well under the 48 dp guidance, so
  /// the *hit* box is padded out around it while the drawing stays small
  /// enough to sit in the ring without hiding the subject.
  static const double _lockHit = 44;

  /// Headroom above the ring, so the padlock's hit box is centred on the
  /// ring's twelve o'clock rather than hanging below it.
  static const double _lockHeadroom = _lockHit / 2;

  static const double _trackWidth = 108;
  static const double _trackHeight = 34;
  static const double _gap = 8;

  /// How much of the ring is left unpainted for the padlock to sit in.
  ///
  /// Every platform camera app cuts the ring rather than drawing the lock on
  /// top of the line, and the reason is legibility: a stroke running through
  /// the middle of a padlock reads as a broken circle with something stuck to
  /// it, not as a badge on a ring.
  ///
  /// Derived from the glyph rather than typed in, so the gap stays exactly as
  /// wide as it needs to be if either size changes. Half the gap is the angle
  /// subtended by half the glyph plus a little clearance either side.
  static const double _gapClearance = 3;

  static double get lockGapSweep => 2 *
      math.asin(((_lockGlyph / 2) + _gapClearance) / (_ring / 2));

  double get _width => _trackWidth;
  double get _height => _lockHeadroom + _ring + _gap + _trackHeight;

  /// Distance from the widget's top edge down to the ring's centre.
  double get _ringCentreFromTop => _lockHeadroom + (_ring / 2);

  @override
  Widget build(BuildContext context) {
    final bool canAdjust = exposure.canAdjust;
    final double height = canAdjust ? _height : _lockHeadroom + _ring;

    // Clamped so a tap in a corner does not put the controls half off-screen,
    // where the slider cannot be dragged and the padlock cannot be hit.
    final double left =
        (position.dx - _width / 2).clamp(4.0, (bounds.width - _width - 4).clamp(4.0, double.infinity));
    final double top = (position.dy - _ringCentreFromTop)
        .clamp(4.0, (bounds.height - height - 4).clamp(4.0, double.infinity));

    return Positioned(
      left: left,
      top: top,
      width: _width,
      height: height,
      child: TweenAnimationBuilder<double>(
        // Keyed on the point so a *new* tap replays the snap; adjusting the
        // brightness of an existing one must not.
        key: ValueKey<Offset>(position),
        tween: Tween<double>(begin: 1.25, end: 1),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutBack,
        builder: (BuildContext context, double scale, Widget? child) =>
            Transform.scale(scale: scale, child: child),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              // The width is as load-bearing as the height. A [Stack] takes
              // its size from its *non-positioned* children, and the only one
              // here is the padlock - so without this the stack was 44 dp
              // wide, the positioned 68 dp ring was constrained and clipped to
              // that, and the reticle rendered as two disconnected arcs with
              // no left or right side.
              width: _ring,
              height: _lockHeadroom + _ring,
              child: Stack(
                alignment: Alignment.topCenter,
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned(
                    top: _lockHeadroom,
                    child: IgnorePointer(
                      child: CustomPaint(
                        size: const Size(_ring, _ring),
                        painter: const _MeteringRingPainter(),
                      ),
                    ),
                  ),
                  _LockBadge(isLocked: isLocked, onPressed: onLockToggled),
                ],
              ),
            ),
            if (canAdjust) ...<Widget>[
              const SizedBox(height: _gap),
              _BrightnessSlider(
                exposure: exposure,
                offset: exposureOffset,
                onChanged: onExposureChanged,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The ring, drawn with a gap at twelve o'clock for the padlock.
///
/// A [CustomPaint] rather than a circular [BoxDecoration] because a decoration
/// can only draw a whole border, and the whole point is the piece that is
/// missing.
class _MeteringRingPainter extends CustomPainter {
  const _MeteringRingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      // Rounded, so the two cut ends read as a deliberate gap rather than as a
      // line that ran out.
      ..strokeCap = StrokeCap.round;

    final double gap = FocusReticle.lockGapSweep;

    // Angles are measured from three o'clock, so twelve o'clock is -pi/2.
    // Start half a gap past it and sweep the rest of the way round.
    canvas.drawArc(
      Offset.zero & size,
      -math.pi / 2 + (gap / 2),
      (2 * math.pi) - gap,
      false,
      stroke,
    );
  }

  @override
  bool shouldRepaint(_MeteringRingPainter oldDelegate) => false;
}

/// The padlock that holds focus and exposure.
class _LockBadge extends StatelessWidget {
  const _LockBadge({required this.isLocked, required this.onPressed});

  final bool isLocked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: isLocked,
      label: isLocked
          ? 'Focus and exposure locked. Tap to unlock.'
          : 'Lock focus and exposure',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          // Square, so the glyph's centre lands exactly on the ring's twelve
          // o'clock - which is where the gap in the ring is cut for it.
          width: FocusReticle._lockHit,
          height: FocusReticle._lockHit,
          child: Center(
            child: Icon(
              isLocked ? Icons.lock : Icons.lock_open,
              size: FocusReticle._lockGlyph,
              color: Colors.white,
              shadows: const <Shadow>[
                Shadow(color: Color(0xCC000000), blurRadius: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The sun on a track under the reticle.
class _BrightnessSlider extends StatelessWidget {
  const _BrightnessSlider({
    required this.exposure,
    required this.offset,
    required this.onChanged,
  });

  final ExposureRange exposure;
  final double offset;
  final ValueChanged<double> onChanged;

  static const double _sun = 22;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      slider: true,
      label: 'Brightness',
      value: Formatters.exposure(offset),
      child: SizedBox(
        width: FocusReticle._trackWidth,
        height: FocusReticle._trackHeight,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double travel = constraints.maxWidth - _sun;

            void report(double dx) {
              if (travel <= 0) return;
              onChanged(exposure.evAt(((dx - _sun / 2) / travel).clamp(0.0, 1.0)));
            }

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (DragUpdateDetails details) =>
                  report(details.localPosition.dx),
              onTapDown: (TapDownDetails details) =>
                  report(details.localPosition.dx),
              child: Stack(
                alignment: Alignment.centerLeft,
                children: <Widget>[
                  // The track is drawn full width and the sun rides over it,
                  // exactly as in the platform apps: a line that stops at the
                  // knob reads as a progress bar, which this is not.
                  Center(
                    child: Container(
                      height: 1.4,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                  Positioned(
                    left: (travel * exposure.fractionOf(offset))
                        .clamp(0.0, travel <= 0 ? 0.0 : travel),
                    child: _SunKnob(),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SunKnob extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _BrightnessSlider._sun,
      height: _BrightnessSlider._sun,
      child: Center(
        child: Icon(
          Icons.brightness_7,
          size: 18,
          color: Colors.white,
          shadows: const <Shadow>[
            Shadow(color: Color(0xCC000000), blurRadius: 4),
          ],
        ),
      ),
    );
  }
}
