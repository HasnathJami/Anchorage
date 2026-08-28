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

  UploadManagerBloc buildBloc() => UploadManagerBloc(
        watchQueue: WatchUploadQueue(repository),
        processQueue: ProcessUploadQueue(
          repository: repository,
          uploader: uploader,
          connectivity: connectivity,
          scheduler: scheduler,
          clock: () => DateTime(2026, 8, 28, 9, 30),
        ),
        connectivity: connectivity,
        pauseAll: PauseAllUploads(repository),
        resumeAll: ResumeAllUploads(repository: repository, scheduler: scheduler),
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
