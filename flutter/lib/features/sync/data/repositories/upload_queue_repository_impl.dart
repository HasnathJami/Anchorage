import 'dart:async';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/features/sync/data/datasources/upload_queue_database.dart';
import 'package:anchorage_harbor/features/sync/data/models/upload_task_row.dart';
import 'package:anchorage_harbor/features/sync/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/features/sync/domain/repositories/upload_queue_repository.dart';
import 'package:sqflite/sqflite.dart';

/// SQLite-backed durable queue.
///
/// `sqflite` has no reactive query support, so change notification is explicit:
/// every write calls [_notify], which re-reads and pushes to the broadcast
/// stream. That is honest and cheap for a queue of tens of items, and it keeps
/// the "who republishes?" question answerable by reading one file - unlike a
/// hand-rolled trigger scheme that works until someone adds a write path and
/// forgets to fire it.
class UploadQueueRepositoryImpl implements UploadQueueRepository {
  UploadQueueRepositoryImpl({required UploadQueueDatabase database})
      : _database = database;

  final UploadQueueDatabase _database;
  final StreamController<List<UploadTask>> _controller =
      StreamController<List<UploadTask>>.broadcast();

  bool _seeded = false;

  @override
  Stream<List<UploadTask>> watchQueue() async* {
    // The first listener gets the current contents immediately rather than
    // waiting for the next write - otherwise the Upload Manager opens empty.
    if (!_seeded) {
      _seeded = true;
      final Result<List<UploadTask>> initial = await readQueue();
      yield initial.valueOrNull ?? const <UploadTask>[];
    } else {
      final Result<List<UploadTask>> initial = await readQueue();
      yield initial.valueOrNull ?? const <UploadTask>[];
    }

    yield* _controller.stream;
  }

  @override
  Future<Result<List<UploadTask>>> readQueue() => guard<List<UploadTask>>(
        () async {
          final Database db = await _database.open();
          final List<Map<String, Object?>> rows = await db.query(
            UploadQueueColumns.table,
            orderBy: '${UploadQueueColumns.createdAt} ASC',
          );
          return rows.map(uploadTaskFromRow).toList(growable: false);
        },
        onError: (Object error, StackTrace _) => StorageReadFailure(cause: error),
      );

