import 'package:anchorage_harbor/app/anchorage_harbor_app.dart';
import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/core/designsystem/harbor_toast.dart';
import 'package:anchorage_harbor/di/injector.dart';
import 'package:anchorage_harbor/data/datasources/camera_plugin_adapter.dart';
import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/preview_crop.dart';
import 'package:anchorage_harbor/domain/entities/zoom_stop.dart';
import 'package:anchorage_harbor/presentation/capture/bloc/camera_bloc.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/batch_review_sheet.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/camera_chrome.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/camera_settings_sheet.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/exit_confirmation_dialog.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// `CameraPreviewScreen` from the brief.
///
/// The layout is a transcription of the reference design, top to bottom:
///
/// | Reference | Here |
/// | --- | --- |
/// | close button in a dark disc, top left | [GlassCircleButton] |
/// | bare flash and gear glyphs, top right | [_FlashButton], [_SettingsButton] |
/// | vertical zoom slider hugging the right edge | [VerticalZoomSlider] |
/// | three round `0.5 / 1 / 2` buttons | [ZoomStopSelector] |
/// | thumbnail + blue count badge, shutter, lens flip | [BatchThumbnail], [ShutterButton] |
/// | full-width blue `UPLOAD BATCH (n)` | [_UploadBatchButton] |
///
/// The widget observes the app lifecycle itself. That is not incidental: on
/// Android the OS reclaims the camera when the app is backgrounded, and a
/// screen that does not hand the sensor back returns to a frozen black
/// rectangle after a phone call.
class CameraPreviewPage extends StatefulWidget {
  const CameraPreviewPage({super.key});

  @override
  State<CameraPreviewPage> createState() => _CameraPreviewPageState();
}

