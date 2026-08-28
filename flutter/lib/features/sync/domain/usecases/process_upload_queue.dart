import 'dart:math';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/features/sync/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/features/sync/domain/entities/retry_policy.dart';
import 'package:anchorage_harbor/features/sync/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/features/sync/domain/repositories/upload_queue_repository.dart';
import 'package:anchorage_harbor/features/sync/domain/services/sync_ports.dart';

/// Outcome of one sweep of the queue.
class SyncSweepReport {
  const SyncSweepReport({
    required this.attempted,
    required this.succeeded,
    required this.parkedForConnectivity,
    required this.scheduledForRetry,
    required this.permanentlyFailed,
  });

  static const SyncSweepReport idle = SyncSweepReport(
    attempted: 0,
    succeeded: 0,
    parkedForConnectivity: 0,
    scheduledForRetry: 0,
    permanentlyFailed: 0,
  );

  final int attempted;
  final int succeeded;
  final int parkedForConnectivity;
  final int scheduledForRetry;
  final int permanentlyFailed;

  /// True when work remains, so the caller can ask the OS to wake it again.
  bool get shouldReschedule => parkedForConnectivity > 0 || scheduledForRetry > 0;

  bool get didWork => attempted > 0;
}

/// **The resilient sync engine.**
///
/// One sweep of the queue, obeying these rules in order:
///
///  1. **Never start without a stable link.** If the link is offline or has
///     not settled, every eligible task is parked in
///     [UploadStatus.waitingForConnection] *without spending an attempt*, and
///     a network-constrained wake-up is requested. This is what makes "no
///     internet" a pause rather than five wasted retries.
///  2. **One task at a time.** Serial, not parallel: parallel uploads on a
///     weak link starve each other, and the reference UI shows exactly one row
///     transferring at a time. It also bounds memory on large files.
///  3. **Connectivity failures do not consume attempts.** Losing the signal
///     mid-transfer parks the task; only a genuine transport or server error
///     increments the attempt counter and schedules jittered backoff.
///  4. **Unretryable failures stop immediately.** A missing file or a 400 will
///     never succeed, so the task is failed once and shown to the user rather
///     than looped five times.
///  5. **The queue is the source of truth throughout.** Every transition is
///     written before the next task starts, so a process death mid-sweep loses
///     at most the bytes of one in-flight upload - never the queue itself.
///
/// The use case takes no UI dependency at all, which is what allows the very
/// same code to run from the ViewModel-facing Bloc *and* from the WorkManager
/// isolate, where no widget tree exists.
class ProcessUploadQueue {
  ProcessUploadQueue({
    required UploadQueueRepository repository,
    required UploaderPort uploader,
    required ConnectivityPort connectivity,
    required BackgroundSchedulerPort scheduler,
    RetryPolicy retryPolicy = const RetryPolicy(),
    DateTime Function() clock = DateTime.now,
    Random? random,
  })  : _repository = repository,
        _uploader = uploader,
        _connectivity = connectivity,
        _scheduler = scheduler,
        _retryPolicy = retryPolicy,
        _clock = clock,
        _random = random ?? Random();

  final UploadQueueRepository _repository;
  final UploaderPort _uploader;
  final ConnectivityPort _connectivity;
  final BackgroundSchedulerPort _scheduler;
  final RetryPolicy _retryPolicy;
  final DateTime Function() _clock;
  final Random _random;

  /// Guards against a manual "sync now" racing the periodic worker. Without
  /// it the same file could be uploaded twice concurrently.
  bool _inFlight = false;

  Future<Result<SyncSweepReport>> call() async {
    if (_inFlight) return const Result<SyncSweepReport>.success(SyncSweepReport.idle);
    _inFlight = true;

    try {
      final Result<List<UploadTask>> eligible =
          await _repository.readEligible(_clock());

      return await eligible.fold(
        (List<UploadTask> tasks) => _sweep(tasks),
        (Failure failure) async => Result<SyncSweepReport>.failure(failure),
      );
    } finally {
      _inFlight = false;
    }
  }

