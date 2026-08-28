import 'dart:io';

import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/core/utils/formatters.dart';
import 'package:anchorage_harbor/domain/entities/batch_progress.dart';
import 'package:anchorage_harbor/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:flutter/material.dart';

/// The "STABLE LINK" chip.
///
/// Three states, not two. "Connected" and "usable" are different things on a
/// mobile device, and the whole retry engine turns on the difference - so the
/// chip tells the truth about which one is currently the case.
class LinkBadge extends StatelessWidget {
  const LinkBadge({required this.quality, super.key});

  final LinkQuality quality;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;

    final (String label, Color color) = switch (quality) {
      LinkQuality.stable => ('STABLE LINK', colors.success),
      LinkQuality.unstable => ('WEAK LINK', colors.caution),
      LinkQuality.offline => ('NO LINK', colors.danger),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: const BorderRadius.all(HarborRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(label, style: context.harborText.eyebrow.copyWith(color: color)),
        ],
      ),
    );
  }
}

/// The aggregate header: percentage, bar, byte counts and the pause control.
class BatchProgressHeader extends StatelessWidget {
  const BatchProgressHeader({
    required this.progress,
    required this.isPaused,
    required this.onTogglePause,
    super.key,
  });

  final BatchProgress progress;
  final bool isPaused;
  final VoidCallback onTogglePause;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;
    final HarborTypography text = context.harborText;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        HarborSpacing.md,
        HarborSpacing.sm,
        HarborSpacing.md,
        HarborSpacing.md,
      ),
      color: colors.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                'BATCH SYNC PROGRESS',
                style: text.eyebrow.copyWith(color: colors.textSecondary),
              ),
              const Spacer(),
              Text(
                '${progress.percent}%',
                style: text.numeric.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: HarborSpacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress.fraction,
              minHeight: 6,
              backgroundColor: colors.textTertiary.withValues(alpha: 0.35),
              valueColor: AlwaysStoppedAnimation<Color>(colors.primaryBright),
            ),
          ),
          const SizedBox(height: HarborSpacing.xs),
          Row(
            children: <Widget>[
              Text(
                Formatters.transferred(progress.uploadedBytes, progress.totalBytes),
                style: text.itemMeta.copyWith(color: colors.textTertiary),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onTogglePause,
                behavior: HitTestBehavior.opaque,
                child: Text(
                  isPaused ? 'RESUME ALL' : 'PAUSE ALL',
                  style: text.eyebrow.copyWith(color: colors.primaryBright),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One row of the queue.
///
/// The active row is visually promoted - lifted surface, blue hairline, an
/// inline progress bar and a throughput read-out - exactly as in the reference.
/// That promotion is the screen's only motion, which is what makes "something
/// is happening right now" readable at a glance.
class UploadTaskTile extends StatelessWidget {
  const UploadTaskTile({
    required this.task,
    required this.onRetry,
    required this.onDiscard,
    super.key,
  });

  final UploadTask task;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;
    final HarborTypography text = context.harborText;
    final bool isActive = task.status.isActive;

    return Container(
      margin: const EdgeInsets.only(bottom: HarborSpacing.sm),
      padding: const EdgeInsets.all(HarborSpacing.sm),
      decoration: BoxDecoration(
        color: isActive ? colors.cardActive : colors.card,
        borderRadius: const BorderRadius.all(HarborRadius.card),
        border: Border.all(
          color: isActive ? colors.primary.withValues(alpha: 0.55) : colors.hairline,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Thumbnail(task: task),
          const SizedBox(width: HarborSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        Formatters.fileName(task.displayName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.itemTitle.copyWith(color: colors.textPrimary),
                      ),
                    ),
                    if (isActive && (task.throughputBytesPerSecond ?? 0) > 0)
                      Text(
                        Formatters.throughput(task.throughputBytesPerSecond!),
                        style: text.numeric.copyWith(color: colors.primaryBright),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  Formatters.bytes(task.sizeBytes),
                  style: text.itemMeta.copyWith(color: colors.textTertiary),
                ),
                if (isActive) ...<Widget>[
                  const SizedBox(height: HarborSpacing.xs),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: task.progress,
                      minHeight: 4,
                      backgroundColor: colors.textTertiary.withValues(alpha: 0.3),
                      valueColor:
                          AlwaysStoppedAnimation<Color>(colors.primaryBright),
                    ),
                  ),
                ],
                const SizedBox(height: HarborSpacing.xxs),
                _StatusLine(task: task),
              ],
            ),
          ),
          _TrailingAction(task: task, onRetry: onRetry, onDiscard: onDiscard),
        ],
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.task});

  final UploadTask task;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;

    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        color: colors.hairline,
        borderRadius: const BorderRadius.all(HarborRadius.thumbnail),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.file(
        File(task.filePath),
        fit: BoxFit.cover,
        // The file can legitimately be gone (the OS cleared it, the user wiped
        // storage). A placeholder is correct here; the engine reports the same
        // condition as a terminal `MissingArtifactFailure`.
        errorBuilder: (_, _, _) => Icon(
          Icons.insert_drive_file_outlined,
          size: 22,
          color: colors.textTertiary,
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.task});

  final UploadTask task;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;
    final HarborTypography text = context.harborText;

    final (String label, Color color, IconData? icon) = switch (task.status) {
      UploadStatus.queued => ('IN QUEUE', colors.textTertiary, null),
      UploadStatus.waitingForConnection => (
          'WAITING FOR CONNECTION',
          colors.caution,
          null,
        ),
      UploadStatus.uploading => (
          'UPLOADING - ${(task.progress * 100).round()}%',
          colors.primaryBright,
          null,
        ),
      UploadStatus.retrying => (
          'RETRYING... (ATTEMPT ${Formatters.attempts(task.attempt, task.maxAttempts)})',
          colors.danger,
          null,
        ),
      UploadStatus.synced => ('SYNCED', colors.success, Icons.check_circle),
      UploadStatus.failed => (
          _failedLabel(task.lastFailureKind),
          colors.danger,
          Icons.error_outline,
        ),
      UploadStatus.paused => ('PAUSED', colors.textSecondary, Icons.pause_circle_outline),
    };

    return Row(
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.itemStatus.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  String _failedLabel(UploadFailureKind kind) => switch (kind) {
        UploadFailureKind.missingFile => 'FILE NO LONGER ON DEVICE',
        UploadFailureKind.server => 'REJECTED BY SERVER',
        UploadFailureKind.timeout => 'TIMED OUT',
        _ => 'FAILED',
      };
}