  @override
  Future<Result<void>> enqueueAll(List<UploadTask> tasks) async {
    final Result<void> result = await guard<void>(
      () async {
        final Database db = await _database.open();
        // One transaction for the whole batch: a batch is either queued or it
        // is not. A half-enqueued batch would upload some photographs of a
        // site and silently drop the rest.
        await db.transaction((Transaction txn) async {
          for (final UploadTask task in tasks) {
            await txn.insert(
              UploadQueueColumns.table,
              task.toRow(),
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
          }
        });
      },
      onError: (Object error, StackTrace _) => StorageWriteFailure(cause: error),
    );

    await _notify();
    return result;
  }

  @override
  Future<Result<List<UploadTask>>> readEligible(DateTime now) =>
      guard<List<UploadTask>>(
        () async {
          final Database db = await _database.open();
          final List<Map<String, Object?>> rows = await db.query(
            UploadQueueColumns.table,
            where: '${UploadQueueColumns.status} IN (?, ?, ?) '
                'AND (${UploadQueueColumns.nextAttemptAt} IS NULL '
                'OR ${UploadQueueColumns.nextAttemptAt} <= ?)',
            whereArgs: <Object?>[
              UploadStatus.queued.name,
              UploadStatus.waitingForConnection.name,
              UploadStatus.retrying.name,
              now.millisecondsSinceEpoch,
            ],
            // FIFO: the oldest capture is the one the user has been waiting
            // longest to see delivered.
            orderBy: '${UploadQueueColumns.createdAt} ASC',
          );
          return rows.map(uploadTaskFromRow).toList(growable: false);
        },
        onError: (Object error, StackTrace _) => StorageReadFailure(cause: error),
      );

  @override
  Future<Result<void>> updateStatus(String id, UploadStatus status) =>
      _write(<String, Object?>{UploadQueueColumns.status: status.name}, id);

  @override
  Future<Result<void>> updateProgress(
    String id, {
    required int bytesTransferred,
    int? throughputBytesPerSecond,
  }) =>
      _write(
        <String, Object?>{
          UploadQueueColumns.bytesTransferred: bytesTransferred,
          UploadQueueColumns.throughput: throughputBytesPerSecond,
          UploadQueueColumns.status: UploadStatus.uploading.name,
        },
        id,
      );

  @override
  Future<Result<void>> markSynced(String id, DateTime completedAt) => _write(
        <String, Object?>{
          UploadQueueColumns.status: UploadStatus.synced.name,
          UploadQueueColumns.completedAt: completedAt.millisecondsSinceEpoch,
          UploadQueueColumns.failureKind: UploadFailureKind.none.name,
          UploadQueueColumns.nextAttemptAt: null,
          UploadQueueColumns.throughput: null,
        },
        id,
      );

  @override
  Future<Result<void>> markAttemptFailed(
    String id, {
    required int attempt,
    required UploadStatus status,
    required UploadFailureKind failureKind,
    DateTime? nextAttemptAt,
  }) =>
      _write(
        <String, Object?>{
          UploadQueueColumns.status: status.name,
          UploadQueueColumns.attempt: attempt,
          UploadQueueColumns.failureKind: failureKind.name,
          UploadQueueColumns.nextAttemptAt: nextAttemptAt?.millisecondsSinceEpoch,
          UploadQueueColumns.throughput: null,
        },
        id,
      );

  @override
  Future<Result<void>> parkForConnectivity(String id, UploadFailureKind kind) => _write(
        <String, Object?>{
          UploadQueueColumns.status: UploadStatus.waitingForConnection.name,
          UploadQueueColumns.failureKind: kind.name,
          // Cleared on purpose: the task is not on a timer, it is waiting for
          // an event. Leaving a stale backoff here would delay it *after* the
          // network came back.
          UploadQueueColumns.nextAttemptAt: null,
          UploadQueueColumns.throughput: null,
        },
        id,
      );

  @override
  Future<Result<void>> pauseAll() => _bulkWrite(
        values: <String, Object?>{
          UploadQueueColumns.status: UploadStatus.paused.name,
          UploadQueueColumns.throughput: null,
        },
        where: '${UploadQueueColumns.status} NOT IN (?, ?)',
        whereArgs: <Object?>[UploadStatus.synced.name, UploadStatus.failed.name],
      );

  @override
  Future<Result<void>> resumeAll() => _bulkWrite(
        values: <String, Object?>{
          UploadQueueColumns.status: UploadStatus.queued.name,
          UploadQueueColumns.nextAttemptAt: null,
        },
        where: '${UploadQueueColumns.status} = ?',
        whereArgs: <Object?>[UploadStatus.paused.name],
      );

  @override
  Future<Result<void>> retry(String id) => _write(
        <String, Object?>{
          UploadQueueColumns.status: UploadStatus.queued.name,
          // The attempt counter is reset because this is a *human* saying
          // "try again" - a deliberate act that deserves a fresh budget, not
          // the exhausted one that produced the failure.
          UploadQueueColumns.attempt: 0,
          UploadQueueColumns.nextAttemptAt: null,
          UploadQueueColumns.failureKind: UploadFailureKind.none.name,
          UploadQueueColumns.bytesTransferred: 0,
        },
        id,
      );

  @override
  Future<Result<void>> remove(String id) async {
    final Result<void> result = await guard<void>(
      () async {
        final Database db = await _database.open();
        await db.delete(
          UploadQueueColumns.table,
          where: '${UploadQueueColumns.id} = ?',
          whereArgs: <Object?>[id],
        );
      },
      onError: (Object error, StackTrace _) => StorageWriteFailure(cause: error),
    );
    await _notify();
    return result;
  }

  @override
  Future<Result<int>> purgeSynced() async {
    final Result<int> result = await guard<int>(
      () async {
        final Database db = await _database.open();
        return db.delete(
          UploadQueueColumns.table,
          where: '${UploadQueueColumns.status} = ?',
          whereArgs: <Object?>[UploadStatus.synced.name],
        );
      },
      onError: (Object error, StackTrace _) => StorageWriteFailure(cause: error),
    );
    await _notify();
    return result;
  }

  Future<Result<void>> _write(Map<String, Object?> values, String id) async {
    final Result<void> result = await guard<void>(
      () async {
        final Database db = await _database.open();
        await db.update(
          UploadQueueColumns.table,
          values,
          where: '${UploadQueueColumns.id} = ?',
          whereArgs: <Object?>[id],
        );
      },
      onError: (Object error, StackTrace _) => StorageWriteFailure(cause: error),
    );
    await _notify();
    return result;
  }

  Future<Result<void>> _bulkWrite({
    required Map<String, Object?> values,
    required String where,
    required List<Object?> whereArgs,
  }) async {
    final Result<void> result = await guard<void>(
      () async {
        final Database db = await _database.open();
        await db.update(
          UploadQueueColumns.table,
          values,
          where: where,
          whereArgs: whereArgs,
        );
      },
      onError: (Object error, StackTrace _) => StorageWriteFailure(cause: error),
    );
    await _notify();
    return result;
  }

  Future<void> _notify() async {
    if (_controller.isClosed || !_controller.hasListener) return;
    final Result<List<UploadTask>> snapshot = await readQueue();
    _controller.add(snapshot.valueOrNull ?? const <UploadTask>[]);
  }

  Future<void> dispose() async {
    await _controller.close();
    await _database.close();
  }
}