class _CameraPreviewPageState extends State<CameraPreviewPage>
    with WidgetsBindingObserver {
  /// True while the exit confirmation is on screen or being acted on.
  bool _exitPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final CameraBloc bloc = context.read<CameraBloc>();

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        bloc.add(const CameraPaused());
      case AppLifecycleState.resumed:
        bloc.add(const CameraResumed());
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<CameraBloc, CameraState>(
      listenWhen: (CameraState previous, CameraState current) =>
          previous.notice != current.notice && current.notice != null,
      listener: _showNotice,
      builder: (BuildContext context, CameraState state) {
        // The camera is the app's root route, so a back press here is a request
        // to close the app, not to pop a screen. `canPop: false` intercepts it
        // and routes it through exactly the same confirmation as the ✕ — one
        // exit path, asked the same way whichever gesture started it.
        return PopScope<Object?>(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (didPop) return;
            _requestExit(state);
          },
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _PreviewSurface(state: state),
                _ChromeOverlay(state: state, onClose: () => _requestExit(state)),
                // Not while a rear camera is handing over to another one: the
                // sensor is gone for a few hundred milliseconds, but the
                // chrome is still true and still worth touching, and throwing
                // a cold-start spinner over it is the flicker that pinching
                // past 1x used to produce.
                if (!state.isReady && !state.isSwitchingLens)
                  _BlockingOverlay(state: state),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Confirm, optionally hand the batch over, then close the app.
  ///
  /// Guarded against re-entry: on Android a back press and predictive-back can
  /// both arrive while the dialog is already up, and two stacked confirmations
  /// is a bug the user has to dismiss twice.
  Future<void> _requestExit(CameraState state) async {
    if (_exitPending) return;
    _exitPending = true;

    try {
      final CameraBloc bloc = context.read<CameraBloc>();

      final ExitIntent intent = await ExitConfirmationDialog.show(
        context,
        // Only work that is still the user's to lose counts. Anything already
        // in the queue is durable and survives the app closing, so warning
        // about it would be a false alarm.
        pendingShots: state.canSubmitBatch ? state.shotCount : 0,
      );

      if (intent == ExitIntent.cancel) return;

      if (intent == ExitIntent.uploadThenExit && !await _handOverBatch(bloc)) {
        // The enqueue failed. The Bloc has already raised the notice that says
        // why; closing now would do exactly the thing the user chose to avoid.
        return;
      }

      // `SystemNavigator.pop` rather than `exit(0)`: it asks the platform to
      // finish the activity, which lets Flutter and the plugins shut down in
      // order. Killing the process outright is how a half-written SQLite
      // transaction becomes a corrupted queue.
      await SystemNavigator.pop();
    } finally {
      if (mounted) _exitPending = false;
    }
  }

  /// Submits the batch and waits for the engine to accept it.
  ///
  /// Returns whether the queue actually took it.
  Future<bool> _handOverBatch(CameraBloc bloc) async {
    // Subscribed *before* the event is dispatched: a Bloc stream does not
    // replay, and the hand-over can complete inside a microtask.
    final Future<CameraState> settled =
        bloc.stream.firstWhere((CameraState state) => !state.isSubmitting);

    bloc.add(const CameraBatchSubmitted());

    final CameraState result = await settled.timeout(
      // A backstop, not a deadline. Enqueueing a batch is a single SQLite
      // transaction; if it has not answered in eight seconds something is very
      // wrong, and hanging the exit on it forever would be worse.
      const Duration(seconds: 8),
      onTimeout: () => bloc.state,
    );

    return !result.hasShots;
  }

  void _showNotice(BuildContext context, CameraState state) {
    final CameraNotice? notice = state.notice;
    if (notice == null) return;

    // Confirmations get [HarborToast.brief]; anything the user has to read and
    // act on gets [HarborToast.standard]. A hand-over the user just triggered
    // themselves is the one message that must not linger over the shutter.
    final (String message, Duration life, HarborToastAction? action) =
        switch (notice) {
      BatchQueuedNotice(:final count) => (
          '$count photograph${count == 1 ? '' : 's'} handed to the sync engine.',
          HarborToast.brief,
          (
            label: 'VIEW',
            onPressed: () =>
                Navigator.of(context).pushNamed(HarborRoutes.uploads),
          ),
        ),
      CameraStorageNotice() => (
          'Could not write to local storage. Free some space and try again.',
          HarborToast.standard,
          null,
        ),
      CameraHardwareNotice(:final detail) => (
          switch (detail) {
            'no-camera' => 'No usable camera was found on this device.',
            'interrupted' =>
              'The camera was interrupted. Reopening the preview.',
            _ => 'The camera could not complete that action.',
          },
          HarborToast.standard,
          null,
        ),
      CameraFlashUnavailableNotice() => (
          'This camera has no flash.',
          HarborToast.standard,
          null,
        ),
      TorchTimedOutNotice() => (
          'The torch switched off to save battery.',
          HarborToast.brief,
          null,
        ),
      CameraPermissionNotice() => (
          'Camera permission is required.',
          HarborToast.standard,
          null,
        ),
    };

    HarborToast.show(
      context,
      message: message,
      duration: life,
      action: action,
    );
  }
}

/// The size the preview is laid out at before it is scaled to cover.
///
/// Shared with [_FittedPreview] rather than written twice: the crop maths and
/// the widget that performs the crop have to agree about the source, and the
/// axes are swapped here because a portrait preview reports its size in the
/// sensor's own landscape orientation.
Size _previewChildSize(CameraController? controller) {
  final Size? preview = controller?.value.previewSize;
  if (preview == null) return const Size(1080, 1920);
  return Size(preview.height, preview.width);
}

/// A stored sensor point, as an offset in the preview's own coordinates.
Offset _viewportOffset(FocusPoint point, PreviewCrop crop, Size size) {
  final ({double x, double y}) mapped = crop.toViewport(x: point.x, y: point.y);
  return Offset(mapped.x * size.width, mapped.y * size.height);
}

/// The live preview, plus the pinch and tap gestures that act on it.
class _PreviewSurface extends StatelessWidget {
  const _PreviewSurface({required this.state});

  final CameraState state;

  @override
  Widget build(BuildContext context) {
    final CameraBloc bloc = context.read<CameraBloc>();
    final CameraController? controller = getIt<CameraPluginAdapter>().controller;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = Size(constraints.maxWidth, constraints.maxHeight);

        // The preview is painted to *cover* this box, so a tap on screen and
        // the point it names on the sensor are not the same point. See
        // [PreviewCrop] - without this, tap-to-focus focused somewhere the
        // user did not touch, by more the further from centre they tapped.
        //
        // Built from the size the controller actually reported, never from
        // the placeholder [_previewChildSize] falls back to: a fabricated
        // shape would map taps confidently and wrongly for the moment before
        // the real one arrives. No reported size means no crop.
        final Size? reported = controller?.value.previewSize;
        final PreviewCrop crop = reported == null
            ? PreviewCrop.none
            : PreviewCrop.of(
                // Axes swapped, as in [_previewChildSize]: a portrait preview
                // reports its size in the sensor's own landscape orientation.
                sourceAspect: reported.height / reported.width,
                viewportAspect: size.width / size.height,
              );

        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (_) => bloc.add(const CameraPinchStarted()),
              onScaleUpdate: (ScaleUpdateDetails details) {
                // `onScaleUpdate` also fires for single-finger pans with scale
                // 1; ignoring those keeps a tap-to-focus from nudging the zoom.
                if (details.pointerCount < 2) return;
                bloc.add(CameraPinchZoomed(details.scale));
              },
              // Fingers up. If the pinch travelled past what the open camera
              // can show, this is when the other one is opened - once, and not
              // under a moving thumb.
              onScaleEnd: (_) => bloc.add(const CameraZoomGestureEnded()),
              onTapUp: (TapUpDetails details) {
                if (!state.isReady) return;

                final ({double x, double y}) point = crop.toSensor(
                  x: details.localPosition.dx / size.width,
                  y: details.localPosition.dy / size.height,
                );

                bloc.add(CameraFocusRequested(x: point.x, y: point.y));
              },
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (state.isReady &&
                      controller != null &&
                      controller.value.isInitialized)
                    // Keyed on previewKey so a re-opened controller produces a
                    // new platform view rather than reusing a disposed texture.
                    KeyedSubtree(
                      key: ValueKey<int>(state.session!.previewKey),
                      child: _FittedPreview(controller: controller),
                    )
                  else
                    const _PreviewPlaceholder(),
                  if (state.showsGrid) const CompositionGrid(),
                  // A gentle darkening at both ends so white chrome stays
                  // legible over a bright sky or a white wall. Without it the
                  // reference design's floating controls disappear outdoors.
                  const _ChromeScrim(),
                ],
              ),
            ),

            // Deliberately a *sibling* of the gesture detector rather than its
            // child, and painted after it. The reticle now carries two
            // controls of its own, and nested inside the focus detector every
            // tap on the padlock would also register as "re-meter here".
            if (state.focusPoint != null)
              FocusReticle(
                // Back out through the same crop, so the ring is drawn under
                // the finger rather than where the sensor thinks it is.
                position: _viewportOffset(state.focusPoint!, crop, size),
                bounds: size,
                isLocked: state.isMeteringLocked,
                exposure: state.exposureRange,
                exposureOffset: state.exposureOffset,
                onLockToggled: () => bloc.add(const CameraFocusLockToggled()),
                onExposureChanged: (double ev) =>
                    bloc.add(CameraExposureOffsetChanged(ev)),
              ),
          ],
        );
      },
    );
  }
}

