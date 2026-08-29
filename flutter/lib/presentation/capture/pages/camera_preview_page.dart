import 'package:anchorage_harbor/app/anchorage_harbor_app.dart';
import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/di/injector.dart';
import 'package:anchorage_harbor/data/datasources/camera_plugin_adapter.dart';
import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/zoom_stop.dart';
import 'package:anchorage_harbor/presentation/capture/bloc/camera_bloc.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/batch_review_sheet.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/camera_chrome.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/camera_settings_sheet.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
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
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              _PreviewSurface(state: state),
              _ChromeOverlay(state: state),
              if (!state.isReady) _BlockingOverlay(state: state),
            ],
          ),
        );
      },
    );
  }

  void _showNotice(BuildContext context, CameraState state) {
    final CameraNotice? notice = state.notice;
    if (notice == null) return;

    final (String message, SnackBarAction? action) = switch (notice) {
      BatchQueuedNotice(:final count) => (
          '$count photograph${count == 1 ? '' : 's'} handed to the sync engine.',
          SnackBarAction(
            label: 'VIEW',
            onPressed: () =>
                Navigator.of(context).pushNamed(HarborRoutes.uploads),
          ),
        ),
      CameraStorageNotice() => (
          'Could not write to local storage. Free some space and try again.',
          null,
        ),
      CameraHardwareNotice(:final detail) => (
          switch (detail) {
            'no-camera' => 'No usable camera was found on this device.',
            'interrupted' =>
              'The camera was interrupted. Reopening the preview.',
            _ => 'The camera could not complete that action.',
          },
          null,
        ),
      CameraFlashUnavailableNotice() => (
          'This camera has no flash.',
          null,
        ),
      TorchTimedOutNotice() => (
          'The torch switched off to save battery.',
          null,
        ),
      CameraPermissionNotice() => ('Camera permission is required.', null),
    };

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }
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

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (_) => bloc.add(const CameraPinchStarted()),
          onScaleUpdate: (ScaleUpdateDetails details) {
            // `onScaleUpdate` also fires for single-finger pans with scale 1;
            // ignoring those keeps a tap-to-focus from nudging the zoom.
            if (details.pointerCount < 2) return;
            bloc.add(CameraPinchZoomed(details.scale));
          },
          onTapUp: (TapUpDetails details) {
            if (!state.isReady) return;
            bloc.add(
              CameraFocusRequested(
                x: details.localPosition.dx / size.width,
                y: details.localPosition.dy / size.height,
              ),
            );
          },
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (state.isReady &&
                  controller != null &&
                  controller.value.isInitialized)
                // Keyed on previewKey so a re-opened controller produces a new
                // platform view rather than reusing a disposed texture.
                KeyedSubtree(
                  key: ValueKey<int>(state.session!.previewKey),
                  child: _FittedPreview(controller: controller),
                )
              else
                const _PreviewPlaceholder(),
              if (state.showsGrid) const CompositionGrid(),
              // A gentle darkening at both ends so white chrome stays legible
              // over a bright sky or a white wall. Without it the reference
              // design's floating controls disappear outdoors.
              const _ChromeScrim(),
              if (state.focusPoint != null)
                FocusReticle(
                  position: Offset(
                    state.focusPoint!.x * size.width,
                    state.focusPoint!.y * size.height,
                  ),
                ),
            ],
          ),
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
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: controller.value.previewSize?.height ?? 1080,
          height: controller.value.previewSize?.width ?? 1920,
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
  const _ChromeOverlay({required this.state});

  final CameraState state;

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
                  semanticLabel: 'Close camera',
                  onPressed: () => Navigator.of(context).maybePop(),
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
                    child: VerticalZoomSlider(
                      zoom: state.settings.zoom,
                      minZoom: state.settings.minZoom,
                      maxZoom: state.settings.maxZoom,
                      height: height,
                      onZoomChanged: (double zoom) =>
                          bloc.add(CameraZoomChanged(zoom)),
                    ),
                  ),
                );
              },
            ),
          ),

          // ------------------------------------------------- quick-zoom row
          ZoomStopSelector(
            stops: state.zoomStops,
            zoom: state.settings.zoom,
            onSelected: (ZoomStop stop) =>
                bloc.add(CameraZoomStopSelected(stop)),
          ),

          const SizedBox(height: 18),

          // ---------------------------------------------------- shutter row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                BatchThumbnail(
                  count: state.shotCount,
                  latestPath: state.batch?.latest?.filePath,
                  onTap: () => _openBatchReview(context, state),
                ),
                ShutterButton(
                  isCapturing: state.isCapturing,
                  enabled: state.isReady && !state.isCapturing,
                  onPressed: () => bloc.add(const CameraShutterPressed()),
                ),
                GlassCircleButton(
                  icon: Icons.flip_camera_android_outlined,
                  semanticLabel: state.isFrontFacing
                      ? 'Switch to the rear camera'
                      : 'Switch to the front camera',
                  size: 44,
                  onPressed: () => _flip(context, state),
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
        flashMode: state.flashMode,
        showsGrid: state.showsGrid,
        onFlashModeSelected: (CaptureFlashMode mode) =>
            bloc.add(CameraFlashModeSelected(mode)),
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
          backgroundColor: count > 0 ? colors.primary : colors.primary.withValues(alpha: 0.45),
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
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.anchor, size: 18),
                  const SizedBox(width: 10),
                  Text(
                    count > 0 ? 'UPLOAD BATCH ($count)' : 'UPLOAD MANAGER',
                    style: context.harborText.button,
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
