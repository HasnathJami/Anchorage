import 'dart:io';

import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/core/utils/formatters.dart';
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
    this.height = 230,
    super.key,
  });

  final double zoom;
  final double minZoom;
  final double maxZoom;
  final ValueChanged<double> onZoomChanged;
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
        onTapDown: (TapDownDetails details) => _handleDrag(details.localPosition.dy),
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

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: count == 0
          ? 'No photographs in this batch yet'
          : 'Review $count photograph${count == 1 ? '' : 's'} in this batch',
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 62,
          height: 62,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Container(
                width: 54,
                height: 54,
                margin: const EdgeInsets.only(top: 8),
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
                  right: 0,
                  top: 0,
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

/// The tap-to-focus reticle.
///
/// A square that snaps in and settles, mirroring the platform camera apps the
/// user already knows - the familiarity is the point.
class FocusReticle extends StatelessWidget {
  const FocusReticle({required this.position, super.key});

  final Offset position;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx - 36,
      top: position.dy - 36,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          key: ValueKey<Offset>(position),
          tween: Tween<double>(begin: 1.35, end: 1),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          builder: (BuildContext context, double scale, Widget? child) =>
              Transform.scale(scale: scale, child: child),
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFFFD24A), width: 1.6),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFFFFD24A),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
