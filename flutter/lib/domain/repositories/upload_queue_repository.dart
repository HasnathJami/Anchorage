import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';

/// **Durable storage for the upload queue** — the interface the domain
/// defines and the data layer implements.
///
/// Implemented by `UploadQueueRepositoryImpl` on top of SQLite. The domain
/// never learns that SQLite exists, which is what lets
/// [ProcessUploadQueue] be tested against an in-memory fake.
///
/// ## Why every mutation is its own method
///
/// There is no generic `save(task)`. Each transition is a separate method, so
/// the persistence layer can express it as a **targeted UPDATE**. Two
/// payoffs:
///
/// 1. The write stays small — important when [updateProgress] fires several
///    times a second during a transfer.
/// 2. The complete set of legal transitions is readable in one place. If a
///    state change is not in this list, it does not happen.
abstract interface class UploadQueueRepository {
  /// The whole queue, newest batch first, as a live stream.
  ///
  /// Backed by a SQLite trigger, so the Upload Manager updates by itself
  /// whenever any row changes.
  Stream<List<UploadTask>> watchQueue();

  /// One-shot read, for the background worker — which has no UI to feed and
  /// therefore no reason to hold a stream open.
  Future<Result<List<UploadTask>>> readQueue();

  /// Writes a whole batch in one transaction. All rows land, or none do.
  Future<Result<void>> enqueueAll(List<UploadTask> tasks);

  /// Tasks the engine may attempt **right now**, oldest first.
  ///
  /// Excludes terminal and paused rows, and rows still inside their backoff
  /// window — which is what [now] is for.
  Future<Result<List<UploadTask>>> readEligible(DateTime now);

  /// Atomically takes ownership of a task for one upload attempt.
  ///
  /// Returns `true` only if this caller won the row.
  ///
  /// Two sweeps can genuinely race: the Bloc sweeps in the foreground the
  /// moment the link steadies, and WorkManager sweeps from its own isolate
  /// with its own object graph — so an in-process `bool _inFlight` cannot see
  /// the other side. Without a claim the same photograph gets uploaded twice,
  /// which on a metered link is a real cost to a real person.
  ///
  /// [claimedAt] starts the task's lease. See [requeueStalled] for the other
  /// half of this mechanism.
  Future<Result<bool>> claim(String id, DateTime claimedAt);

  /// Releases tasks whose lease expired back into the queue.
  ///
  /// A task is marked `uploading` before its bytes move. If the process is
  /// killed at that moment — the user swipes the app away, Android reclaims
  /// memory — the row is left `uploading` forever. And `uploading` is not an
  /// eligible state, so that photograph would **never be attempted again**.
  ///
  /// This is the sweeper for exactly that: anything claimed before
  /// [staleBefore] is assumed abandoned and re-queued from byte zero.
  Future<Result<int>> requeueStalled(DateTime staleBefore);

  /// Sets a task's status directly. Used for pause and for manual moves.
  Future<Result<void>> updateStatus(String id, UploadStatus status);

  /// Records transfer progress, and **renews the claim lease**.
  ///
  /// That second job is why a slow-but-moving upload is never reaped by
  /// [requeueStalled]: only a transfer that has genuinely stopped expires.
  Future<Result<void>> updateProgress(
    String id, {
    required int bytesTransferred,
    int? throughputBytesPerSecond,
  });

  /// The happy ending: delivered and acknowledged.
  Future<Result<void>> markSynced(String id, DateTime completedAt);

  /// Records a failure that **was the task's own fault**, spending an
  /// attempt.
  ///
  /// [status] is [UploadStatus.retrying] when budget remains, or
  /// [UploadStatus.failed] when it does not. [nextAttemptAt] carries the
  /// jittered backoff deadline.
  Future<Result<void>> markAttemptFailed(
    String id, {
    required int attempt,
    required UploadStatus status,
    required UploadFailureKind failureKind,
    DateTime? nextAttemptAt,
  });

  /// Parks a task **without spending an attempt** — the no-network path.
  ///
  /// The distinction between this and [markAttemptFailed] is the single most
  /// important rule in the sync engine. See [ProcessUploadQueue] rule 3.
  Future<Result<void>> parkForConnectivity(String id, UploadFailureKind kind);

  /// Holds every non-terminal task. "PAUSE ALL".
  Future<Result<void>> pauseAll();

  /// Releases held tasks back into the queue. "RESUME ALL".
  Future<Result<void>> resumeAll();

  /// Resets one failed task so the user can try it again by hand.
  Future<Result<void>> retry(String id);

  /// Gives every *recoverable* failure a fresh budget, and returns how many
  /// rows that was.
  ///
  /// Two kinds of row are deliberately left alone:
  ///
  /// - **Rows whose failure no retry can fix.** A file the operating system
  ///   has swept away is not coming back, and re-queueing it would put a row
  ///   in the list that can only fail again — the difference between "we will
  ///   keep trying" and "we are wasting your battery".
  /// - **Paused rows.** Pause is a deliberate instruction from the user, and
  ///   this must not quietly countermand it.
  Future<Result<int>> retryFailed();

  /// Removes one task from the queue entirely.
  Future<Result<void>> remove(String id);

  /// Drops everything already delivered — housekeeping after a batch lands.
  ///
  /// Returns how many rows went.
  Future<Result<int>> purgeSynced();
}
