import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Column names, in one place, so a typo is a compile error rather than a
/// silent empty result set.
abstract final class UploadQueueColumns {
  static const String table = 'upload_tasks';

  static const String id = 'id';
  static const String batchId = 'batch_id';
  static const String filePath = 'file_path';
  static const String displayName = 'display_name';
  static const String sizeBytes = 'size_bytes';
  static const String createdAt = 'created_at';
  static const String status = 'status';
  static const String attempt = 'attempt';
  static const String maxAttempts = 'max_attempts';
  static const String bytesTransferred = 'bytes_transferred';
  static const String nextAttemptAt = 'next_attempt_at';
  static const String failureKind = 'failure_kind';
  static const String throughput = 'throughput_bps';
  static const String completedAt = 'completed_at';
}

/// Opens (and migrates) the queue database.
///
/// SQLite rather than a JSON file or SharedPreferences for one reason that
/// matters more than any other here: **atomic, durable single-row updates**.
/// A progress tick fires several times a second; rewriting a whole JSON
/// document that often would be both slow and, if the process died mid-write,
/// a way to lose the entire queue. A row update either happens or does not.
class UploadQueueDatabase {
  UploadQueueDatabase({DatabaseFactory? factory, String? directoryOverride})
      : _factory = factory,
        _directoryOverride = directoryOverride;

  static const String fileName = 'anchorage_harbor_queue.db';
  static const int schemaVersion = 1;

  final DatabaseFactory? _factory;
  final String? _directoryOverride;

  Database? _database;

  Future<Database> open() async {
    final Database? existing = _database;
    if (existing != null && existing.isOpen) return existing;

    final DatabaseFactory factory = _factory ?? databaseFactory;
    final String directory = _directoryOverride ?? await factory.getDatabasesPath();
    final String path = p.join(directory, fileName);

    final Database database = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (Database db, int version) => _createSchema(db),
        onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );

    _database = database;
    return database;
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE ${UploadQueueColumns.table} (
        ${UploadQueueColumns.id} TEXT PRIMARY KEY NOT NULL,
        ${UploadQueueColumns.batchId} TEXT NOT NULL,
        ${UploadQueueColumns.filePath} TEXT NOT NULL,
        ${UploadQueueColumns.displayName} TEXT NOT NULL,
        ${UploadQueueColumns.sizeBytes} INTEGER NOT NULL,
        ${UploadQueueColumns.createdAt} INTEGER NOT NULL,
        ${UploadQueueColumns.status} TEXT NOT NULL,
        ${UploadQueueColumns.attempt} INTEGER NOT NULL DEFAULT 0,
        ${UploadQueueColumns.maxAttempts} INTEGER NOT NULL DEFAULT ${UploadTask.defaultMaxAttempts},
        ${UploadQueueColumns.bytesTransferred} INTEGER NOT NULL DEFAULT 0,
        ${UploadQueueColumns.nextAttemptAt} INTEGER,
        ${UploadQueueColumns.failureKind} TEXT NOT NULL DEFAULT 'none',
        ${UploadQueueColumns.throughput} INTEGER,
        ${UploadQueueColumns.completedAt} INTEGER
      )
    ''');

    // The engine's hot query is "what may I attempt now, oldest first".
    await db.execute(
      'CREATE INDEX idx_queue_pickup ON ${UploadQueueColumns.table} '
      '(${UploadQueueColumns.status}, ${UploadQueueColumns.nextAttemptAt}, ${UploadQueueColumns.createdAt})',
    );
    await db.execute(
      'CREATE INDEX idx_queue_batch ON ${UploadQueueColumns.table} (${UploadQueueColumns.batchId})',
    );
  }
}