/// Fills the screen with the preview without distorting it.
///
/// `CameraPreview` alone letterboxes, because a sensor is 4:3 while a phone
/// screen is nearer 20:9. Scaling to cover and clipping the overflow is what
/// every native camera app does, and it is what the reference design shows.
class _FittedPreview extends StatelessWidget {
  const _FittedPreview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final Size child = _previewChildSize(controller);

    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: child.width,
          height: child.height,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}

/// Top and bottom gradients that keep the floating controls readable.
class _ChromeScrim extends StatelessWidget {
  const _ChromeScrim();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color(0x59000000),
              Color(0x00000000),
              Color(0x00000000),
              Color(0x99000000),
            ],
            stops: <double>[0, 0.18, 0.55, 1],
          ),
        ),
      ),
    );
  }
}

/// What fills the frame before the sensor opens, and in previews and tests
/// where no camera exists. A gradient in the reference design's own tones,
/// rather than a black void that reads as a crash.
class _PreviewPlaceholder extends StatelessWidget {
  const _PreviewPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF2C3B3B), Color(0xFF5A7878), Color(0xFF1B2626)],
        ),
      ),
    );
  }
}

/// All the floating controls.
class _ChromeOverlay extends StatelessWidget {
  const _ChromeOverlay({required this.state, required this.onClose});

