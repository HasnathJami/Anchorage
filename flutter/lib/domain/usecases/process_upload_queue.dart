import 'dart:math';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/domain/entities/bandwidth_policy.dart';
import 'package:anchorage_harbor/domain/entities/retry_policy.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/domain/repositories/upload_queue_repository.dart';
import 'package:anchorage_harbor/domain/services/sync_ports.dart';

/// What happened during one sweep of the queue.
///
/// Every task the sweep touched lands in exactly one of these five counters,
/// so `attempted` equals `succeeded + parked + scheduled + failed` for tasks
/// that were actually picked up.
class SyncSweepReport {
  const SyncSweepReport({
    required this.attempted,
    required this.succeeded,
    required this.parkedForConnectivity,
    required this.scheduledForRetry,
    required this.permanentlyFailed,
  });

  /// The "nothing to do" report.
  static const SyncSweepReport idle = SyncSweepReport(
    attempted: 0,
    succeeded: 0,
    parkedForConnectivity: 0,
    scheduledForRetry: 0,
    permanentlyFailed: 0,
  );

  /// How many tasks were claimed and actually uploaded against.
  final int attempted;

  /// How many reached the server.
  final int succeeded;

  /// How many were parked for want of a usable link. **These spent no
  /// attempt.**
  final int parkedForConnectivity;

  /// How many failed for their own reason and will be retried after backoff.
  final int scheduledForRetry;

  /// How many are out of attempts, or failed unrecoverably.
  final int permanentlyFailed;

  /// True when work remains, so the caller can ask the OS to wake it again.
  bool get shouldReschedule => parkedForConnectivity > 0 || scheduledForRetry > 0;

  /// True when the sweep did anything at all.
  bool get didWork => attempted > 0;
}

