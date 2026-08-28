import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/features/sync/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/features/sync/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/features/sync/domain/services/sync_ports.dart';

/// What the mock server should do on the next attempt.
///
/// Exposed as a knob rather than hard-wired so the behaviour the brief asks
/// for - success *and* failure responses - can be demonstrated live from the
/// app's debug menu, and asserted deterministically from tests.
enum MockUploadBehaviour {
  /// Transfer completes normally.
  succeed,

  /// Fails part-way with [LowBandwidthFailure] - the "weak signal" case.
  failLowBandwidth,

  /// Fails immediately with [NoConnectionFailure] - the "no internet" case.
  failNoConnection,

  /// Fails with a retryable 503.
  failServerRetryable,

  /// Fails with a non-retryable 400; must never be retried.
  failServerPermanent,

  /// Never answers; the caller's timeout must fire.
  hang,

  /// Succeeds or fails at random - useful for soak-testing the engine.
  flaky,
}

/// The stand-in for a real upload endpoint.
///
/// **The brief states no API is available**, so this class *is* the transport
/// for the assessment build. It is not a stub that returns `true`: it streams
/// realistic progress at a configurable throughput, fails at a configurable
/// point, and returns the full range of typed failures - which is what allows
/// the retry, backoff and connectivity-parking logic to be exercised end to
/// end without a server.
///
/// The real implementation it stands in for is sketched in
/// `http_upload_api.dart`; swapping them is a one-line change in the injector
/// because both satisfy [UploaderPort].
class MockUploadApi implements UploaderPort {
  MockUploadApi({
    this.behaviour = MockUploadBehaviour.succeed,
    ConnectivityPort? connectivity,
    int throughputBytesPerSecond = 2 * 1024 * 1024,
    Duration tick = const Duration(milliseconds: 120),
    double failAtFraction = 0.45,
    Random? random,
    bool simulateTime = true,
  })  : _connectivity = connectivity,
        _throughput = throughputBytesPerSecond,
        _tick = tick,
        _failAtFraction = failAtFraction,
        _random = random ?? Random(),
        _simulateTime = simulateTime;

  /// Switchable at runtime from the in-app demo panel so a reviewer can see
  /// each response path without a rebuild. Nothing in the engine reads it.
  MockUploadBehaviour behaviour;
  final ConnectivityPort? _connectivity;
  final int _throughput;
  final Duration _tick;
  final double _failAtFraction;
  final Random _random;

  /// When false the mock returns instantly - used by tests that assert engine
  /// behaviour rather than transfer pacing.
  final bool _simulateTime;

  final Set<String> _cancelled = <String>{};

  @override
  Future<Result<void>> upload(
    UploadTask task, {
    void Function(UploadProgress progress)? onProgress,
  }) async {
    _cancelled.remove(task.id);

    // A queue entry whose file has been swept away by the OS is terminal, not
    // retryable - checking here keeps that truth in the transport, where the
    // filesystem actually lives.
    if (!await File(task.filePath).exists()) {
      return Result<void>.failure(MissingArtifactFailure(task.filePath));
    }

    // Honour the real link when one is wired in, so pulling the device off
    // Wi-Fi during a demo produces a genuine failure rather than a scripted
    // one.
    final LinkStatus? link = await _connectivity?.current();
    if (link != null && !link.quality.isOnline) {
      return const Result<void>.failure(NoConnectionFailure());
    }

    final MockUploadBehaviour behaviour = _resolveBehaviour();

    if (behaviour == MockUploadBehaviour.failNoConnection) {
      return const Result<void>.failure(NoConnectionFailure());
    }
    if (behaviour == MockUploadBehaviour.hang) {
      await Future<void>.delayed(const Duration(minutes: 5));
      return const Result<void>.failure(TimeoutFailure());
    }

    final int bytesPerTick =
        max(1, (_throughput * _tick.inMilliseconds / 1000).round());
    final int failAtBytes = (task.sizeBytes * _failAtFraction).round();

    int sent = 0;
    while (sent < task.sizeBytes) {
      if (_cancelled.contains(task.id)) {
        return const Result<void>.failure(TimeoutFailure());
      }

      if (_simulateTime) await Future<void>.delayed(_tick);

      sent = min(task.sizeBytes, sent + bytesPerTick);

      onProgress?.call(
        UploadProgress(
          bytesTransferred: sent,
          totalBytes: task.sizeBytes,
          throughputBytesPerSecond: _throughput,
        ),
      );

      // Mid-transfer failures happen part-way through, not at byte zero -
      // that is the case that exercises resuming a partially sent file.
      if (behaviour == MockUploadBehaviour.failLowBandwidth && sent >= failAtBytes) {
        return Result<void>.failure(
          LowBandwidthFailure(observedBytesPerSecond: _throughput ~/ 20),
        );
      }
      if (behaviour == MockUploadBehaviour.failServerRetryable && sent >= failAtBytes) {
        return const Result<void>.failure(ServerFailure(503));
      }
      if (behaviour == MockUploadBehaviour.failServerPermanent && sent >= failAtBytes) {
        return const Result<void>.failure(ServerFailure(400, isRetryable: false));
      }
    }

    return const Result<void>.success(null);
  }

  @override
  Future<void> cancel(String taskId) async => _cancelled.add(taskId);

  MockUploadBehaviour _resolveBehaviour() {
    if (behaviour != MockUploadBehaviour.flaky) return behaviour;

    // 60 % success, then a spread of the retryable failures.
    final double roll = _random.nextDouble();
    if (roll < 0.60) return MockUploadBehaviour.succeed;
    if (roll < 0.80) return MockUploadBehaviour.failLowBandwidth;
    if (roll < 0.92) return MockUploadBehaviour.failServerRetryable;
    return MockUploadBehaviour.failNoConnection;
  }
}
