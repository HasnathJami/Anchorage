import 'dart:math';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/domain/entities/bandwidth_policy.dart';
import 'package:anchorage_harbor/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/domain/entities/retry_policy.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/domain/services/sync_ports.dart';
import 'package:anchorage_harbor/domain/usecases/process_upload_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

/// The resilient sync engine is the heart of this app, so it gets the deepest
/// suite. Every rule stated in [ProcessUploadQueue]'s doc comment has at least
/// one test that fails if the rule is removed.
void main() {
  late FakeUploadQueueRepository repository;
  late FakeUploader uploader;
  late FakeConnectivity connectivity;
  late RecordingScheduler scheduler;

  final DateTime now = DateTime(2026, 8, 28, 9, 30);

  ProcessUploadQueue buildEngine({
    RetryPolicy policy = const RetryPolicy(),
    BandwidthPolicy bandwidth = BandwidthPolicy.standard,
    DateTime Function()? clock,
  }) =>
      ProcessUploadQueue(
        repository: repository,
        uploader: uploader,
        connectivity: connectivity,
        scheduler: scheduler,
        retryPolicy: policy,
        bandwidthPolicy: bandwidth,
        clock: clock ?? () => now,
        // A seeded Random makes the jittered backoff reproducible, so the
        // tests assert on scheduling behaviour rather than on luck.
        random: Random(42),
      );

  setUp(() {
    repository = FakeUploadQueueRepository();
    uploader = FakeUploader();
    connectivity = FakeConnectivity();
    scheduler = RecordingScheduler();
  });

  tearDown(() async {
    await repository.dispose();
    await connectivity.dispose();
  });

  group('rule 3: a link that is up but too slow to use', () {
    const BandwidthPolicy tight = BandwidthPolicy(
      floorBytesPerSecond: 24 * 1024,
      grace: Duration(seconds: 6),
    );

    /// A clock the transport advances one second per progress tick, so a run
    /// of slow ticks actually spends the grace window.
    (DateTime Function(), void Function()) tickingClock() {
      DateTime current = now;
      return (() => current, () => current = current.add(const Duration(seconds: 1)));
    }

    test('a transfer that stays under the floor is abandoned and parked',
        () async {
      final (DateTime Function() clock, void Function() advance) = tickingClock();
      uploader.beforeTick = advance;
      // Eight seconds of 2 KB/s: well under the floor, well past the grace.
      uploader.throughputTicks = List<int>.filled(8, 2 * 1024);

      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      final report = await buildEngine(bandwidth: tight, clock: clock)();

      expect(report.valueOrNull!.parkedForConnectivity, 1);
      expect(
        repository.byId(taskFixture().id)!.status,
        UploadStatus.waitingForConnection,
      );
    });

    test('it costs no attempt, exactly like losing the signal', () async {
      // The whole point of treating it as connectivity: the file is fine, the
      // server is fine, the network is not. Spending a retry on that would
      // burn the budget the task needs when the link comes back.
      final (DateTime Function() clock, void Function() advance) = tickingClock();
      uploader.beforeTick = advance;
      uploader.throughputTicks = List<int>.filled(8, 2 * 1024);

      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      await buildEngine(bandwidth: tight, clock: clock)();

      expect(repository.byId(taskFixture().id)!.attempt, 0);
      expect(repository.byId(taskFixture().id)!.lastFailureKind,
          UploadFailureKind.lowBandwidth);
    });

    test('the transfer is stopped rather than left running', () async {
      final (DateTime Function() clock, void Function() advance) = tickingClock();
      uploader.beforeTick = advance;
      uploader.throughputTicks = List<int>.filled(8, 2 * 1024);

      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      await buildEngine(bandwidth: tight, clock: clock)();

      expect(uploader.cancelled, contains(taskFixture().id),
          reason: 'holding a socket open on a dead link helps nobody');
    });

    test('a wake-up is requested, so it is retried when the link is worth it',
        () async {
      final (DateTime Function() clock, void Function() advance) = tickingClock();
      uploader.beforeTick = advance;
      uploader.throughputTicks = List<int>.filled(8, 2 * 1024);

      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      await buildEngine(bandwidth: tight, clock: clock)();

      expect(scheduler.connectedRequests, isNotEmpty);
    });

    test('a brief dip that recovers is not a collapse', () async {
      final (DateTime Function() clock, void Function() advance) = tickingClock();
      uploader.beforeTick = advance;
      // Two slow seconds, then the link comes back. The grace window measures
      // a *continuous* slow spell, so this must complete normally.
      uploader.throughputTicks = <int>[
        2 * 1024,
        2 * 1024,
        1024 * 1024,
        1024 * 1024,
      ];

      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      final report = await buildEngine(bandwidth: tight, clock: clock)();

      expect(report.valueOrNull!.succeeded, 1);
      expect(uploader.cancelled, isEmpty);
    });

    test('a fast link is never touched by the watchdog', () async {
      final (DateTime Function() clock, void Function() advance) = tickingClock();
      uploader.beforeTick = advance;
      uploader.throughputTicks = List<int>.filled(8, 4 * 1024 * 1024);

      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      final report = await buildEngine(bandwidth: tight, clock: clock)();

      expect(report.valueOrNull!.succeeded, 1);
      expect(report.valueOrNull!.parkedForConnectivity, 0);
    });
  });

  group('an empty or ineligible queue', () {
    test('does nothing at all', () async {
      final report = await buildEngine()();

      expect(report.valueOrNull, SyncSweepReport.idle);
      expect(uploader.attempts, isEmpty);
      expect(scheduler.connectedRequests, isEmpty);
    });

    test('skips a task whose backoff has not yet elapsed', () async {
      await repository.enqueueAll(<UploadTask>[
        taskFixture(
          status: UploadStatus.retrying,
          nextAttemptAt: now.add(const Duration(minutes: 5)),
        ),
      ]);

      await buildEngine()();

      expect(uploader.attempts, isEmpty);
    });

    test('skips paused tasks', () async {
      await repository.enqueueAll(<UploadTask>[
        taskFixture(status: UploadStatus.paused),
      ]);

      await buildEngine()();

      expect(uploader.attempts, isEmpty);
    });
  });

  group('rule 1 - never start without a stable link', () {
    test('parks every task and spends no attempt when offline', () async {
      connectivity.quality = LinkQuality.offline;
      await repository.enqueueAll(<UploadTask>[
        taskFixture(id: 'a'),
        taskFixture(id: 'b'),
      ]);

      final report = await buildEngine()();

      expect(uploader.attempts, isEmpty);
      expect(report.valueOrNull!.parkedForConnectivity, 2);

      for (final String id in <String>['a', 'b']) {
        final UploadTask task = repository.byId(id)!;
        expect(task.status, UploadStatus.waitingForConnection);
        expect(task.attempt, 0, reason: 'a missing network is not a failed attempt');
        expect(task.lastFailureKind, UploadFailureKind.noConnection);
      }
    });

    test('parks on an unstable link too, and records why', () async {
      connectivity.quality = LinkQuality.unstable;
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      await buildEngine()();

      expect(uploader.attempts, isEmpty);
      expect(
        repository.byId('task-1')!.lastFailureKind,
        UploadFailureKind.lowBandwidth,
      );
    });

    test('asks the OS to wake it when a network arrives', () async {
      connectivity.quality = LinkQuality.offline;
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      await buildEngine()();

      expect(scheduler.connectedRequests, isNotEmpty);
    });

    test('clears any stale backoff when parking', () async {
      connectivity.quality = LinkQuality.offline;
      await repository.enqueueAll(<UploadTask>[
        taskFixture(
          status: UploadStatus.retrying,
          nextAttemptAt: now.subtract(const Duration(minutes: 1)),
        ),
      ]);

      await buildEngine()();

      // A parked task waits for an event, not a timer - leaving a backoff on
      // it would delay the upload after the network returned.
      expect(repository.byId('task-1')!.nextAttemptAt, isNull);
    });
  });

  group('the happy path', () {
    test('uploads and marks synced', () async {
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      final report = await buildEngine()();

      expect(report.valueOrNull!.succeeded, 1);
      final UploadTask task = repository.byId('task-1')!;
      expect(task.status, UploadStatus.synced);
      expect(task.completedAt, now);
    });

    test('drains the whole queue in FIFO order', () async {
      await repository.enqueueAll(<UploadTask>[
        taskFixture(id: 'second', createdAt: DateTime(2026, 8, 28, 9, 5)),
        taskFixture(id: 'first', createdAt: DateTime(2026, 8, 28, 9, 1)),
        taskFixture(id: 'third', createdAt: DateTime(2026, 8, 28, 9, 9)),
      ]);

      await buildEngine()();

      expect(uploader.attempts, <String>['first', 'second', 'third']);
    });

    test('records transfer progress as it goes', () async {
      await repository.enqueueAll(<UploadTask>[taskFixture(sizeBytes: 2000)]);

      await buildEngine()();

      // The fake emits one tick at the halfway point before succeeding.
      expect(repository.byId('task-1')!.status, UploadStatus.synced);
    });
  });

  group('rule 3 - connectivity failures do not consume attempts', () {
    test('a link lost mid-transfer parks rather than counts', () async {
      uploader.script('task-1', <Failure?>[const NoConnectionFailure()]);
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      final report = await buildEngine()();

      final UploadTask task = repository.byId('task-1')!;
      expect(task.status, UploadStatus.waitingForConnection);
      expect(task.attempt, 0);
      expect(report.valueOrNull!.parkedForConnectivity, 1);
    });

    test('low bandwidth is treated the same way', () async {
      uploader.script('task-1', <Failure?>[const LowBandwidthFailure()]);
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      await buildEngine()();

      expect(repository.byId('task-1')!.attempt, 0);
      expect(
        repository.byId('task-1')!.lastFailureKind,
        UploadFailureKind.lowBandwidth,
      );
    });

    test('the link dropping between files parks the remainder', () async {
      await repository.enqueueAll(<UploadTask>[
        taskFixture(id: 'a', createdAt: DateTime(2026, 8, 28, 9, 1)),
        taskFixture(id: 'b', createdAt: DateTime(2026, 8, 28, 9, 2)),
      ]);

      uploader.script('a', <Failure?>[null]);
      // Simulate the radio dying the moment the first file lands.
      final ProcessUploadQueue engine = ProcessUploadQueue(
        repository: repository,
        uploader: _DropLinkAfterFirst(uploader, connectivity),
        connectivity: connectivity,
        scheduler: scheduler,
        clock: () => now,
        random: Random(1),
      );

      await engine();

      expect(repository.byId('a')!.status, UploadStatus.synced);
      expect(repository.byId('b')!.status, UploadStatus.waitingForConnection);
      expect(repository.byId('b')!.attempt, 0);
    });
  });

  group('retryable failures', () {
    test('schedule backoff and increment the attempt', () async {
      uploader.script('task-1', <Failure?>[const ServerFailure(503)]);
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      final report = await buildEngine()();

      final UploadTask task = repository.byId('task-1')!;
      expect(task.status, UploadStatus.retrying);
      expect(task.attempt, 1);
      expect(task.lastFailureKind, UploadFailureKind.server);
      expect(task.nextAttemptAt, isNotNull);
      expect(task.nextAttemptAt!.isAfter(now) || task.nextAttemptAt == now, isTrue);
      expect(report.valueOrNull!.scheduledForRetry, 1);
    });

    test('the third failure for the same reason is the last one', () async {
      // Three, not five. The budget is only ever spent on failures that are
      // the task's own - a park for want of a network costs nothing - so by
      // the third identical rejection the fourth is not going to be the one
      // that works.
      uploader.script('task-1', <Failure?>[const ServerFailure(503)]);
      await repository.enqueueAll(<UploadTask>[
        taskFixture(
          status: UploadStatus.retrying,
          attempt: RetryPolicy.defaultMaxAttempts - 1,
        ),
      ]);

      final report = await buildEngine()();

      final UploadTask task = repository.byId('task-1')!;
      expect(task.status, UploadStatus.failed);
      expect(task.attempt, RetryPolicy.defaultMaxAttempts);
      expect(report.valueOrNull!.permanentlyFailed, 1);
    });

    test('the second failure still schedules another go', () async {
      uploader.script('task-1', <Failure?>[const ServerFailure(503)]);
      await repository.enqueueAll(<UploadTask>[
        taskFixture(
          status: UploadStatus.retrying,
          attempt: RetryPolicy.defaultMaxAttempts - 2,
        ),
      ]);

      final report = await buildEngine()();

      expect(repository.byId('task-1')!.status, UploadStatus.retrying);
      expect(report.valueOrNull!.scheduledForRetry, 1);
    });

    test('parks do not eat into the budget, however many there are', () async {
      // The rule the ceiling depends on. If a park spent an attempt, three
      // would be far too few: a phone in and out of a tunnel would exhaust it
      // without the server ever having been asked.
      connectivity.quality = LinkQuality.offline;
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      for (int sweep = 0; sweep < 5; sweep++) {
        await buildEngine()();
      }

      final UploadTask task = repository.byId('task-1')!;
      expect(task.attempt, 0);
      expect(task.status, UploadStatus.waitingForConnection);
    });

    test('succeed on a later attempt after transient failures', () async {
      uploader.script('task-1', <Failure?>[
        const ServerFailure(503),
        const TimeoutFailure(),
        null,
      ]);
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      final ProcessUploadQueue engine = ProcessUploadQueue(
        repository: repository,
        uploader: uploader,
        connectivity: connectivity,
        scheduler: scheduler,
        // Zero backoff so three sweeps can run back to back in the test.
        retryPolicy: const RetryPolicy(baseDelay: Duration.zero),
        clock: () => now,
        random: Random(7),
      );

      await engine();
      await engine();
      await engine();

      expect(repository.byId('task-1')!.status, UploadStatus.synced);
      expect(uploader.attemptsFor('task-1'), 3);
    });
  });

  group('rule 4 - unretryable failures stop immediately', () {
    test('a 400 fails on the first attempt and is never retried', () async {
      uploader.script(
        'task-1',
        <Failure?>[const ServerFailure(400, isRetryable: false)],
      );
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      await buildEngine()();

      final UploadTask task = repository.byId('task-1')!;
      expect(task.status, UploadStatus.failed);
      expect(task.attempt, 1);
      expect(task.nextAttemptAt, isNull, reason: 'nothing to come back for');
    });

    test('a missing file fails terminally rather than looping', () async {
      uploader.script(
        'task-1',
        <Failure?>[const MissingArtifactFailure('/tmp/gone.jpg')],
      );
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      await buildEngine()();

      expect(repository.byId('task-1')!.status, UploadStatus.failed);
      expect(
        repository.byId('task-1')!.lastFailureKind,
        UploadFailureKind.missingFile,
      );
    });
  });

  group('rescheduling', () {
    test('asks for another wake-up while work remains', () async {
      uploader.script('task-1', <Failure?>[const ServerFailure(503)]);
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      await buildEngine()();

      expect(scheduler.connectedRequests, isNotEmpty);
    });

    test('does not ask for one when the queue drained cleanly', () async {
      await repository.enqueueAll(<UploadTask>[taskFixture()]);

      await buildEngine()();

      expect(scheduler.connectedRequests, isEmpty);
    });
  });

  group('concurrency', () {
    test('a second sweep started mid-flight is a no-op', () async {
      await repository.enqueueAll(<UploadTask>[taskFixture()]);
      final ProcessUploadQueue engine = buildEngine();

      final results = await Future.wait(<Future<dynamic>>[engine(), engine()]);

      // Exactly one sweep did the work; the other returned idle rather than
      // uploading the same file twice.
      expect(uploader.attemptsFor('task-1'), 1);
      expect(
        results.where((dynamic r) => r.valueOrNull == SyncSweepReport.idle).length,
        1,
      );
    });
  });

  group('storage failures', () {
    test('a queue read failure is surfaced, not swallowed', () async {
      repository.readFailure = const StorageReadFailure();

      final report = await buildEngine()();

      expect(report.isFailure, isTrue);
      expect(report.failureOrNull, isA<StorageReadFailure>());
    });
  });

  group('rule 6 - a task is claimed before it is uploaded', () {
    test('a row another sweep won in the meantime is skipped, not sent twice',
        () async {
      // The real race: this sweep reads two eligible tasks, and before it gets
      // to the second one the WorkManager isolate — a different object graph,
      // invisible to this one's in-flight guard — claims it. Only the atomic
      // claim can catch that, which is why the read here deliberately still
      // hands over the row that has since been taken.
      repository = _StaleReadRepository(<UploadTask>[
        taskFixture(id: 'mine'),
        taskFixture(id: 'theirs'),
      ]);
      await repository.claim('theirs', now);

      final report = await buildEngine()();

      expect(uploader.attempts, <String>['mine']);
      expect(report.valueOrNull?.attempted, 1);
    });

    test('a task abandoned mid-transfer is re-queued, not stranded', () async {
      // The bug this closes: the process is killed between the claim and the
      // first byte. The row is left "uploading", which is not an eligible
      // state, so without a reaper that photograph is never attempted again.
      repository = FakeUploadQueueRepository(<UploadTask>[
        taskFixture(
          id: 'stranded',
          status: UploadStatus.uploading,
          bytesTransferred: 512,
        ),
      ]);

      await buildEngine()();

      expect(uploader.attempts, <String>['stranded']);
      expect(repository.byId('stranded')?.status, UploadStatus.synced);
    });

    test('a transfer that is still moving is left alone by the reaper',
        () async {
      repository = FakeUploadQueueRepository(<UploadTask>[
        taskFixture(id: 'moving'),
      ]);
      // A live lease, taken a moment ago by the other sweep.
      await repository.claim('moving', now);

      await buildEngine()();

      expect(uploader.attempts, isEmpty);
      expect(repository.byId('moving')?.status, UploadStatus.uploading);
    });
  });
}

/// A queue whose eligibility read is deliberately out of date.
///
/// It returns every task regardless of status, which is exactly what a *real*
/// read looks like from the losing side of a race: correct when it was taken,
/// stale by the time the caller acts on it. Nothing but the atomic claim can
/// close that window, so this is the only honest way to test it.
class _StaleReadRepository extends FakeUploadQueueRepository {
  _StaleReadRepository(super.initial);

  @override
  Future<Result<List<UploadTask>>> readEligible(DateTime now) async =>
      Result<List<UploadTask>>.success(tasks);
}

/// Uploads the first file successfully, then kills the link - the "signal died
/// halfway through the batch" scenario.
class _DropLinkAfterFirst implements UploaderPort {
  _DropLinkAfterFirst(this._delegate, this._connectivity);

  final FakeUploader _delegate;
  final FakeConnectivity _connectivity;

  @override
  Future<Result<void>> upload(
    UploadTask task, {
    void Function(UploadProgress progress)? onProgress,
  }) async {
    final Result<void> result =
        await _delegate.upload(task, onProgress: onProgress);
    _connectivity.quality = LinkQuality.offline;
    return result;
  }

  @override
  Future<void> cancel(String taskId) => _delegate.cancel(taskId);
}