  final CameraState state;

  /// The ✕. It goes through the page rather than popping, because on the root
  /// route there is nothing to pop — which is exactly what the button used to
  /// do: nothing at all.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final CameraBloc bloc = context.read<CameraBloc>();

    return SafeArea(
      child: Column(
        children: <Widget>[
          // ---------------------------------------------------- top controls
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
            child: Row(
              children: <Widget>[
                GlassCircleButton(
                  icon: Icons.close,
                  semanticLabel: 'Close Anchorage Harbor',
                  onPressed: onClose,
                ),
                const Spacer(),
                _FlashButton(state: state),
                const SizedBox(width: 4),
                _SettingsButton(state: state),
              ],
            ),
          ),

          const SizedBox(height: 10),
          _CaptureModeLabel(state: state),

          // ---------------------------------------------------- zoom slider
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                // Sized against what is actually left rather than a constant:
                // on a short screen a fixed 230 dp slider is an overflow
                // stripe across the preview, which is a rendering bug the user
                // sees before they see the camera.
                final double height =
                    (constraints.maxHeight - 24).clamp(96.0, 230.0);

                return Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    // The band across *every* rear camera, not the open
                    // sensor's own: on a phone that publishes its ultra-wide
                    // separately the open camera stops at 1x, and a slider
                    // built from it could never offer the 0.5x the pills do.
                    child: VerticalZoomSlider(
                      zoom: state.effectiveZoom,
                      minZoom: state.reachableZoomRange.min,
                      maxZoom: state.reachableZoomRange.max,
                      height: height,
                      onZoomChanged: (double zoom) =>
                          bloc.add(CameraZoomChanged(zoom)),
                      onZoomSettled: () =>
                          bloc.add(const CameraZoomGestureEnded()),
                    ),
                  ),
                );
              },
            ),
          ),

          // ------------------------------------------------- quick-zoom row
          ZoomStopSelector(
            stops: state.zoomStops,
            zoom: state.effectiveZoom,
            onSelected: (ZoomStop stop) =>
                bloc.add(CameraZoomStopSelected(stop)),
          ),

          const SizedBox(height: 18),

          // ---------------------------------------------------- shutter row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            // The shutter is centred on the *screen*, not spaced evenly between
            // its neighbours. `spaceBetween` looks equivalent and is not: the
            // thumbnail is 62 dp and the flip button 44, so the shutter used to
            // sit 9 dp right of centre — enough to read as a mistake on a
            // screen whose whole composition is symmetrical about it. Matching
            // `Expanded` slots make the centring exact whatever the flanking
            // controls weigh.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: BatchThumbnail(
                      count: state.shotCount,
                      latestPath: state.batch?.latest?.filePath,
                      onTap: () => _openBatchReview(context, state),
                    ),
                  ),
                ),
                ShutterButton(
                  isCapturing: state.isCapturing,
                  enabled: state.isReady && !state.isCapturing,
                  onPressed: () => bloc.add(const CameraShutterPressed()),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: GlassCircleButton(
                      icon: Icons.flip_camera_android_outlined,
                      semanticLabel: state.isFrontFacing
                          ? 'Switch to the rear camera'
                          : 'Switch to the front camera',
                      size: 44,
                      onPressed: () => _flip(context, state),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // ------------------------------------------------- upload the batch
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: _UploadBatchButton(state: state),
          ),
        ],
      ),
    );
  }

  void _openBatchReview(BuildContext context, CameraState state) {
    final CameraBloc bloc = context.read<CameraBloc>();

    if (!state.hasShots) {
      // Nothing of this user's own is waiting, so the useful destination is
      // the queue - which may well be full of earlier batches.
      Navigator.of(context).pushNamed(HarborRoutes.uploads);
      return;
    }

    BatchReviewSheet.show(
      context,
      bloc: bloc,
      onOpenUploads: () {
        Navigator.of(context).pop();
        Navigator.of(context).pushNamed(HarborRoutes.uploads);
      },
    );
  }

  void _flip(BuildContext context, CameraState state) {
    final CameraBloc bloc = context.read<CameraBloc>();
    final CameraLens? active = state.session?.activeLens;
    if (active == null) return;

    final CameraLens? target = state.lenses.cast<CameraLens?>().firstWhere(
          (CameraLens? lens) => active.kind == CameraLensKind.front
              ? lens?.kind != CameraLensKind.front
              : lens?.kind == CameraLensKind.front,
          orElse: () => null,
        );

    if (target != null) bloc.add(CameraLensSelected(target));
  }
}

