import 'package:anchorage_harbor/data/datasources/upload_queue_database.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';

/// Row <-> entity mapping.
///
/// Enums are persisted by *name*, never by index. An index would silently
/// re-map every stored row the day someone inserts a new case in the middle
/// of the enum - the kind of bug that corrupts a user's queue and is
/// impossible to spot in review.
extension UploadTaskRowMapper on UploadTask {
  Map<String, Object?> toRow() => <String, Object?>{
        UploadQueueColumns.id: id,
        UploadQueueColumns.batchId: batchId,
        UploadQueueColumns.filePath: filePath,
        UploadQueueColumns.displayName: displayName,
        UploadQueueColumns.sizeBytes: sizeBytes,
        UploadQueueColumns.createdAt: createdAt.millisecondsSinceEpoch,
        UploadQueueColumns.status: status.name,
        UploadQueueColumns.attempt: attempt,
        UploadQueueColumns.maxAttempts: maxAttempts,
        UploadQueueColumns.bytesTransferred: bytesTransferred,
        UploadQueueColumns.nextAttemptAt: nextAttemptAt?.millisecondsSinceEpoch,
        UploadQueueColumns.failureKind: lastFailureKind.name,
        UploadQueueColumns.throughput: throughputBytesPerSecond,
        UploadQueueColumns.completedAt: completedAt?.millisecondsSinceEpoch,
      };
}

UploadTask uploadTaskFromRow(Map<String, Object?> row) {
  return UploadTask(
    id: row[UploadQueueColumns.id]! as String,
    batchId: row[UploadQueueColumns.batchId]! as String,
    filePath: row[UploadQueueColumns.filePath]! as String,
    displayName: row[UploadQueueColumns.displayName]! as String,
    sizeBytes: row[UploadQueueColumns.sizeBytes]! as int,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row[UploadQueueColumns.createdAt]! as int,
    ),
    status: _statusFrom(row[UploadQueueColumns.status] as String?),
    attempt: (row[UploadQueueColumns.attempt] as int?) ?? 0,
    maxAttempts:
        (row[UploadQueueColumns.maxAttempts] as int?) ?? UploadTask.defaultMaxAttempts,
    bytesTransferred: (row[UploadQueueColumns.bytesTransferred] as int?) ?? 0,
    nextAttemptAt: _dateOrNull(row[UploadQueueColumns.nextAttemptAt] as int?),
    lastFailureKind: _failureFrom(row[UploadQueueColumns.failureKind] as String?),
    throughputBytesPerSecond: row[UploadQueueColumns.throughput] as int?,
    completedAt: _dateOrNull(row[UploadQueueColumns.completedAt] as int?),
  );
}

DateTime? _dateOrNull(int? millis) =>
    millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);

/// Unknown values degrade to a safe default rather than throwing: a queue that
/// refuses to open because one row holds a status from a newer build is a far
/// worse outcome than one row reading as `queued`.
UploadStatus _statusFrom(String? name) => UploadStatus.values.firstWhere(
      (UploadStatus status) => status.name == name,
      orElse: () => UploadStatus.queued,
    );

UploadFailureKind _failureFrom(String? name) => UploadFailureKind.values.firstWhere(
      (UploadFailureKind kind) => kind.name == name,
      orElse: () => UploadFailureKind.none,
    );
