import 'package:anchorage_harbor/domain/entities/retry_policy.dart';
import 'package:equatable/equatable.dart';

/// Where a queued photograph is in its journey to the server.
///
/// ```
///   queued ──► uploading ──► synced          (the happy path)
///     ▲            │
///     │            ├──► waitingForConnection  (no link — costs no attempt)
///     │            │            │
///     └────────────┴──► retrying ──► failed   (out of attempts)
///                  │
///                  └──► paused                (the user said stop)
/// ```
///
/// ## Why not just "pending / done / error"?
///
/// Two reasons. The reference design shows four visually distinct rows — but
/// more importantly, the **engine** treats them differently:
/// [waitingForConnection] is not a failure and must not consume an attempt,
/// while [retrying] is and does. Collapsing them would make the queue spend
/// its three attempts sitting in a tunnel.
enum UploadStatus {
  /// Accepted into the queue, not yet picked up.
  queued,

  /// Parked: a previous attempt could not run because there was no usable
  /// link. **No attempt was spent.** Resumes when connectivity returns.
  waitingForConnection,

  /// Bytes are moving right now. Also the "claimed" state — see
  /// `UploadQueueRepository.claim`.
  uploading,

  /// An attempt failed for a retryable reason; backoff is in progress.
  retrying,

  /// Delivered and acknowledged by the server. Terminal.
  synced,

  /// Out of attempts, or failed for a reason no retry can fix. Terminal.
  failed,

  /// Explicitly held by the user ("PAUSE ALL"). Never resumed automatically.
  paused;

  /// Nothing more will happen to this task by itself.
  bool get isTerminal => this == UploadStatus.synced || this == UploadStatus.failed;

  /// Whether the engine should consider picking this task up on this sweep.
  bool get isEligibleForPickup =>
      this == UploadStatus.queued ||
      this == UploadStatus.waitingForConnection ||
      this == UploadStatus.retrying;

  /// Whether bytes are in flight.
  bool get isActive => this == UploadStatus.uploading;
}

/// A persistable reason for the last failure.
///
/// The rich [Failure] hierarchy cannot be written to SQLite — and would be
/// misleading if it could, since a stack trace from three days ago helps
/// nobody. This enum keeps exactly the part the UI and the retry policy need.
enum UploadFailureKind {
  /// Nothing has failed yet.
  none,
  noConnection,
  lowBandwidth,
  timeout,
  server,
  missingFile,
  unknown;

  /// True when the *link* was the problem, not the file or the server.
  /// These never cost an attempt.
  bool get isConnectivityRelated =>
      this == UploadFailureKind.noConnection || this == UploadFailureKind.lowBandwidth;
}

/// **One photograph in the durable upload queue.**
///
/// This is the unit of durability. A row is written to SQLite the instant the
/// shutter closes, and only leaves the queue once the server acknowledges it
/// — which is what lets the app be killed, rebooted or flown across an ocean
/// without losing a photograph.
///
/// ## Immutable, like everything else in the domain
///
/// Nothing mutates a task. State changes produce a *new* task via [copyWith],
/// and the repository writes it. That makes every transition an explicit,
/// greppable line of code rather than a field assignment buried somewhere.
class UploadTask extends Equatable {
  const UploadTask({
    required this.id,
    required this.batchId,
    required this.filePath,
    required this.displayName,
    required this.sizeBytes,
    required this.createdAt,
    this.status = UploadStatus.queued,
    this.attempt = 0,
    this.maxAttempts = defaultMaxAttempts,
    this.bytesTransferred = 0,
    this.nextAttemptAt,
    this.lastFailureKind = UploadFailureKind.none,
    this.throughputBytesPerSecond,
    this.completedAt,
  });

  /// Mirrors [RetryPolicy.defaultMaxAttempts] rather than restating it.
  ///
  /// These used to be two independent `5`s, which is a disagreement waiting
  /// to happen: the engine decides when to stop from the policy, and the
  /// row's `ATTEMPT 2/3` label is read from here.
  static const int defaultMaxAttempts = RetryPolicy.defaultMaxAttempts;

