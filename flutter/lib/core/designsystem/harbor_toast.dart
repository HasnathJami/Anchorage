import 'dart:async';

import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:flutter/material.dart';

/// What one of these carries on its right-hand side, if anything.
///
/// A record rather than `SnackBarAction`: that class is welded to the snackbar
/// machinery this file exists to avoid, and it would drag Material's own
/// colours in with it.
typedef HarborToastAction = ({String label, VoidCallback onPressed});

/// A brief message across the **top** of the screen.
///
/// Material's `SnackBar` is a bottom-edge surface, and on the camera that edge
/// is the busiest part of the app: shutter, batch thumbnail, zoom pills and
/// the upload call to action all live there. A snackbar covered the shutter
/// with a confirmation of the shot just taken — the one moment the user is
/// most likely to be reaching for it again. `SnackBar` has no top position
/// (`behavior` chooses between fixed and floating, and both anchor to the
/// bottom), so this is an [OverlayEntry] instead.
///
/// It is deliberately *not* a general notification surface. Persistent
/// conditions get a banner; only momentary events get one of these — see
/// `docs/ERROR-HANDLING.md`.
abstract final class HarborToast {
  /// A confirmation the user already expects, because they just caused it.
  ///
  /// Long enough to read a short sentence, short enough to be gone before the
  /// thumb is back on the shutter.
  static const Duration brief = Duration(milliseconds: 2500);

  /// Anything the user has to read and decide about: a failure, or a message
  /// carrying an action worth travelling to.
  static const Duration standard = Duration(seconds: 4);

  /// The one on screen, if any.
  ///
  /// A single slot rather than a queue, mirroring `hideCurrentSnackBar()`:
  /// two stacked toasts on a phone in portrait is most of the viewfinder, and
  /// the newer message is always the truer one.
  static _ToastHandle? _current;

  /// Shows [message], replacing whatever is already up.
  static void show(
    BuildContext context, {
    required String message,
    Duration duration = brief,
    HarborToastAction? action,
  }) {
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    // No overlay means no route is mounted — during a teardown, or in a test
    // that pumps a widget bare. Dropping the message is correct; throwing over
    // a toast is not.
    if (overlay == null) return;

    dismiss();

    final _ToastHandle handle = _ToastHandle(_ToastSignal());
    handle.entry = OverlayEntry(
      builder: (BuildContext _) => _ToastSurface(
        message: message,
        duration: duration,
        action: action,
        signal: handle.signal,
        onDismissed: () {
          // Only retire the slot if it is still ours: a toast timing out just
          // after being replaced must not clear its successor.
          if (identical(_current, handle)) _current = null;
          handle.entry?.remove();
          handle.entry = null;
          handle.signal.dispose();
        },
      ),
    );

    _current = handle;
    overlay.insert(handle.entry!);
  }

  /// Retracts the current toast, if there is one, with its exit animation.
  static void dismiss() {
    final _ToastHandle? handle = _current;
    if (handle == null) return;
    _current = null;
    handle.signal.retract();
  }
}

/// The overlay entry plus the channel [HarborToast] uses to retract it from
/// outside its own element tree.
class _ToastHandle {
  _ToastHandle(this.signal);

  final _ToastSignal signal;
  OverlayEntry? entry;
}

/// A one-shot "please leave now".
///
/// A [ChangeNotifier] rather than a `GlobalKey` onto the state: a replacement
/// can arrive in the same frame the surface was inserted, before its element
/// exists, and a key that has never been attached is a null dereference.
class _ToastSignal extends ChangeNotifier {
  bool _retracted = false;

  void retract() {
    if (_retracted) return;
    _retracted = true;
    notifyListeners();
  }
}

class _ToastSurface extends StatefulWidget {
  const _ToastSurface({
    required this.message,
    required this.duration,
    required this.action,
    required this.signal,
    required this.onDismissed,
  });

  final String message;
  final Duration duration;
  final HarborToastAction? action;
  final _ToastSignal signal;
  final VoidCallback onDismissed;

  @override
  State<_ToastSurface> createState() => _ToastSurfaceState();
}

class _ToastSurfaceState extends State<_ToastSurface>
    with SingleTickerProviderStateMixin {
  static const Duration _transition = Duration(milliseconds: 220);

  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: _transition,
  );

  Timer? _deadline;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    widget.signal.addListener(_leave);
    _animation.forward();
    // [duration] is time *on screen*, so the clock covers the slide in as well
    // as the dwell — otherwise the message is readable for less than it says.
    _deadline = Timer(_transition + widget.duration, _leave);
  }

  @override
  void dispose() {
    widget.signal.removeListener(_leave);
    _deadline?.cancel();
    _animation.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (_leaving || !mounted) return;
    _leaving = true;
    _deadline?.cancel();
    await _animation.reverse();
    if (mounted) widget.onDismissed();
  }

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;
    final HarborToastAction? action = widget.action;

    return Positioned(
      top: MediaQuery.viewPaddingOf(context).top + HarborSpacing.xs,
      left: HarborSpacing.md,
      right: HarborSpacing.md,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.6),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(
            parent: _animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        ),
        child: FadeTransition(
          opacity: _animation,
          child: Semantics(
            // A snackbar announces itself; an overlay does not unless told to.
            // Without this the confirmation is silent to a screen reader.
            liveRegion: true,
            container: true,
            child: Material(
              color: Colors.transparent,
              child: GestureDetector(
                // A touch anywhere on the body retires it early, and an upward
                // flick throws it back where it came from. There is no close
                // affordance drawn because the thing closes itself.
                onTap: _leave,
                onVerticalDragEnd: (DragEndDetails details) {
                  if ((details.primaryVelocity ?? 0) < 0) _leave();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HarborSpacing.md,
                    vertical: HarborSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: colors.cardActive,
                    borderRadius: const BorderRadius.all(HarborRadius.card),
                    border: Border.all(color: colors.hairline),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 18,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          widget.message,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                      if (action != null) ...<Widget>[
                        const SizedBox(width: HarborSpacing.sm),
                        TextButton(
                          onPressed: () {
                            _leave();
                            action.onPressed();
                          },
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 36),
                            padding: const EdgeInsets.symmetric(
                              horizontal: HarborSpacing.xs,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            action.label,
                            style: context.harborText.eyebrow
                                .copyWith(color: colors.primaryBright),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
