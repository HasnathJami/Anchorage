import 'dart:async';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/permissions/permission_gateway.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/features/capture/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/features/capture/domain/entities/capture_batch.dart';
import 'package:anchorage_harbor/features/capture/domain/services/camera_port.dart';
import 'package:anchorage_harbor/features/sync/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/features/sync/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/features/sync/domain/repositories/upload_queue_repository.dart';
import 'package:anchorage_harbor/features/sync/domain/services/sync_ports.dart';

/// Hand-written fakes rather than generated mocks.
///
/// A mock asserts on *calls*; a fake lets a test assert on *behaviour*. For a
/// queue and a network - both inherently stateful - the second reads far
/// better and survives refactoring, so these carry real state and the tests
/// check the state that results.

// ------------------------------------------------------------------ sync

/// In-memory [UploadQueueRepository] with the same transition rules as the
/// SQLite implementation.
class FakeUploadQueueRepository implements UploadQueueRepository {
  FakeUploadQueueRepository([List<UploadTask> initial = const <UploadTask>[]]) {
    for (final UploadTask task in initial) {
      _tasks[task.id] = task;
    }
  }

  final Map<String, UploadTask> _tasks = <String, UploadTask>{};
  final StreamController<List<UploadTask>> _controller =
      StreamController<List<UploadTask>>.broadcast();

  Failure? readFailure;

  List<UploadTask> get tasks => _tasks.values.toList(growable: false);

  UploadTask? byId(String id) => _tasks[id];

  @override
  Stream<List<UploadTask>> watchQueue() async* {
    yield tasks;
    yield* _controller.stream;
  }

  @override
  Future<Result<List<UploadTask>>> readQueue() async {
    final Failure? failure = readFailure;
    if (failure != null) return Result<List<UploadTask>>.failure(failure);
    return Result<List<UploadTask>>.success(tasks);
  }

  @override
  Future<Result<List<UploadTask>>> readEligible(DateTime now) async {
    final Failure? failure = readFailure;
    if (failure != null) return Result<List<UploadTask>>.failure(failure);

    final List<UploadTask> eligible = tasks
        .where((UploadTask task) =>
            task.status.isEligibleForPickup && task.isReadyAt(now))
        .toList()
      ..sort((UploadTask a, UploadTask b) => a.createdAt.compareTo(b.createdAt));

    return Result<List<UploadTask>>.success(eligible);
  }

  @override
  Future<Result<void>> enqueueAll(List<UploadTask> tasks) async {
    for (final UploadTask task in tasks) {
      _tasks.putIfAbsent(task.id, () => task);
    }
    _emit();
    return const Result<void>.success(null);
  }

  @override
  Future<Result<void>> updateStatus(String id, UploadStatus status) async =>
      _mutate(id, (UploadTask task) => task.copyWith(status: status));

  @override
  Future<Result<void>> updateProgress(
    String id, {
    required int bytesTransferred,
    int? throughputBytesPerSecond,
  }) async =>
      _mutate(
        id,
        (UploadTask task) => task.copyWith(
          status: UploadStatus.uploading,
          bytesTransferred: bytesTransferred,
          throughputBytesPerSecond: throughputBytesPerSecond,
        ),
      );

  @override
  Future<Result<void>> markSynced(String id, DateTime completedAt) async => _mutate(
        id,
        (UploadTask task) => task.copyWith(
          status: UploadStatus.synced,
          completedAt: completedAt,
          lastFailureKind: UploadFailureKind.none,
          clearNextAttemptAt: true,
          clearThroughput: true,
        ),
      );

  @override
  Future<Result<void>> markAttemptFailed(
    String id, {
    required int attempt,
    required UploadStatus status,
    required UploadFailureKind failureKind,
    DateTime? nextAttemptAt,
  }) async =>
      _mutate(
        id,
        (UploadTask task) => task.copyWith(
          status: status,
          attempt: attempt,
          lastFailureKind: failureKind,
          nextAttemptAt: nextAttemptAt,
          clearNextAttemptAt: nextAttemptAt == null,
          clearThroughput: true,
        ),
      );

  @override
  Future<Result<void>> parkForConnectivity(
    String id,
    UploadFailureKind kind,
  ) async =>
      _mutate(
        id,
        (UploadTask task) => task.copyWith(
          status: UploadStatus.waitingForConnection,
          lastFailureKind: kind,
          clearNextAttemptAt: true,
          clearThroughput: true,
        ),
      );

  @override
  Future<Result<void>> pauseAll() async {
    for (final UploadTask task in tasks) {
      if (task.status.isTerminal) continue;
      _tasks[task.id] = task.copyWith(status: UploadStatus.paused);
    }
    _emit();
    return const Result<void>.success(null);
  }

