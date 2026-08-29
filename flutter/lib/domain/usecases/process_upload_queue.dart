import 'dart:math';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/domain/entities/bandwidth_policy.dart';
import 'package:anchorage_harbor/domain/entities/retry_policy.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/domain/repositories/upload_queue_repository.dart';
import 'package:anchorage_harbor/domain/services/sync_ports.dart';

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
///     increments the attempt counter and schedules jittered backoff. A link
///     that is *up but too slow to be useful* counts as a connectivity failure
///     too — see [BandwidthPolicy]. The operating system will not report that
///     one, so throughput is measured as the bytes move and the transfer is
///     abandoned if it stays under the floor.
///  4. **Unretryable failures stop immediately.** A missing file or a 400 will
///     never succeed, so the task is failed once and shown to the user rather
///     than looped five times.
///  5. **The queue is the source of truth throughout.** Every transition is
///     written before the next task starts, so a process death mid-sweep loses
///     at most the bytes of one in-flight upload - never the queue itself.
///  6. **A task is claimed before it is uploaded.** The claim is a conditional
///     UPDATE, so of two sweeps racing for the same row exactly one proceeds.
///     The other kind of race - a process killed *holding* a claim - is undone
///     at the top of every sweep by [staleClaimAfter], which returns abandoned
///     rows to the queue. Without both halves the queue either uploads a file
///     twice or stalls on it forever.
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
    BandwidthPolicy bandwidthPolicy = BandwidthPolicy.standard,
    DateTime Function() clock = DateTime.now,
    this.staleClaimAfter = const Duration(minutes: 10),
    Random? random,
  })  : _repository = repository,
        _uploader = uploader,
        _connectivity = connectivity,
        _scheduler = scheduler,
        _retryPolicy = retryPolicy,
        _bandwidth = bandwidthPolicy,
        _clock = clock,
        _random = random ?? Random();

  final UploadQueueRepository _repository;
  final UploaderPort _uploader;
  final ConnectivityPort _connectivity;
  final BackgroundSchedulerPort _scheduler;
  final RetryPolicy _retryPolicy;
  final BandwidthPolicy _bandwidth;
  final DateTime Function() _clock;
  final Random _random;

  /// How long a claim may go without progress before the row is treated as
  /// abandoned.
  ///
  /// Generously long. The cost of reaping too early is a duplicate upload; the
  /// cost of reaping too late is a photograph that waits one extra sweep. Ten
  /// minutes is comfortably longer than any single file this app produces takes
  /// on a usable link, and [UploadQueueRepository.updateProgress] renews the
  /// lease anyway, so only a transfer that has genuinely stopped moving expires.
  final Duration staleClaimAfter;

  /// Guards against a manual "sync now" racing the periodic worker. Without
  /// it the same file could be uploaded twice concurrently.
  bool _inFlight = false;

  Future<Result<SyncSweepReport>> call() async {
    if (_inFlight) return const Result<SyncSweepReport>.success(SyncSweepReport.idle);
    _inFlight = true;

    try {
      // Before anything else: rescue rows a previous process died holding.
      // They are `uploading`, which is not an eligible state, so without this
      // they would never be read again and the photograph would be stranded.
      await _repository.requeueStalled(_clock().subtract(staleClaimAfter));

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

      // Claim before transferring. A `false` here means another sweep - very
      // likely the WorkManager isolate, which has its own object graph and
      // cannot see this one's in-flight guard - already owns this row.
      final Result<bool> claim = await _repository.claim(task.id, _clock());
      if (claim.valueOrNull != true) continue;

      attempted++;

      // The bandwidth watchdog. Held here rather than in the transport so the
      // rule applies to *every* transport, and so the decision stays in the
      // domain where the rest of the sync policy lives.
      DateTime? slowSince;
      bool collapsed = false;

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

          if (collapsed) return;

          if (!_bandwidth.isTooSlow(progress.throughputBytesPerSecond)) {
            // Recovered. The grace window measures a *continuous* slow spell,
            // so one good tick clears it - a link that dips and comes back is
            // not a link that has failed.
            slowSince = null;
            return;
          }

          final DateTime now = _clock();
          slowSince ??= now;

          if (_bandwidth.shouldPark(
            observedBytesPerSecond: progress.throughputBytesPerSecond,
            slowFor: now.difference(slowSince!),
          )) {
            collapsed = true;
            // Stop pushing bytes down a pipe that cannot carry them. The
            // transport answers the cancellation however it likes; the park
            // below does not depend on which failure comes back.
            _uploader.cancel(task.id);
          }
        },
      );

      final Failure? failure = result.failureOrNull;

      if (failure == null) {
        // The cancellation lost a race with the last chunk. A delivered file
        // is delivered.
        await _repository.markSynced(task.id, _clock());
        succeeded++;
        continue;
      }

      // Rule 3, the half the operating system cannot tell us about: the link
      // is up, and too slow to be worth an attempt.
      if (collapsed) {
        await _repository.parkForConnectivity(
          task.id,
          UploadFailureKind.lowBandwidth,
        );
        parked++;
        await _scheduler.requestSyncWhenConnected(
          reason: 'throughput collapsed mid-transfer',
        );
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
