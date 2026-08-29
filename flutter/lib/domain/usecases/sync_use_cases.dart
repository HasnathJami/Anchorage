import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/domain/entities/capture_batch.dart';
import 'package:anchorage_harbor/domain/entities/batch_progress.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/domain/repositories/upload_queue_repository.dart';
import 'package:anchorage_harbor/domain/services/sync_ports.dart';

/// Moves a finished capture batch into the durable queue.
///
/// The order matters: the rows are committed to SQLite *before* the OS is
/// asked for a wake-up. Reversing it would leave a window in which the worker
/// runs, finds an empty queue, and goes back to sleep - and the batch would
/// then wait for the next periodic sweep instead of uploading now.
class EnqueueBatch {
  const EnqueueBatch({
    required UploadQueueRepository repository,
    required BackgroundSchedulerPort scheduler,
  })  : _repository = repository,
        _scheduler = scheduler;

  final UploadQueueRepository _repository;
  final BackgroundSchedulerPort _scheduler;

  Future<Result<int>> call(CaptureBatch batch) async {
    if (batch.shots.isEmpty) return const Result<int>.success(0);

    final List<UploadTask> tasks = batch.shots
        .map(
          (CapturedShot shot) => UploadTask(
            id: shot.id,
            batchId: batch.id,
            filePath: shot.filePath,
            displayName: shot.displayName,
            sizeBytes: shot.sizeBytes,
            createdAt: shot.capturedAt,
          ),
        )
        .toList(growable: false);

    final Result<void> stored = await _repository.enqueueAll(tasks);

    return stored.fold(
      (_) async {
        await _scheduler.requestSyncWhenConnected(reason: 'batch ${batch.id}');
        return Result<int>.success(tasks.length);
      },
      (failure) async => Result<int>.failure(failure),
    );
  }
}

/// Live queue plus the aggregate header, as one stream.
///
/// Deriving [BatchProgress] here - rather than in the Bloc - keeps the
/// invariant "header agrees with rows" in a single tested place.
class WatchUploadQueue {
  const WatchUploadQueue(this._repository);

  final UploadQueueRepository _repository;

  Stream<QueueSnapshot> call() => _repository.watchQueue().map(
        (List<UploadTask> tasks) => QueueSnapshot(
          tasks: tasks,
          progress: BatchProgress.from(tasks),
        ),
      );
}

/// The queue and its summary at one instant.
class QueueSnapshot {
  const QueueSnapshot({required this.tasks, required this.progress});

  static const QueueSnapshot empty =
      QueueSnapshot(tasks: <UploadTask>[], progress: BatchProgress.empty);

  final List<UploadTask> tasks;
  final BatchProgress progress;

  bool get isEmpty => tasks.isEmpty;

  int get pendingCount => tasks
      .where((UploadTask task) => task.status != UploadStatus.synced)
      .length;

  /// Whether the queue is being *held*, which is not the same as having
  /// nothing left to do.
  ///
  /// Both halves are needed. "Every task is paused or finished" alone was true
  /// of a queue where everything had been delivered, so a fully synced list
  /// offered **RESUME ALL** - a button naming a state the user was not in, for
  /// work that did not exist. At least one row has to actually be held.
  bool get isPaused =>
      tasks.any((UploadTask task) => task.status == UploadStatus.paused) &&
      tasks.every(
        (UploadTask task) =>
            task.status == UploadStatus.paused || task.status.isTerminal,
      );
}

/// Holds every non-terminal task. The user asked; the engine obeys.
class PauseAllUploads {
  const PauseAllUploads(this._repository);

  final UploadQueueRepository _repository;

  Future<Result<void>> call() => _repository.pauseAll();
}

/// Releases held tasks back into the queue and asks for a sweep.
///
/// **Rows that gave up are re-armed too.** `RESUME ALL` reads, to the person
/// pressing it, as "get on with all of it" - and a list that still shows
/// `REJECTED BY SERVER` after they pressed it has not obeyed. Releasing only
/// the paused rows was the literal reading of the button and the wrong one.
///
/// The exception is the same as everywhere else: a row whose file has gone is
/// left where it is, because no amount of resuming will find it.
class ResumeAllUploads {
  const ResumeAllUploads({
    required UploadQueueRepository repository,
    required BackgroundSchedulerPort scheduler,
  })  : _repository = repository,
        _scheduler = scheduler;

  final UploadQueueRepository _repository;
  final BackgroundSchedulerPort _scheduler;

  Future<Result<void>> call() async {
    final Result<void> result = await _repository.resumeAll();
    if (result.isFailure) return result;

    // Best effort, and deliberately not fatal: releasing the held rows is the
    // button's core promise and must not be undone because re-arming the
    // failed ones did not work.
    await _repository.retryFailed();

    await _scheduler.requestSyncWhenConnected(reason: 'user resumed');
    return result;
  }
}

/// Gives every recoverable failure a fresh budget, in one go.
///
/// The brief asks for uploads to resume without user intervention, and the
/// engine does that for everything it still considers *live*. A row that has
/// spent its attempts is deliberately not live - that is what an attempt
/// ceiling is for - so without this it sat at `FAILED` until someone pressed
/// Retry on it, even once the thing that had been failing was fixed.
///
/// Opening the Upload Manager is the intervention. It is a person deliberately
/// coming to look at the queue, and treating that as "try everything again" is
/// both what they expect and cheaper than making them tap each row.
class RetryFailedUploads {
  const RetryFailedUploads({
    required UploadQueueRepository repository,
    required BackgroundSchedulerPort scheduler,
  })  : _repository = repository,
        _scheduler = scheduler;

  final UploadQueueRepository _repository;
  final BackgroundSchedulerPort _scheduler;

  /// Returns how many rows were given another go.
  Future<Result<int>> call() async {
    final Result<int> result = await _repository.retryFailed();

    if ((result.valueOrNull ?? 0) > 0) {
      await _scheduler.requestSyncWhenConnected(reason: 'upload manager opened');
    }
    return result;
  }
}

/// Re-arms a single failed task, clearing its backoff so it goes next.
class RetryUpload {
  const RetryUpload({
    required UploadQueueRepository repository,
    required BackgroundSchedulerPort scheduler,
  })  : _repository = repository,
        _scheduler = scheduler;

  final UploadQueueRepository _repository;
  final BackgroundSchedulerPort _scheduler;

  Future<Result<void>> call(String taskId) async {
    final Result<void> result = await _repository.retry(taskId);
    if (result.isSuccess) {
      await _scheduler.requestSyncWhenConnected(reason: 'manual retry');
    }
    return result;
  }
}

/// Removes a task from the queue entirely.
class DiscardUpload {
  const DiscardUpload(this._repository);

  final UploadQueueRepository _repository;

  Future<Result<void>> call(String taskId) => _repository.remove(taskId);
}

/// Housekeeping: forget everything already delivered.
class ClearSyncedUploads {
  const ClearSyncedUploads(this._repository);

  final UploadQueueRepository _repository;

  Future<Result<int>> call() => _repository.purgeSynced();
}