  /// Unique id for this one file. Also the SQLite primary key.
  final String id;

  /// Which capture session this file came from. One shutter session produces
  /// one batch of several files, and the Upload Manager groups by this.
  final String batchId;

  /// Absolute path of the captured file inside the app's private directory.
  final String filePath;

  /// Human-facing name shown in the queue, e.g. `IMG_0042.jpg`.
  final String displayName;

  /// File size in bytes. Denominator of [progress], so it is read a lot.
  final int sizeBytes;

  /// When the shutter closed. Drives the queue's ordering.
  final DateTime createdAt;

  /// Where this task is in its journey. See [UploadStatus].
  final UploadStatus status;

  /// How many attempts have been **spent**.
  ///
  /// Connectivity parks do not count — see [RetryPolicy.defaultMaxAttempts]
  /// for the full reasoning.
  final int attempt;

  /// The budget. Normally [defaultMaxAttempts].
  final int maxAttempts;

  /// How many bytes have made it so far. Numerator of [progress].
  final int bytesTransferred;

  /// Earliest wall-clock time the engine may try again — the backoff deadline.
  ///
  /// Null means "ready now".
  final DateTime? nextAttemptAt;

  /// Why the last attempt failed, in a form SQLite can store.
  final UploadFailureKind lastFailureKind;

  /// Observed rate of the most recent attempt. Drives the "12 MB/s" read-out.
  final int? throughputBytesPerSecond;

  /// When the task reached a terminal state.
  final DateTime? completedAt;

  /// Upload progress from `0.0` to `1.0`.
  ///
  /// Guarded against a zero-byte file so the progress bar can never divide
  /// by zero.
  double get progress =>
      sizeBytes <= 0 ? 0 : (bytesTransferred / sizeBytes).clamp(0.0, 1.0);

  /// Whether the budget still has room for another try.
  bool get hasAttemptsLeft => attempt < maxAttempts;

  /// Whether backoff has elapsed (or was never set).
  ///
  /// [now] is passed in rather than read from the clock, so tests can put the
  /// task at any point in its backoff without waiting.
  bool isReadyAt(DateTime now) =>
      nextAttemptAt == null || !now.isBefore(nextAttemptAt!);

  /// Returns a copy with the given fields changed.
  ///
  /// Note the two `clear*` flags. `nextAttemptAt: null` cannot mean "clear
  /// it", because that is indistinguishable from "do not change it" in Dart's
  /// named-argument model. Passing `clearNextAttemptAt: true` is how a task
  /// is made ready immediately.
  UploadTask copyWith({
    UploadStatus? status,
    int? attempt,
    int? bytesTransferred,
    DateTime? nextAttemptAt,
    bool clearNextAttemptAt = false,
    UploadFailureKind? lastFailureKind,
    int? throughputBytesPerSecond,
    bool clearThroughput = false,
    DateTime? completedAt,
  }) {
    return UploadTask(
      id: id,
      batchId: batchId,
      filePath: filePath,
      displayName: displayName,
      sizeBytes: sizeBytes,
      createdAt: createdAt,
      status: status ?? this.status,
      attempt: attempt ?? this.attempt,
      maxAttempts: maxAttempts,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      nextAttemptAt: clearNextAttemptAt ? null : (nextAttemptAt ?? this.nextAttemptAt),
      lastFailureKind: lastFailureKind ?? this.lastFailureKind,
      throughputBytesPerSecond:
          clearThroughput ? null : (throughputBytesPerSecond ?? this.throughputBytesPerSecond),
      completedAt: completedAt ?? this.completedAt,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        id,
        batchId,
        filePath,
        displayName,
        sizeBytes,
        createdAt,
        status,
        attempt,
        maxAttempts,
        bytesTransferred,
        nextAttemptAt,
        lastFailureKind,
        throughputBytesPerSecond,
        completedAt,
      ];
}