/// **The resilient sync engine** — the heart of Anchorage Harbor.
///
/// One call to this class is one *sweep* of the queue: read every task that
/// is eligible, and move each one forward as far as the network allows.
///
/// If you read one file to understand the Flutter app, read this one.
///
/// ## The six rules, in order
///
/// **1. Never start without a stable link.** If the link is offline or has
/// not settled, every eligible task is parked in
/// [UploadStatus.waitingForConnection] *without spending an attempt*, and a
/// network-constrained wake-up is requested. This is what makes "no internet"
/// a **pause** rather than five wasted retries.
///
/// **2. One task at a time.** Serial, not parallel. Parallel uploads on a
/// weak link starve each other, the reference UI shows exactly one row
/// transferring at a time, and serial bounds memory on large files.
///
/// **3. Connectivity failures do not consume attempts.** Losing the signal
/// mid-transfer parks the task; only a genuine transport or server error
/// increments the counter and schedules jittered backoff.
///
/// A link that is *up but too slow to be useful* counts as a connectivity
/// failure too — see [BandwidthPolicy]. The operating system will never
/// report that one, so throughput is **measured** as the bytes move and the
/// transfer is abandoned if it stays under the floor.
///
/// **4. Unretryable failures stop immediately.** A missing file or a 400 will
/// never succeed, so the task is failed once and shown to the user rather
/// than looped three times.
///
/// **5. The queue is the source of truth throughout.** Every transition is
/// written before the next task starts, so a process death mid-sweep loses at
/// most the bytes of one in-flight upload — never the queue itself.
///
/// **6. A task is claimed before it is uploaded.** The claim is a conditional
/// `UPDATE`, so of two sweeps racing for the same row exactly one proceeds.
/// The other kind of race — a process killed *holding* a claim — is undone at
/// the top of every sweep by [staleClaimAfter], which returns abandoned rows
/// to the queue. Without **both** halves the queue either uploads a file
/// twice or stalls on it forever.
///
/// ## Why this has no UI dependency at all
///
/// That is what allows the very same code to run from the Bloc *and* from the
/// WorkManager isolate, where no widget tree exists. Two entry points, one
/// implementation of the rules.
///
/// @param repository The durable queue. Every state change goes through it.
/// @param uploader The transport that actually moves bytes.
/// @param connectivity Reports link quality. Consulted before the sweep and
///   again between every file.
/// @param scheduler Asks the OS to wake the app when a network returns.
/// @param retryPolicy Owns the attempt budget and the backoff curve.
/// @param bandwidthPolicy Owns the "too slow to bother" rule.
/// @param clock Injected so tests can control backoff deadlines and lease
///   expiry without waiting.
/// @param random Injected so the jitter is deterministic under test.
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
  /// abandoned and returned to the queue.
  ///
  /// Generously long, on purpose. The cost of reaping too early is a
  /// duplicate upload; the cost of reaping too late is a photograph that
  /// waits one extra sweep. Ten minutes is comfortably longer than any single
  /// file this app produces takes on a usable link, and
  /// [UploadQueueRepository.updateProgress] renews the lease anyway — so only
  /// a transfer that has genuinely stopped moving expires.
  final Duration staleClaimAfter;

  /// Guards against a manual "sync now" racing the periodic worker *within
  /// this isolate*.
  ///
  /// It cannot see the WorkManager isolate, which has its own object graph —
  /// that race is handled by the database claim instead (rule 6).
  bool _inFlight = false;

  /// Runs one sweep of the queue.
  ///
  /// Safe to call from anywhere, at any time: re-entrant calls return
  /// [SyncSweepReport.idle] rather than starting a second sweep.
  Future<Result<SyncSweepReport>> call() async {
    if (_inFlight) return const Result<SyncSweepReport>.success(SyncSweepReport.idle);
    _inFlight = true;

    try {
      // Step 1 - the reaper. Rescue rows a previous process died holding.
      //
      // They are `uploading`, which is not an eligible state, so without this
      // they would never be read again and the photograph would be stranded
      // forever. This is the second half of rule 6.
      await _repository.requeueStalled(_clock().subtract(staleClaimAfter));

      // Step 2 - what is there to do?
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

  /// The sweep proper. See the class docs for the six rules it enforces.
  ///
  /// @param tasks Every task eligible for pickup, oldest first.
  Future<Result<SyncSweepReport>> _sweep(List<UploadTask> tasks) async {
    if (tasks.isEmpty) {
      return const Result<SyncSweepReport>.success(SyncSweepReport.idle);
    }

    final LinkStatus link = await _connectivity.current();

    // ── RULE 1 ──────────────────────────────────────────────────────────
    // No stable link means nothing is attempted at all. Park everything and
    // ask the OS to wake us when a network appears. No attempts are spent.
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

    // ── RULE 2: one at a time ───────────────────────────────────────────
    for (final UploadTask task in tasks) {
      // Re-check between files: a link can vanish mid-batch, and continuing
      // would burn an attempt on every remaining task.
      final LinkStatus latest = await _connectivity.current();
      if (!latest.quality.canTransfer) {
        await _repository.parkForConnectivity(task.id, UploadFailureKind.noConnection);
        parked++;
        continue;
      }

      // ── RULE 6: claim before transferring ─────────────────────────────
      // A `false` here means another sweep - very likely the WorkManager
      // isolate, which has its own object graph and cannot see this one's
      // in-flight guard - already owns this row.
      final Result<bool> claim = await _repository.claim(task.id, _clock());
      if (claim.valueOrNull != true) continue;

      attempted++;

      // ── The bandwidth watchdog ────────────────────────────────────────
      //
      // Held here rather than in the transport, for two reasons: the rule
      // then applies to *every* transport, and the decision stays in the
      // domain alongside the rest of the sync policy.
      //
      // `slowSince` is when throughput first dropped under the floor, or null
      // if it is currently fine. `collapsed` latches once we have given up.
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
        // Success. Note this branch is also reached when the cancellation
        // above lost a race with the last chunk - a delivered file is
        // delivered, whatever we were trying to do about it.
        await _repository.markSynced(task.id, _clock());
        succeeded++;
        continue;
      }

      // ── RULE 3a: the half the OS cannot tell us about ─────────────────
      // The link is up, and too slow to be worth an attempt.
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

      // ── RULE 3b: the network going away is not the task's fault ───────
      if (failure.isConnectivityRelated) {
        await _repository.parkForConnectivity(task.id, _kindOf(failure));
        parked++;
        await _scheduler.requestSyncWhenConnected(reason: 'lost link mid-batch');
        continue;
      }

      // Everything below here *is* the task's own fault, so it costs an
      // attempt.
      final int nextAttempt = task.attempt + 1;

      // ── RULE 4: some failures are final on the first try ──────────────
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

      // Retryable, and budget remains: schedule it with jittered backoff.
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

    // Anything parked or backing off needs the OS to wake us again later.
    if (report.shouldReschedule) {
      await _scheduler.requestSyncWhenConnected(reason: 'work remaining');
    }

    return Result<SyncSweepReport>.success(report);
  }

  /// Collapses the rich [Failure] into the small enum SQLite can store.
  ///
  /// The detail is deliberately dropped: what the UI and the retry policy
  /// need is the *kind*, and a three-day-old stack trace helps nobody.
  UploadFailureKind _kindOf(Failure failure) => switch (failure) {
        NoConnectionFailure() => UploadFailureKind.noConnection,
        LowBandwidthFailure() => UploadFailureKind.lowBandwidth,
        TimeoutFailure() => UploadFailureKind.timeout,
        ServerFailure() => UploadFailureKind.server,
        MissingArtifactFailure() => UploadFailureKind.missingFile,
        _ => UploadFailureKind.unknown,
      };
}