  @override
  Future<Result<void>> resumeAll() async {
    for (final UploadTask task in tasks) {
      if (task.status != UploadStatus.paused) continue;
      _tasks[task.id] =
          task.copyWith(status: UploadStatus.queued, clearNextAttemptAt: true);
    }
    _emit();
    return const Result<void>.success(null);
  }

  @override
  Future<Result<void>> retry(String id) async => _mutate(
        id,
        (UploadTask task) => task.copyWith(
          status: UploadStatus.queued,
          attempt: 0,
          bytesTransferred: 0,
          lastFailureKind: UploadFailureKind.none,
          clearNextAttemptAt: true,
        ),
      );

  @override
  Future<Result<void>> remove(String id) async {
    _tasks.remove(id);
    _emit();
    return const Result<void>.success(null);
  }

  @override
  Future<Result<int>> purgeSynced() async {
    final int before = _tasks.length;
    _tasks.removeWhere(
      (_, UploadTask task) => task.status == UploadStatus.synced,
    );
    _emit();
    return Result<int>.success(before - _tasks.length);
  }

  Result<void> _mutate(String id, UploadTask Function(UploadTask) transform) {
    final UploadTask? task = _tasks[id];
    if (task == null) return const Result<void>.success(null);
    _tasks[id] = transform(task);
    _emit();
    return const Result<void>.success(null);
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(tasks);
  }

  Future<void> dispose() => _controller.close();
}

/// A scripted transport. Each task id can be given its own sequence of
/// outcomes, which is what makes "fails twice then succeeds" expressible.
class FakeUploader implements UploaderPort {
  FakeUploader({Failure? defaultFailure}) : _defaultFailure = defaultFailure;

  final Failure? _defaultFailure;
  final Map<String, List<Failure?>> _scripts = <String, List<Failure?>>{};
  final List<String> attempts = <String>[];

  /// `null` in the list means "this attempt succeeds".
  void script(String taskId, List<Failure?> outcomes) {
    _scripts[taskId] = List<Failure?>.of(outcomes);
  }

  int attemptsFor(String taskId) =>
      attempts.where((String id) => id == taskId).length;

  @override
  Future<Result<void>> upload(
    UploadTask task, {
    void Function(UploadProgress progress)? onProgress,
  }) async {
    attempts.add(task.id);

    onProgress?.call(
      UploadProgress(
        bytesTransferred: task.sizeBytes ~/ 2,
        totalBytes: task.sizeBytes,
        throughputBytesPerSecond: 1024 * 1024,
      ),
    );

    final List<Failure?>? script = _scripts[task.id];
    final Failure? failure =
        (script != null && script.isNotEmpty) ? script.removeAt(0) : _defaultFailure;

    if (failure != null) return Result<void>.failure(failure);
    return const Result<void>.success(null);
  }

  @override
  Future<void> cancel(String taskId) async {}
}

/// A link the test drives by hand.
class FakeConnectivity implements ConnectivityPort {
  FakeConnectivity([this.quality = LinkQuality.stable]);

  LinkQuality quality;

  final StreamController<LinkStatus> _controller =
      StreamController<LinkStatus>.broadcast();

  void emit(LinkQuality value) {
    quality = value;
    _controller.add(
      LinkStatus(
        quality: value,
        transport: value == LinkQuality.offline
            ? LinkTransport.none
            : LinkTransport.wifi,
        observedAt: DateTime(2026, 8, 28),
      ),
    );
  }

  @override
  Future<LinkStatus> current() async => LinkStatus(
        quality: quality,
        transport:
            quality == LinkQuality.offline ? LinkTransport.none : LinkTransport.wifi,
        observedAt: DateTime(2026, 8, 28),
      );

  @override
  Stream<LinkStatus> watch() => _controller.stream;

  Future<void> dispose() => _controller.close();
}

/// Records what the engine asked the OS to do.
class RecordingScheduler implements BackgroundSchedulerPort {
  int periodicRegistrations = 0;
  final List<String> connectedRequests = <String>[];
  int cancellations = 0;

  @override
  Future<void> ensurePeriodicSyncScheduled() async => periodicRegistrations++;

  @override
  Future<void> requestSyncWhenConnected({String? reason}) async =>
      connectedRequests.add(reason ?? 'unspecified');

  @override
  Future<void> cancelAll() async => cancellations++;
}

// ---------------------------------------------------------------- capture

