import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';

/// One progress tick from an in-flight upload.
class UploadProgress {
  const UploadProgress({
    required this.bytesTransferred,
    required this.totalBytes,
    required this.throughputBytesPerSecond,
  });

  final int bytesTransferred;
  final int totalBytes;
  final int throughputBytesPerSecond;
}

/// The transport that actually moves bytes.
///
/// Behind this port sits `MockUploadApi` for the assessment and a real HTTP
/// client in production. The engine cannot tell the difference, which is the
/// entire point: every retry, backoff and connectivity rule in this codebase
/// is exercised by the tests without a server existing.
abstract interface class UploaderPort {
  /// Uploads [task], emitting progress as it goes.
  ///
  /// Implementations must not throw: transport problems come back as a
  /// [Result] failure so the engine can classify and schedule them.
  Future<Result<void>> upload(
    UploadTask task, {
    void Function(UploadProgress progress)? onProgress,
  });

  /// Best-effort cancellation of an in-flight upload.
  Future<void> cancel(String taskId);
}

/// Live view of the network link.
abstract interface class ConnectivityPort {
  /// Emits whenever the link changes. The implementation is responsible for
  /// the "settle" debounce that turns a raw transport event into
  /// [LinkQuality.stable].
  Stream<LinkStatus> watch();

  /// The current link, sampled synchronously enough for a worker to gate on.
  Future<LinkStatus> current();
}

/// Schedules work that must survive the app being closed.
///
/// Kept as a port so the engine's rules can be tested on the Dart VM, where
/// WorkManager does not exist, and so the iOS implementation (BGTaskScheduler
/// semantics, which are far stricter) can differ without touching the engine.
abstract interface class BackgroundSchedulerPort {
  /// Registers the periodic sweep. Idempotent.
  Future<void> ensurePeriodicSyncScheduled();

  /// Asks the OS to run a sweep as soon as a network is available. Used when
  /// a fresh batch is enqueued while the device is offline.
  Future<void> requestSyncWhenConnected({String? reason});

  Future<void> cancelAll();
}
