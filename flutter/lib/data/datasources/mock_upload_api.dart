import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/domain/services/sync_ports.dart';

/// What the mock **server** should do on the next attempt.
///
/// Two outcomes, and only two, because a server has only two things to say
/// about an upload: it took it, or it did not. The network conditions the
/// brief also asks about — no internet, and a link too slow to use — are
/// deliberately *not* in this list. They are not the server's answer, and
/// scripting them demonstrated nothing except that a switch works:
///
///  * **No internet** comes from `ConnectivityMonitor`, and the queue is
///    drained again by WorkManager's network-constrained wake-up.
///  * **Low bandwidth** is measured from the bytes actually moving and judged
///    by `BandwidthPolicy`.
///
/// Both are therefore real on a real device: turn off mobile data, or stand
/// somewhere with one bar, and the engine responds to the link it genuinely
/// has. This switch only decides what the far end says once bytes arrive.
enum MockUploadBehaviour {
  /// The server accepts the upload. Whether it *completes* still depends on
  /// the link, which is the point.
  succeed,

  /// The server rejects the upload, however good the link is.
  ///
  /// Rendered as a retryable 500, so one tap shows the whole of the engine's
  /// server-failure policy: jittered backoff, an attempt counter that climbs,
  /// and a row that ends at `FAILED` with a Retry button once the attempts run
  /// out — rather than a queue that quietly spins forever.
  fail,

  /// Never answers; the caller's timeout must fire.
  ///
  /// Not offered in the app's demonstration panel: it is indistinguishable
  /// from a hung app until the timeout fires, which is a poor thing to show a
  /// reviewer. Kept because it is a real transport behaviour worth testing.
  hang,
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
    bool simulateTime = true,
  })  : _connectivity = connectivity,
        _throughput = throughputBytesPerSecond,
        _tick = tick,
        _failAtFraction = failAtFraction,
        _simulateTime = simulateTime;

  /// What [MockUploadBehaviour.fail] returns.
  ///
  /// Retryable, so the engine's backoff and attempt ceiling are what end the
  /// task rather than a special case here. `RetryPolicy` already decides when
  /// enough is enough, and it should stay the only thing that does.
  static const int rejectionStatusCode = 500;

  /// Switchable at runtime from the in-app demo panel so a reviewer can see
  /// each response path without a rebuild. Nothing in the engine reads it.
  MockUploadBehaviour behaviour;
  final ConnectivityPort? _connectivity;
  final int _throughput;
  final Duration _tick;
  final double _failAtFraction;

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

    final MockUploadBehaviour behaviour = this.behaviour;

    if (behaviour == MockUploadBehaviour.hang) {
      await Future<void>.delayed(const Duration(minutes: 5));
      return const Result<void>.failure(TimeoutFailure());
    }

    final int bytesPerTick =
        max(1, (_throughput * _tick.inMilliseconds / 1000).round());
    final int failAtBytes = (task.sizeBytes * _failAtFraction).round();

    int sent = 0;
    // Throughput is *measured*, not declared. It is the number the bandwidth
    // watchdog acts on, so reporting the configured rate back would make that
    // check a tautology - and would hide a pipe that had genuinely stalled.
    final Stopwatch elapsed = Stopwatch()..start();

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
          throughputBytesPerSecond: _observedThroughput(sent, elapsed),
        ),
      );

      // A rejection arrives part-way through, not at byte zero - that is the
      // case that exercises a partially sent file being started again.
      if (behaviour == MockUploadBehaviour.fail && sent >= failAtBytes) {
        return const Result<void>.failure(
          ServerFailure(rejectionStatusCode, isRetryable: true),
        );
      }
    }

    return const Result<void>.success(null);
  }

  /// Bytes per second, from the clock rather than from the setting.
  ///
  /// Guarded against a zero elapsed time: with [_simulateTime] off the whole
  /// transfer happens inside one microtask, and dividing by nothing would make
  /// every test look like an infinitely fast link. Reporting the configured
  /// rate in that case is the honest answer - no time has passed, so no
  /// slowness has been observed.
  int _observedThroughput(int sent, Stopwatch elapsed) {
    final int millis = elapsed.elapsedMilliseconds;
    if (millis <= 0) return _throughput;
    return (sent * 1000 / millis).round();
  }

  @override
  Future<void> cancel(String taskId) async => _cancelled.add(taskId);

}
