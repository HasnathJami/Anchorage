import 'dart:io';

import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/core/utils/formatters.dart';
import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
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
    super.key,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? semanticLabel;
  final double size;
  final double iconSize;
  final bool filled;

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
            child: Icon(icon, size: iconSize, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// The vertical zoom slider on the right edge.
///
/// Built by hand rather than with a rotated [Slider] for two reasons: a
/// `RotatedBox`-wrapped Slider inverts its own gesture axis (dragging up
/// decreases the value), and the reference design needs end labels inside the
/// track, which Slider cannot express.
class VerticalZoomSlider extends StatelessWidget {
  const VerticalZoomSlider({
    required this.settings,
    required this.onZoomChanged,
    this.height = 210,
    super.key,
  });

  final CameraSettings settings;
  final ValueChanged<double> onZoomChanged;
  final double height;

  static const double _trackWidth = 30;
  static const double _knobSize = 16;

  @override
  Widget build(BuildContext context) {
    final HarborColorsAccess colors = HarborColorsAccess(context);
    final double usable = height - _knobSize - 36;

    return SizedBox(
      width: _trackWidth,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (DragUpdateDetails details) =>
            _handleDrag(details.localPosition.dy, usable),
        onTapDown: (TapDownDetails details) =>
            _handleDrag(details.localPosition.dy, usable),
        child: Container(
          decoration: BoxDecoration(
            color: colors.scrim,
            borderRadius: BorderRadius.circular(_trackWidth / 2),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: <Widget>[
              _EndLabel(text: Formatters.zoom(settings.maxZoom)),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    // Fraction 0 sits at the bottom (min zoom), 1 at the top.
                    final double travel = constraints.maxHeight - _knobSize;
                    final double top = travel * (1 - settings.zoomFraction);

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
                          top: top.clamp(0.0, travel),
                          child: Container(
                            width: _knobSize,
                            height: _knobSize,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              _EndLabel(text: Formatters.zoom(settings.minZoom)),
            ],
          ),
        ),
      ),
    );
  }

  void _handleDrag(double dy, double usable) {
    if (usable <= 0) return;
    // Invert: dragging towards the top of the screen zooms in.
    final double fraction = (1 - ((dy - 18) / usable)).clamp(0.0, 1.0);
    onZoomChanged(
      settings.minZoom + fraction * (settings.maxZoom - settings.minZoom),
    );
  }
}

class _EndLabel extends StatelessWidget {
  const _EndLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 8,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
      ),
    );
  }
}

/// The "0.5 / 1 / 2" lens pills.
///
/// The selected pill inverts to a solid white circle exactly as in the
/// reference; the others stay translucent so they read as available options
/// rather than as disabled ones.
class LensSelector extends StatelessWidget {
  const LensSelector({
    required this.lenses,
    required this.activeLens,
    required this.onSelected,
    super.key,
  });

  final List<CameraLens> lenses;
  final CameraLens? activeLens;
  final ValueChanged<CameraLens> onSelected;

  @override
  Widget build(BuildContext context) {
    // A single-lens device gets no selector at all rather than one pill that
    // does nothing when tapped.
    if (lenses.length < 2) return const SizedBox.shrink();

    final HarborColorsAccess colors = HarborColorsAccess(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: lenses.map((CameraLens lens) {
        final bool selected = lens.id == activeLens?.id;
        final double size = selected ? 42 : 34;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Semantics(
            button: true,
            selected: selected,
            label: '${lens.label} times zoom',
            child: GestureDetector(
              onTap: () => onSelected(lens),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? Colors.white : colors.scrim,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  selected ? '${lens.label}x' : lens.label,
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
    final HarborColorsAccess colors = HarborColorsAccess(context);

    return Semantics(
      button: true,
      label: '$count photograph${count == 1 ? '' : 's'} in this batch',
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
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
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

/// Small helper so the camera widgets read colours without four lines of
/// `Theme.of(context).extension<...>()` each.
class HarborColorsAccess {
  HarborColorsAccess(BuildContext context)
      : scrim = context.harborColors.cameraScrim,
        primary = context.harborColors.primary;

  final Color scrim;
  final Color primary;
}
