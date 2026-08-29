import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/domain/usecases/process_upload_queue.dart';
import 'package:anchorage_harbor/domain/usecases/sync_use_cases.dart';
import 'package:anchorage_harbor/presentation/sync/bloc/upload_manager_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late FakeUploadQueueRepository repository;
  late FakeUploader uploader;
  late FakeConnectivity connectivity;
  late RecordingScheduler scheduler;

  /// [clock] drives both the engine and the Bloc, so a test that cares about
  /// backoff deadlines can hand them the same real clock its Timer runs on.
  UploadManagerBloc buildBloc({
    DateTime Function()? clock,
    Duration parkedRetryInterval =
        UploadManagerBloc.defaultParkedRetryInterval,
  }) =>
      UploadManagerBloc(
        clock: clock ?? () => DateTime(2026, 8, 28, 9, 30),
        parkedRetryInterval: parkedRetryInterval,
        watchQueue: WatchUploadQueue(repository),
        processQueue: ProcessUploadQueue(
          repository: repository,
          uploader: uploader,
          connectivity: connectivity,
          scheduler: scheduler,
          clock: clock ?? () => DateTime(2026, 8, 28, 9, 30),
        ),
        connectivity: connectivity,
        pauseAll: PauseAllUploads(repository),
        resumeAll: ResumeAllUploads(repository: repository, scheduler: scheduler),
        retryFailed:
            RetryFailedUploads(repository: repository, scheduler: scheduler),
        retryUpload: RetryUpload(repository: repository, scheduler: scheduler),
        discardUpload: DiscardUpload(repository),
        clearSynced: ClearSyncedUploads(repository),
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

  /// Lets the Bloc's internal stream subscriptions and queued events settle.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  test('starting subscribes to the queue and sweeps once', () async {
    await repository.enqueueAll(<UploadTask>[taskFixture()]);
    final UploadManagerBloc bloc = buildBloc();

    bloc.add(const UploadManagerStarted());
    await settle();

    expect(bloc.state.tasks, isNotEmpty);
    expect(uploader.attemptsFor('task-1'), 1);
    await bloc.close();
  });

  test('the header progress agrees with the rows beneath it', () async {
    await repository.enqueueAll(<UploadTask>[
      taskFixture(id: 'a', sizeBytes: 100),
      taskFixture(id: 'b', sizeBytes: 100),
    ]);
    final UploadManagerBloc bloc = buildBloc();

    bloc.add(const UploadManagerStarted());
    await settle();

    expect(bloc.state.progress.totalTasks, 2);
    expect(bloc.state.progress.syncedTasks, 2);
    expect(bloc.state.progress.percent, 100);
    await bloc.close();
  });

  test('a link becoming stable resumes the queue with no user action', () async {
    connectivity.quality = LinkQuality.offline;
    await repository.enqueueAll(<UploadTask>[taskFixture()]);
    final UploadManagerBloc bloc = buildBloc();

    bloc.add(const UploadManagerStarted());
    await settle();

    // Offline: parked, nothing attempted.
    expect(uploader.attempts, isEmpty);
    expect(repository.byId('task-1')!.status, UploadStatus.waitingForConnection);

    // The network returns and settles.
    connectivity.emit(LinkQuality.stable);
    await settle();

    expect(uploader.attemptsFor('task-1'), 1);
    expect(repository.byId('task-1')!.status, UploadStatus.synced);
    await bloc.close();
  });

  test('a merely-connected (unstable) link does not start a transfer', () async {
    connectivity.quality = LinkQuality.offline;
    await repository.enqueueAll(<UploadTask>[taskFixture()]);
    final UploadManagerBloc bloc = buildBloc();

    bloc.add(const UploadManagerStarted());
    await settle();

    connectivity.emit(LinkQuality.unstable);
    await settle();

    expect(uploader.attempts, isEmpty, reason: 'the link has not settled yet');
    await bloc.close();
  });

  test('pausing holds everything and blocks automatic sweeps', () async {
    connectivity.quality = LinkQuality.offline;
    await repository.enqueueAll(<UploadTask>[taskFixture()]);
    final UploadManagerBloc bloc = buildBloc();

    bloc.add(const UploadManagerStarted());
    await settle();

    bloc.add(const UploadPauseAllRequested());
    await settle();

    expect(repository.byId('task-1')!.status, UploadStatus.paused);

    connectivity.emit(LinkQuality.stable);
    await settle();

    expect(uploader.attempts, isEmpty, reason: 'paused means paused');
    await bloc.close();
  });

  test('resuming releases the queue and sweeps', () async {
    await repository.enqueueAll(<UploadTask>[taskFixture()]);
    final UploadManagerBloc bloc = buildBloc();

    bloc.add(const UploadManagerStarted());
    await settle();
    bloc.add(const UploadPauseAllRequested());
    await settle();
    bloc.add(const UploadResumeAllRequested());
    await settle();

    expect(repository.byId('task-1')!.status, UploadStatus.synced);
    await bloc.close();
  });

  test('a manual retry resets the attempt budget and re-runs the task', () async {
    await repository.enqueueAll(<UploadTask>[
      taskFixture(status: UploadStatus.failed, attempt: 5),
    ]);
    final UploadManagerBloc bloc = buildBloc();

    bloc.add(const UploadManagerStarted());
    await settle();
    expect(uploader.attempts, isEmpty, reason: 'a failed task is not eligible');

    bloc.add(const UploadRetryRequested('task-1'));
    await settle();

    expect(repository.byId('task-1')!.status, UploadStatus.synced);
    await bloc.close();
  });

  test('discarding removes the task from the queue', () async {
    await repository.enqueueAll(<UploadTask>[taskFixture()]);
    final UploadManagerBloc bloc = buildBloc();

    bloc.add(const UploadManagerStarted());
    await settle();
    bloc.add(const UploadDiscardRequested('task-1'));
    await settle();

    expect(repository.byId('task-1'), isNull);
    await bloc.close();
  });

  group('opening the Upload Manager', () {
    // The Bloc is hoisted above the navigator so the engine keeps running
    // while the user is on the camera. That means "the app started" happens
    // once and "the user came to look at the queue" happens every time - and
    // the second is the one that means "try all of this again".

    test('a row that had given up is tried again, with no button pressed',
        () async {
      // The reported bug: with the mock set to FAILED the rows climb to
      // REJECTED BY SERVER, and then setting it back to SUCCESS did nothing
      // until each row was retried by hand.
      final UploadManagerBloc bloc = buildBloc();
      bloc.add(const UploadManagerStarted());
      await settle();
      connectivity.emit(LinkQuality.stable);
      await settle();

      await repository.enqueueAll(<UploadTask>[
        taskFixture(id: 'rejected', status: UploadStatus.failed, attempt: 3),
      ]);
      await settle();
      expect(repository.byId('rejected')?.status, UploadStatus.failed,
          reason: 'terminal until someone comes to look');

      bloc.add(const UploadManagerOpened());
      await settle();

      expect(repository.byId('rejected')?.status, UploadStatus.synced);
      await bloc.close();
    });

    test('it gets a fresh budget, not the exhausted one', () async {
      final UploadManagerBloc bloc = buildBloc();
      bloc.add(const UploadManagerStarted());
      await settle();
      connectivity.emit(LinkQuality.stable);
      await settle();

      uploader.script('rejected', <Failure?>[const ServerFailure(500)]);
      await repository.enqueueAll(<UploadTask>[
        taskFixture(id: 'rejected', status: UploadStatus.failed, attempt: 3),
      ]);
      await settle();

      bloc.add(const UploadManagerOpened());
      await settle();

      // One failure spent out of a budget that starts again at zero, so the
      // row is retrying rather than straight back to failed.
      expect(repository.byId('rejected')?.attempt, 1);
      expect(repository.byId('rejected')?.status, UploadStatus.retrying);
      await bloc.close();
    });

    test('a file that is gone is left where it is', () async {
      // The one failure no amount of coming to look at it can fix. Re-queueing
      // it would put a row in the list that can only fail again.
      final UploadManagerBloc bloc = buildBloc();
      bloc.add(const UploadManagerStarted());
      await settle();

      await repository.enqueueAll(<UploadTask>[
        taskFixture(id: 'gone', status: UploadStatus.failed, attempt: 3),
      ]);
      await repository.markAttemptFailed(
        'gone',
        attempt: 3,
        status: UploadStatus.failed,
        failureKind: UploadFailureKind.missingFile,
      );
      await settle();

      bloc.add(const UploadManagerOpened());
      await settle();

      expect(repository.byId('gone')?.status, UploadStatus.failed);
      await bloc.close();
    });

    test('a row the user paused is not quietly released', () async {
      // Pause is an instruction. Coming to look at the queue does not
      // countermand it.
      connectivity.quality = LinkQuality.offline;
      await repository.enqueueAll(<UploadTask>[taskFixture(id: 'held')]);

      final UploadManagerBloc bloc = buildBloc();
      bloc.add(const UploadManagerStarted());
      await settle();
      bloc.add(const UploadPauseAllRequested());
      await settle();
      connectivity.emit(LinkQuality.stable);
      await settle();

      bloc.add(const UploadManagerOpened());
      await settle();

      expect(repository.byId('held')?.status, UploadStatus.paused);
      await bloc.close();
    });
  });

  group('a link that says it is usable and carries nothing', () {
    test('the heartbeat backs off instead of hammering it', () async {
      // A captive portal, or one bar that reports itself connected. The queue
      // parks and keeps parking, and at a flat interval that is three full
      // sweeps a minute for as long as the app is open - a phone getting warm
      // for no delivered bytes.
      final UploadManagerBloc bloc = buildBloc(
        clock: DateTime.now,
        parkedRetryInterval: const Duration(milliseconds: 100),
      );
      bloc.add(const UploadManagerStarted());
      await settle();
      connectivity.emit(LinkQuality.stable);
      await settle();

      uploader.script(
        'stuck',
        List<Failure?>.filled(30, const LowBandwidthFailure()),
      );
      await repository.enqueueAll(<UploadTask>[taskFixture(id: 'stuck')]);
      await settle();

      await Future<void>.delayed(const Duration(milliseconds: 900));
      await settle();

      // Flat 100 ms would be nine or so attempts in that window. Doubling
      // each time - 100, 200, 400, 800 - is four at most.
      expect(uploader.attemptsFor('stuck'), lessThanOrEqualTo(5),
          reason: 'the interval has to be stretching, not holding');
      expect(uploader.attemptsFor('stuck'), greaterThan(1),
          reason: 'but it must still be trying');
      await bloc.close();
    });

    test('one delivered file makes it prompt again', () async {
      final UploadManagerBloc bloc = buildBloc(
        clock: DateTime.now,
        parkedRetryInterval: const Duration(milliseconds: 100),
      );
      bloc.add(const UploadManagerStarted());
      await settle();
      connectivity.emit(LinkQuality.stable);
      await settle();

      // Fails twice, so the heartbeat has started to stretch, then succeeds.
      uploader.script('stuck', <Failure?>[
        const LowBandwidthFailure(),
        const LowBandwidthFailure(),
      ]);
      await repository.enqueueAll(<UploadTask>[taskFixture(id: 'stuck')]);
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await settle();

      expect(repository.byId('stuck')?.status, UploadStatus.synced);

      // A second file must not inherit the backoff the first one earned.
      await repository.enqueueAll(<UploadTask>[taskFixture(id: 'fresh')]);
      await settle();

      expect(repository.byId('fresh')?.status, UploadStatus.synced);
      await bloc.close();
    });
  });

  group('RESUME ALL', () {
    test('releases the held rows and re-arms the rejected ones together',
        () async {
      // "Get on with all of it" is what the button says to the person pressing
      // it. A list still showing REJECTED BY SERVER afterwards has not obeyed.
      connectivity.quality = LinkQuality.offline;
      await repository.enqueueAll(<UploadTask>[
        taskFixture(id: 'held'),
        taskFixture(id: 'rejected', status: UploadStatus.failed, attempt: 3),
      ]);

      final UploadManagerBloc bloc = buildBloc();
      bloc.add(const UploadManagerStarted());
      await settle();
      bloc.add(const UploadPauseAllRequested());
      await settle();

      connectivity.emit(LinkQuality.stable);
      await settle();
      bloc.add(const UploadResumeAllRequested());
      await settle();

      expect(repository.byId('held')?.status, UploadStatus.synced);
      expect(repository.byId('rejected')?.status, UploadStatus.synced);
      await bloc.close();
    });
  });

  group('sweeps nobody asked for', () {
    // The brief's third bullet is "automatically retry once a stable
    // connection is detected **without user intervention**". Reacting only to
    // the link changing satisfies that sentence and still leaves the engine
    // looking dead in the two situations below, because nothing else in the
    // foreground was watching.

    test('work queued while the app is open is swept immediately', () async {
      // Before this, tapping UPLOAD BATCH on an already-stable link uploaded
      // nothing until WorkManager next woke — minutes of `IN QUEUE`.
      final UploadManagerBloc bloc = buildBloc();
      bloc.add(const UploadManagerStarted());
      await settle();
      connectivity.emit(LinkQuality.stable);
      await settle();

      await repository.enqueueAll(<UploadTask>[taskFixture(id: 'fresh')]);
      await settle();

      expect(uploader.attemptsFor('fresh'), 1);
      expect(repository.byId('fresh')?.status, UploadStatus.synced);
      await bloc.close();
    });

    test('a retry is re-attempted when its backoff elapses', () async {
      // A real clock, because the wake-up is a real Timer and the engine has
      // to agree with it about what "now" is.
      final DateTime start = DateTime.now();
      await repository.enqueueAll(<UploadTask>[
        taskFixture(
          id: 'later',
          status: UploadStatus.retrying,
          nextAttemptAt: start.add(const Duration(milliseconds: 300)),
        ),
      ]);

      final UploadManagerBloc bloc = buildBloc(clock: DateTime.now);
      bloc.add(const UploadManagerStarted());
      await settle();
      connectivity.emit(LinkQuality.stable);
      await settle();

      // Still serving its backoff: the point of backoff is that nothing
      // happens yet.
      expect(uploader.attemptsFor('later'), 0);

      await Future<void>.delayed(const Duration(milliseconds: 800));
      await settle();

      expect(uploader.attemptsFor('later'), 1);
      expect(repository.byId('later')?.status, UploadStatus.synced);
      await bloc.close();
    });

    test('parked work is tried again without waiting for a link event',
        () async {
      // The brief's "retry once a stable connection is detected" is served by
      // the link *transition*, and there are ordinary cases where that
      // transition never comes: a weak signal that reports itself connected
      // throughout, or a transport that died for a reason the radio knows
      // nothing about. Without this the row reads WAITING FOR CONNECTION on a
      // phone with four bars, forever.
      final UploadManagerBloc bloc = buildBloc(
        clock: DateTime.now,
        parkedRetryInterval: const Duration(milliseconds: 200),
      );
      bloc.add(const UploadManagerStarted());
      await settle();

      // The link is fine; the transport is not.
      connectivity.emit(LinkQuality.stable);
      await settle();
      uploader.script('parked', <Failure?>[const LowBandwidthFailure()]);
      await repository.enqueueAll(<UploadTask>[taskFixture(id: 'parked')]);
      await settle();

      expect(repository.byId('parked')?.status,
          UploadStatus.waitingForConnection);
      final int afterParking = uploader.attemptsFor('parked');

      // No link event of any kind from here on.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await settle();

      expect(uploader.attemptsFor('parked'), greaterThan(afterParking));
      expect(repository.byId('parked')?.status, UploadStatus.synced);
      await bloc.close();
    });

    test('parked work is not hammered between those heartbeats', () async {
      // Parked rows carry no backoff, so they read as "ready now" forever. A
      // sweep that parks one republishes the queue, and if that landed back on
      // the ready-now check the engine would spin against a failing server at
      // whatever rate the disk allows.
      final UploadManagerBloc bloc = buildBloc(
        clock: DateTime.now,
        parkedRetryInterval: const Duration(seconds: 30),
      );
      bloc.add(const UploadManagerStarted());
      await settle();
      connectivity.emit(LinkQuality.stable);
      await settle();

      uploader.script(
        'stuck',
        List<Failure?>.filled(20, const LowBandwidthFailure()),
      );
      await repository.enqueueAll(<UploadTask>[taskFixture(id: 'stuck')]);
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await settle();

      expect(uploader.attemptsFor('stuck'), 1,
          reason: 'one attempt, then it waits for the heartbeat');
      await bloc.close();
    });

    test('a paused queue gets no heartbeat at all', () async {
      connectivity.quality = LinkQuality.offline;
      await repository.enqueueAll(<UploadTask>[taskFixture(id: 'held')]);

      final UploadManagerBloc bloc = buildBloc(
        clock: DateTime.now,
        parkedRetryInterval: const Duration(milliseconds: 200),
      );
      bloc.add(const UploadManagerStarted());
      await settle();
      bloc.add(const UploadPauseAllRequested());
      await settle();
      connectivity.emit(LinkQuality.stable);
      await settle();

      final int before = uploader.attemptsFor('held');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await settle();

      expect(uploader.attemptsFor('held'), before);
      await bloc.close();
    });

    test('paused rows are not swept behind the user\'s back', () async {
      // Pause is a state of the *rows*, not a mode on the queue: `PAUSE ALL`
      // holds everything that exists when it is tapped. Work queued afterwards
      // is new work and does upload — which is why this asserts only about the
      // row that was actually held.
      // Starts offline so the launch sweep parks the row rather than
      // delivering it before there is anything left to pause.
      connectivity.quality = LinkQuality.offline;
      await repository.enqueueAll(<UploadTask>[taskFixture(id: 'held')]);

      final UploadManagerBloc bloc = buildBloc();
      bloc.add(const UploadManagerStarted());
      await settle();
      bloc.add(const UploadPauseAllRequested());
      await settle();

      final int before = uploader.attemptsFor('held');

      // The link comes back — the one event that normally resumes everything.
      connectivity.emit(LinkQuality.stable);
      await settle();

      expect(uploader.attemptsFor('held'), before);
      expect(repository.byId('held')?.status, UploadStatus.paused);
      await bloc.close();
    });

    test('an offline link does not start a sweep that would only park', () async {
      // The loop this prevents: park for no network -> queue republished ->
      // sweep -> park again -> forever.
      connectivity.quality = LinkQuality.offline;
      final UploadManagerBloc bloc = buildBloc();
      bloc.add(const UploadManagerStarted());
      await settle();

      await repository.enqueueAll(<UploadTask>[taskFixture(id: 'grounded')]);
      await settle();

      expect(uploader.attemptsFor('grounded'), 0);
      await bloc.close();
    });
  });

  test('clearing synced uploads empties the delivered rows only', () async {
    await repository.enqueueAll(<UploadTask>[
      taskFixture(id: 'done'),
      taskFixture(id: 'stuck', status: UploadStatus.failed),
    ]);
    final UploadManagerBloc bloc = buildBloc();

    bloc.add(const UploadManagerStarted());
    await settle();
    bloc.add(const UploadClearSyncedRequested());
    await settle();

    expect(repository.byId('done'), isNull);
    expect(repository.byId('stuck'), isNotNull);
    await bloc.close();
  });
}