  Future<Result<SyncSweepReport>> _sweep(List<UploadTask> tasks) async {
    if (tasks.isEmpty) {
      return const Result<SyncSweepReport>.success(SyncSweepReport.idle);
    }

    final LinkStatus link = await _connectivity.current();

    // Rule 1: no stable link means nothing is attempted at all.
    if (!link.quality.canTransfer) {
      for (final UploadTask task in tasks) {
        await _repository.parkForConnectivity(
          task.id,
          link.quality == LinkQuality.offline
              ? UploadFailureKind.noConnection
              : UploadFailureKind.lowBandwidth,
        );
      }
      await _scheduler.requestSyncWhenConnected(reason: 'link ${link.quality.name}');

      return Result<SyncSweepReport>.success(
        SyncSweepReport(
          attempted: 0,
          succeeded: 0,
          parkedForConnectivity: tasks.length,
          scheduledForRetry: 0,
          permanentlyFailed: 0,
        ),
      );
    }

    int attempted = 0;
    int succeeded = 0;
    int parked = 0;
    int scheduled = 0;
    int failed = 0;

    for (final UploadTask task in tasks) {
      // Re-check between files: a link can vanish mid-batch, and continuing
      // would burn an attempt on every remaining task.
      final LinkStatus latest = await _connectivity.current();
      if (!latest.quality.canTransfer) {
        await _repository.parkForConnectivity(task.id, UploadFailureKind.noConnection);
        parked++;
        continue;
      }

      attempted++;
      await _repository.updateStatus(task.id, UploadStatus.uploading);

      final Result<void> result = await _uploader.upload(
        task,
        onProgress: (UploadProgress progress) {
          // Fire-and-forget: a dropped progress write is cosmetic, and
          // awaiting it would throttle the transfer to the disk's speed.
          _repository.updateProgress(
            task.id,
            bytesTransferred: progress.bytesTransferred,
            throughputBytesPerSecond: progress.throughputBytesPerSecond,
          );
        },
      );

      final Failure? failure = result.failureOrNull;

      if (failure == null) {
        await _repository.markSynced(task.id, _clock());
        succeeded++;
        continue;
      }

      // Rule 3: the network going away is not the task's fault.
      if (failure.isConnectivityRelated) {
        await _repository.parkForConnectivity(task.id, _kindOf(failure));
        parked++;
        await _scheduler.requestSyncWhenConnected(reason: 'lost link mid-batch');
        continue;
      }

      final int nextAttempt = task.attempt + 1;

      // Rule 4: some failures are final on the first try.
      if (!failure.isRetryable || !_retryPolicy.hasAttemptsLeft(nextAttempt)) {
        await _repository.markAttemptFailed(
          task.id,
          attempt: nextAttempt,
          status: UploadStatus.failed,
          failureKind: _kindOf(failure),
        );
        failed++;
        continue;
      }

      await _repository.markAttemptFailed(
        task.id,
        attempt: nextAttempt,
        status: UploadStatus.retrying,
        failureKind: _kindOf(failure),
        nextAttemptAt: _clock().add(
          _retryPolicy.delayForAttempt(nextAttempt, random: _random),
        ),
      );
      scheduled++;
    }

    final SyncSweepReport report = SyncSweepReport(
      attempted: attempted,
      succeeded: succeeded,
      parkedForConnectivity: parked,
      scheduledForRetry: scheduled,
      permanentlyFailed: failed,
    );

    if (report.shouldReschedule) {
      await _scheduler.requestSyncWhenConnected(reason: 'work remaining');
    }

    return Result<SyncSweepReport>.success(report);
  }

  UploadFailureKind _kindOf(Failure failure) => switch (failure) {
        NoConnectionFailure() => UploadFailureKind.noConnection,
        LowBandwidthFailure() => UploadFailureKind.lowBandwidth,
        TimeoutFailure() => UploadFailureKind.timeout,
        ServerFailure() => UploadFailureKind.server,
        MissingArtifactFailure() => UploadFailureKind.missingFile,
        _ => UploadFailureKind.unknown,
      };
}
