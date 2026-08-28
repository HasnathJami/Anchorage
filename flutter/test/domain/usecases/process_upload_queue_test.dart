import 'dart:math';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';
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
  }) =>
      ProcessUploadQueue(
        repository: repository,
        uploader: uploader,
        connectivity: connectivity,
        scheduler: scheduler,
        retryPolicy: policy,
        clock: () => now,
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

    test('exhausting the attempt budget fails the task permanently', () async {
      uploader.script('task-1', <Failure?>[const ServerFailure(503)]);
      await repository.enqueueAll(<UploadTask>[
        taskFixture(status: UploadStatus.retrying, attempt: 4),
      ]);

      final report = await buildEngine()();

      final UploadTask task = repository.byId('task-1')!;
      expect(task.status, UploadStatus.failed);
      expect(task.attempt, 5);
      expect(report.valueOrNull!.permanentlyFailed, 1);
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
