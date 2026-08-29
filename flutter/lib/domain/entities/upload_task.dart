import 'package:anchorage_harbor/domain/entities/retry_policy.dart';
import 'package:equatable/equatable.dart';

/// Where a queued artefact is in its journey to the server.
///
/// The states are deliberately finer-grained than "pending / done / error",
/// because the reference design shows four visually distinct rows and, more
/// importantly, because the *engine* treats them differently:
/// [waitingForConnection] is not a failure and must not consume an attempt,
/// while [retrying] is and does.
enum UploadStatus {
  /// Accepted into the queue, not yet picked up.
  queued,

  /// A previous attempt could not run because there was no usable link. The
  /// task is parked until connectivity returns - no attempt was spent.
  waitingForConnection,

  /// Bytes are moving right now.
  uploading,

  /// An attempt failed for a retryable reason; backoff is in progress.
  retrying,

  /// Delivered and acknowledged by the server.
  synced,

  /// Out of attempts, or failed for a reason no retry can fix.
  failed,

  /// Explicitly held by the user ("PAUSE ALL").
  paused;

  bool get isTerminal => this == UploadStatus.synced || this == UploadStatus.failed;

  /// Whether the engine should consider picking this task up on this pass.
  bool get isEligibleForPickup =>
      this == UploadStatus.queued ||
      this == UploadStatus.waitingForConnection ||
      this == UploadStatus.retrying;

  bool get isActive => this == UploadStatus.uploading;
}

/// A persistable reason for the last failure.
///
/// The rich [Failure] hierarchy cannot be written to SQLite, and would be
/// misleading if it could - a stack trace from three days ago helps nobody.
/// This enum keeps exactly the part the UI and the retry policy need.
enum UploadFailureKind {
  none,
  noConnection,
  lowBandwidth,
  timeout,
  server,
  missingFile,
  unknown;

  bool get isConnectivityRelated =>
      this == UploadFailureKind.noConnection || this == UploadFailureKind.lowBandwidth;
}

/// One artefact in the durable upload queue.
///
/// This is the unit of durability: it is written to SQLite the instant the
/// shutter closes and only leaves the queue once the server acknowledges it,
/// which is what lets the app be killed, rebooted or flown across an ocean
/// without losing a photograph.
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
  /// These used to be two independent `5`s, which is a disagreement waiting to
  /// happen: the engine decides when to stop from the policy, and the row's
  /// `ATTEMPT 2/5` label is read from here.
  static const int defaultMaxAttempts = RetryPolicy.defaultMaxAttempts;

  final String id;
  final String batchId;

  /// Absolute path of the captured file inside the app's private directory.
  final String filePath;

  /// Human-facing name shown in the queue.
  final String displayName;

  final int sizeBytes;
  final DateTime createdAt;
  final UploadStatus status;

  /// How many attempts have been *spent*. Connectivity parks do not count.
  final int attempt;
  final int maxAttempts;

  final int bytesTransferred;

  /// Earliest wall-clock time the engine may try again (backoff).
  final DateTime? nextAttemptAt;

  final UploadFailureKind lastFailureKind;

  /// Observed rate of the most recent attempt; drives the "12 MB/s" read-out.
  final int? throughputBytesPerSecond;

  final DateTime? completedAt;

  /// 0.0 - 1.0. Guarded against a zero-byte file so the bar never divides by 0.
  double get progress =>
      sizeBytes <= 0 ? 0 : (bytesTransferred / sizeBytes).clamp(0.0, 1.0);

  bool get hasAttemptsLeft => attempt < maxAttempts;

  /// True when backoff has elapsed (or was never set).
  bool isReadyAt(DateTime now) =>
      nextAttemptAt == null || !now.isBefore(nextAttemptAt!);

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
