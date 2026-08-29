import 'dart:io';

import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/core/utils/formatters.dart';
import 'package:anchorage_harbor/domain/entities/capture_batch.dart';
import 'package:anchorage_harbor/presentation/capture/bloc/camera_bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Review the batch that has not been handed over yet.
///
/// This sheet exists because of the moment it protects. A field operator
/// photographs a site with no signal, ends up with fourteen frames, and knows
/// two of them are blurred. Once a batch reaches the queue those two are
/// durable: they will be retried across reboots and eventually cost real
/// bandwidth on a metered link. Deleting them here costs nothing.
///
/// It is deliberately not the Upload Manager. The Upload Manager owns
/// *committed* work; this owns work that is still the user's to change.
class BatchReviewSheet extends StatelessWidget {
  const BatchReviewSheet({
    required this.batch,
    required this.isSubmitting,
    required this.onDiscard,
    required this.onSubmit,
    required this.onOpenUploads,
    super.key,
  });

  final CaptureBatch batch;
  final bool isSubmitting;
  final ValueChanged<String> onDiscard;
  final VoidCallback onSubmit;
  final VoidCallback onOpenUploads;

  /// Opens the sheet. Returns once it is dismissed.
  ///
  /// The [bloc] is handed over explicitly rather than read from the sheet's own
  /// context. A modal route is a *sibling* of the page in the navigator, not a
  /// descendant, so `context.read<CameraBloc>()` inside the sheet would throw -
  /// and without the live state the grid would keep showing a frame the user
  /// had just deleted.
  static Future<void> show(
    BuildContext context, {
    required CameraBloc bloc,
    required VoidCallback onOpenUploads,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) => BlocProvider<CameraBloc>.value(
        value: bloc,
        child: BlocConsumer<CameraBloc, CameraState>(
          // Closing on the last discard, and on a successful hand-over, keeps
          // the sheet from lingering over a grid with nothing in it.
          listenWhen: (CameraState previous, CameraState current) =>
              previous.hasShots && !current.hasShots,
          listener: (BuildContext listenerContext, _) =>
              Navigator.of(listenerContext).pop(),
          builder: (BuildContext builderContext, CameraState state) {
            return BatchReviewSheet(
              batch: state.batch ??
                  CaptureBatch(id: 'empty', startedAt: DateTime.now()),
              isSubmitting: state.isSubmitting,
              onDiscard: (String shotId) =>
                  bloc.add(CameraShotDiscarded(shotId)),
              onSubmit: () => bloc.add(const CameraBatchSubmitted()),
              onOpenUploads: onOpenUploads,
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;
    final HarborTypography text = context.harborText;

    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: const BorderRadius.vertical(top: HarborRadius.sheet),
      ),
      padding: const EdgeInsets.fromLTRB(
        HarborSpacing.md,
        HarborSpacing.sm,
        HarborSpacing.md,
        HarborSpacing.md,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const _Grabber(),
            const SizedBox(height: HarborSpacing.sm),
            Row(
              children: <Widget>[
                Text(
                  'Current batch',
                  style: text.screenTitle.copyWith(color: colors.textPrimary),
                ),
                const Spacer(),
                Text(
                  '${batch.count} · ${Formatters.bytes(batch.totalBytes)}',
                  style: text.numeric.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: HarborSpacing.xxs),
            Text(
              batch.isEmpty
                  ? 'Nothing captured yet. The shutter adds frames here.'
                  : 'Tap a frame to drop it. Nothing here has been handed to '
                      'the sync engine yet.',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: HarborSpacing.md),
            if (batch.isNotEmpty) _ShotGrid(batch: batch, onDiscard: onDiscard),
            const SizedBox(height: HarborSpacing.md),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: onOpenUploads,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.textSecondary,
                      side: BorderSide(color: colors.hairline),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(HarborRadius.button),
                      ),
                    ),
                    child: Text('UPLOAD MANAGER', style: text.button),
                  ),
                ),
                const SizedBox(width: HarborSpacing.sm),
                Expanded(
                  child: FilledButton(
                    onPressed: batch.isEmpty || isSubmitting ? null : onSubmit,
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.primary,
                      disabledBackgroundColor:
                          colors.primary.withValues(alpha: 0.35),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(HarborRadius.button),
                      ),
                    ),
                    child: Text('UPLOAD (${batch.count})', style: text.button),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ShotGrid extends StatelessWidget {
  const _ShotGrid({required this.batch, required this.onDiscard});

  final CaptureBatch batch;
  final ValueChanged<String> onDiscard;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;

    return ConstrainedBox(
      // Bounded so a 40-shot batch scrolls inside the sheet rather than
      // pushing the buttons off the bottom of the screen.
      constraints: const BoxConstraints(maxHeight: 260),
      child: GridView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: HarborSpacing.xs,
          crossAxisSpacing: HarborSpacing.xs,
        ),
        itemCount: batch.count,
        itemBuilder: (BuildContext context, int index) {
          final CapturedShot shot = batch.shots[index];

          return Semantics(
            button: true,
            label: 'Discard frame ${index + 1}',
            child: GestureDetector(
              onTap: () => onDiscard(shot.id),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: const BorderRadius.all(HarborRadius.thumbnail),
                    child: Image.file(
                      File(shot.filePath),
                      fit: BoxFit.cover,
                      // One of these per shot in the batch. Full-resolution
                      // decodes here are what an out-of-memory kill is made
                      // of - see [thumbnailCacheWidth].
                      // Four across, so a tile is never wider than a quarter of the
                      // sheet - a safe upper bound without threading the
                      // grid's geometry down here.
                      cacheWidth: thumbnailCacheWidth(
                        context,
                        MediaQuery.sizeOf(context).width / 4,
                      ),
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: colors.card,
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: colors.textTertiary,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 3,
                    top: 3,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.cameraScrimStrong,
                        shape: BoxShape.circle,
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(3),
                        child: Icon(Icons.close, size: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: context.harborColors.textTertiary,
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}
