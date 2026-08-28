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

  bool get isPaused =>
      tasks.isNotEmpty &&
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
    if (result.isSuccess) {
      await _scheduler.requestSyncWhenConnected(reason: 'user resumed');
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