/// The flash glyph, top right.
///
/// A bare icon rather than a disc, as in the reference. The *glyph* carries
/// the mode - `flash_off`, `flash_auto`, `flash_on`, `highlight` are four
/// distinct shapes - so the amber tint when the flash is armed only reinforces
/// a state that is already legible without colour.
class _FlashButton extends StatelessWidget {
  const _FlashButton({required this.state});

  final CameraState state;

  @override
  Widget build(BuildContext context) {
    final bool armed = state.flashMode != CaptureFlashMode.off;

    return GlassCircleButton(
      icon: switch (state.flashMode) {
        CaptureFlashMode.off => Icons.flash_off,
        CaptureFlashMode.auto => Icons.flash_auto,
        CaptureFlashMode.always => Icons.flash_on,
        CaptureFlashMode.torch => Icons.highlight,
      },
      // Announced with its current mode rather than as a bare "Flash mode": a
      // cycling button whose label never changes tells a screen-reader user
      // nothing about what pressing it just did.
      semanticLabel: 'Flash: ${switch (state.flashMode) {
        CaptureFlashMode.off => 'off',
        CaptureFlashMode.auto => 'automatic',
        CaptureFlashMode.always => 'on',
        CaptureFlashMode.torch => 'torch',
      }}',
      filled: false,
      iconSize: 22,
      tint: armed ? context.harborColors.caution : Colors.white,
      onPressed: () => context.read<CameraBloc>().add(const CameraFlashToggled()),
    );
  }
}

class _SettingsButton extends StatelessWidget {
  const _SettingsButton({required this.state});

  final CameraState state;

  @override
  Widget build(BuildContext context) {
    final CameraBloc bloc = context.read<CameraBloc>();

    return GlassCircleButton(
      icon: Icons.settings_outlined,
      semanticLabel: 'Capture settings',
      filled: false,
      iconSize: 22,
      onPressed: () => CameraSettingsSheet.show(
        context,
        showsGrid: state.showsGrid,
        onGridToggled: () => bloc.add(const CameraGridToggled()),
        onOpenUploads: () {
          Navigator.of(context).pop();
          Navigator.of(context).pushNamed(HarborRoutes.uploads);
        },
      ),
    );
  }
}

/// The small centred caption under the top bar.
///
/// The reference shows a word here. It says what the shutter is currently
/// doing rather than naming the screen, because "this frame joins a batch of
/// four" is the one thing about this camera that differs from every other
/// camera the user has held.
class _CaptureModeLabel extends StatelessWidget {
  const _CaptureModeLabel({required this.state});

  final CameraState state;

  @override
  Widget build(BuildContext context) {
    final String label =
        state.hasShots ? 'BATCH · ${state.shotCount} CAPTURED' : 'BATCH CAPTURE';

    return Text(
      label,
      style: context.harborText.eyebrow.copyWith(
        color: Colors.white70,
        fontSize: 11,
        shadows: const <Shadow>[Shadow(color: Color(0x99000000), blurRadius: 4)],
      ),
    );
  }
}