class FakePermissionGateway implements PermissionGateway {
  FakePermissionGateway({
    this.status = PermissionOutcome.granted,
    this.requestResult,
  });

  PermissionOutcome status;
  PermissionOutcome? requestResult;

  int requestCount = 0;
  int openSettingsCount = 0;

  @override
  Future<PermissionOutcome> cameraStatus() async => status;

  @override
  Future<PermissionOutcome> requestCamera() async {
    requestCount++;
    final PermissionOutcome outcome = requestResult ?? status;
    status = outcome;
    return outcome;
  }

  @override
  Future<bool> openSettings() async {
    openSettingsCount++;
    return true;
  }
}

const CameraLens wideLens = CameraLens(
  id: 'back-0',
  zoomFactor: 1,
  label: '1',
  kind: CameraLensKind.wide,
);

const CameraLens ultraWideLens = CameraLens(
  id: 'back-1',
  zoomFactor: 0.5,
  label: '0.5',
  kind: CameraLensKind.ultraWide,
);

CameraSession sessionFor(
  CameraLens lens, {
  double zoom = 1,
  double minZoom = 1,
  double maxZoom = 8,
  int previewKey = 1,
}) =>
    CameraSession(
      previewAspectRatio: 0.5625,
      settings: CameraSettings(zoom: zoom, minZoom: minZoom, maxZoom: maxZoom),
      availableLenses: <CameraLens>[ultraWideLens, wideLens],
      activeLens: lens,
      previewKey: previewKey,
    );

/// A camera that never touches hardware.
class FakeCamera implements CameraPort {
  FakeCamera();

  Failure? initialiseFailure;
  Failure? captureFailure;
  Failure? zoomFailure;

  CameraSession session = sessionFor(wideLens);

  int initialiseCount = 0;
  int disposeCount = 0;
  int captureCount = 0;
  final List<double> zoomCalls = <double>[];
  final List<FocusPoint> focusCalls = <FocusPoint>[];
  final List<CameraLens> lensCalls = <CameraLens>[];

  @override
  Future<Result<CameraSession>> initialise() async {
    initialiseCount++;
    final Failure? failure = initialiseFailure;
    if (failure != null) return Result<CameraSession>.failure(failure);
    return Result<CameraSession>.success(session);
  }

  @override
  Future<Result<CameraSession>> selectLens(CameraLens lens) async {
    lensCalls.add(lens);
    session = sessionFor(lens, previewKey: session.previewKey + 1);
    return Result<CameraSession>.success(session);
  }

  @override
  Future<Result<void>> setZoom(double zoom) async {
    zoomCalls.add(zoom);
    final Failure? failure = zoomFailure;
    if (failure != null) return Result<void>.failure(failure);
    return const Result<void>.success(null);
  }

  @override
  Future<Result<void>> setFlashMode(CaptureFlashMode mode) async =>
      const Result<void>.success(null);

  @override
  Future<Result<void>> focusAt(FocusPoint point) async {
    focusCalls.add(point);
    return const Result<void>.success(null);
  }

  @override
  Future<Result<CapturedShot>> capture({required double zoomLevel}) async {
    captureCount++;
    final Failure? failure = captureFailure;
    if (failure != null) return Result<CapturedShot>.failure(failure);

    return Result<CapturedShot>.success(
      CapturedShot(
        id: 'shot-$captureCount',
        filePath: '/tmp/shot-$captureCount.jpg',
        displayName: 'HARBOR_$captureCount.jpg',
        sizeBytes: 1024 * 1024,
        capturedAt: DateTime(2026, 8, 28, 9, captureCount),
        lensLabel: '1',
        zoomLevel: zoomLevel,
      ),
    );
  }

  @override
  Future<void> dispose() async => disposeCount++;
}

/// Builds an [UploadTask] with sensible defaults, so a test states only the
/// field it actually cares about.
UploadTask taskFixture({
  String id = 'task-1',
  String batchId = 'batch-1',
  int sizeBytes = 1024 * 1024,
  UploadStatus status = UploadStatus.queued,
  int attempt = 0,
  int maxAttempts = 5,
  DateTime? createdAt,
  DateTime? nextAttemptAt,
  int bytesTransferred = 0,
}) =>
    UploadTask(
      id: id,
      batchId: batchId,
      filePath: '/tmp/$id.jpg',
      displayName: '$id.jpg',
      sizeBytes: sizeBytes,
      createdAt: createdAt ?? DateTime(2026, 8, 28, 9),
      status: status,
      attempt: attempt,
      maxAttempts: maxAttempts,
      bytesTransferred: bytesTransferred,
      nextAttemptAt: nextAttemptAt,
    );