class _TrailingAction extends StatelessWidget {
  const _TrailingAction({
    required this.task,
    required this.onRetry,
    required this.onDiscard,
  });

  final UploadTask task;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;

    if (task.status == UploadStatus.failed) {
      return Row(
        children: <Widget>[
          IconButton(
            onPressed: onRetry,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.refresh, size: 18, color: colors.primaryBright),
            tooltip: 'Retry',
          ),
          IconButton(
            onPressed: onDiscard,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.delete_outline, size: 18, color: colors.textTertiary),
            tooltip: 'Discard',
          ),
        ],
      );
    }

    return const SizedBox(width: HarborSpacing.xxs);
  }
}

/// Shown when the queue is empty - the state a well-behaved sync engine spends
/// most of its life in, so it deserves more than a blank rectangle.
class EmptyQueueView extends StatelessWidget {
  const EmptyQueueView({required this.onCapture, super.key});

  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.cloud_done_outlined, size: 44, color: colors.success),
            const SizedBox(height: HarborSpacing.md),
            Text(
              'Everything is ashore',
              style: context.harborText.screenTitle.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: HarborSpacing.xs),
            Text(
              'Nothing is waiting to upload. Captured batches appear here and '
              'sync themselves as soon as the link is stable.',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary, fontSize: 13, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
