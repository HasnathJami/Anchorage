import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/features/sync/domain/entities/upload_task.dart';

/// Durable storage for the upload queue.
///
/// Every mutation is a separate method rather than a generic `save(task)` so
/// the persistence layer can express each one as a targeted UPDATE. That keeps
/// the write small (important when a progress tick fires several times a
/// second) and makes the set of legal transitions readable in one place.
abstract interface class UploadQueueRepository {
  /// The whole queue, newest batch first, as a live stream.
  Stream<List<UploadTask>> watchQueue();

  /// One-shot read - used by the background worker, which has no UI to feed.
  Future<Result<List<UploadTask>>> readQueue();

  Future<Result<void>> enqueueAll(List<UploadTask> tasks);

  /// Tasks the engine may attempt right now, in FIFO order.
  Future<Result<List<UploadTask>>> readEligible(DateTime now);

  Future<Result<void>> updateStatus(String id, UploadStatus status);

  Future<Result<void>> updateProgress(
    String id, {
    required int bytesTransferred,
    int? throughputBytesPerSecond,
  });

  Future<Result<void>> markSynced(String id, DateTime completedAt);

  Future<Result<void>> markAttemptFailed(
    String id, {
    required int attempt,
    required UploadStatus status,
    required UploadFailureKind failureKind,
    DateTime? nextAttemptAt,
  });

  /// Park a task without spending an attempt (no network).
  Future<Result<void>> parkForConnectivity(String id, UploadFailureKind kind);

  Future<Result<void>> pauseAll();

  Future<Result<void>> resumeAll();

  /// Reset a failed task so the user can try again by hand.
  Future<Result<void>> retry(String id);

  Future<Result<void>> remove(String id);

  /// Drop everything already delivered - housekeeping after a batch lands.
  Future<Result<int>> purgeSynced();
}