class _UploadBatchButton extends StatelessWidget {
  const _UploadBatchButton({required this.state});

  final CameraState state;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;
    final CameraBloc bloc = context.read<CameraBloc>();
    final int count = state.shotCount;

    return SizedBox(
      height: 52,
      width: double.infinity,
      child: FilledButton(
        // With an empty batch the button still leads somewhere useful - the
        // queue - instead of being a dead grey rectangle for the whole of a
        // first run.
        onPressed: state.canSubmitBatch
            ? () => bloc.add(const CameraBatchSubmitted())
            : (state.isSubmitting
                ? null
                : () => Navigator.of(context).pushNamed(HarborRoutes.uploads)),
        style: FilledButton.styleFrom(
          // Solid in both states. Fading it while the batch is empty made a
          // button that is perfectly usable — it opens the Upload Manager —
          // look disabled, which is exactly what the reference's one strong
          // blue call to action is not.
          backgroundColor: colors.primary,
          disabledBackgroundColor: colors.primary.withValues(alpha: 0.35),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white60,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(HarborRadius.button),
          ),
        ),
        child: state.isSubmitting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            // `mainAxisSize.min` plus a flexible label: the button is as wide
            // as the screen, but its *contents* are laid out at their natural
            // size, and at 1.3x type the anchor, the gap and the label were
            // 2 dp too wide for it. A call to action that paints a yellow and
            // black overflow bar is worse than one that ellipsises.
            : Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.anchor, size: 18),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      count > 0 ? 'UPLOAD BATCH ($count)' : 'UPLOAD MANAGER',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.harborText.button,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Covers the preview whenever it cannot be shown, and says what to do about
/// it. Every state here offers an action - a camera screen that only says
/// "permission denied" leaves the user stuck.
class _BlockingOverlay extends StatelessWidget {
  const _BlockingOverlay({required this.state});

  final CameraState state;

  @override
  Widget build(BuildContext context) {
    if (state.phase == CameraPhase.initialising) {
      return const ColoredBox(
        color: Colors.black38,
        child: Center(
          child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2),
        ),
      );
    }

    final CameraBloc bloc = context.read<CameraBloc>();
    final HarborColors colors = context.harborColors;

    final (IconData icon, String title, String body, String action, VoidCallback onAction) =
        switch (state.phase) {
      CameraPhase.permissionRequired => (
          Icons.photo_camera_outlined,
          'Camera access needed',
          'Anchorage Harbor captures evidence photographs. The camera is used '
              'only while this screen is open.',
          'ALLOW CAMERA',
          () => bloc.add(const CameraPermissionRequested()),
        ),
      CameraPhase.permissionBlocked => (
          Icons.lock_outline,
          'Camera access is blocked',
          'Android will not ask again. Enable the camera for Anchorage Harbor '
              'in system settings to continue.',
          'OPEN SETTINGS',
          () => bloc.add(const CameraSettingsRequested()),
        ),
      CameraPhase.unavailable => (
          Icons.no_photography_outlined,
          'No camera available',
          'This device did not report a usable camera. You can still review '
              'and upload anything already captured.',
          'OPEN UPLOAD MANAGER',
          () => Navigator.of(context).pushNamed(HarborRoutes.uploads),
        ),
      _ => (
          Icons.refresh,
          'Preview paused',
          'The camera was released. Tap to reopen the preview.',
          'REOPEN CAMERA',
          () => bloc.add(const CameraResumed()),
        ),
    };

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.82),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 44, color: colors.primaryBright),
              const SizedBox(height: HarborSpacing.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: context.harborText.screenTitle.copyWith(color: Colors.white),
              ),
              const SizedBox(height: HarborSpacing.xs),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary, fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: HarborSpacing.lg),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: colors.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(HarborRadius.button),
                  ),
                ),
                child: Text(action, style: context.harborText.button),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
