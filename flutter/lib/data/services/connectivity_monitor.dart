import 'dart:async';

import 'package:anchorage_harbor/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/domain/services/sync_ports.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Turns raw transport events into a trustworthy [LinkQuality].
///
/// The problem this solves is specific and easy to get wrong. `connectivity_plus`
/// reports a link the instant the OS associates with a network - typically
/// several seconds before that network can carry a byte (DHCP, captive-portal
/// checks, a train pulling out of a tunnel with one bar). An engine that starts
/// uploading on the first `connected` event fails immediately and burns a retry
/// attempt, every single time.
///
/// So a new link is admitted as [LinkQuality.unstable] and only promoted to
/// [LinkQuality.stable] after it has held continuously for [settleDuration].
/// Losing the link demotes it instantly - being pessimistic quickly and
/// optimistic slowly is the right asymmetry when the cost of a false
/// "stable" is a wasted attempt.
class ConnectivityMonitor implements ConnectivityPort {
  ConnectivityMonitor({
    Connectivity? connectivity,
    this.settleDuration = const Duration(seconds: 3),
    DateTime Function() clock = DateTime.now,
  })  : _connectivity = connectivity ?? Connectivity(),
        _clock = clock;

  final Connectivity _connectivity;
  final Duration settleDuration;
  final DateTime Function() _clock;

  final StreamController<LinkStatus> _controller =
      StreamController<LinkStatus>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _settleTimer;
  LinkStatus? _latest;

  /// Starts listening. Safe to call more than once.
  Future<void> start() async {
    if (_subscription != null) return;

    _publish(_evaluate(await _connectivity.checkConnectivity(), settled: false));

    _subscription = _connectivity.onConnectivityChanged.listen(
      (List<ConnectivityResult> results) =>
          _publish(_evaluate(results, settled: false)),
      onError: (Object _) => _publish(LinkStatus.offline(_clock())),
    );
  }

  Future<void> stop() async {
    _settleTimer?.cancel();
    _settleTimer = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  @override
  Stream<LinkStatus> watch() async* {
    await start();
    final LinkStatus? latest = _latest;
    if (latest != null) yield latest;
    yield* _controller.stream;
  }

  @override
  Future<LinkStatus> current() async {
    final LinkStatus? latest = _latest;
    if (latest != null) return latest;

    // No cached observation yet (a cold background worker): sample directly.
    // The sample is treated as stable, because a worker that WorkManager only
    // launched *because* its network constraint was satisfied has already had
    // the OS vouch for the link.
    return _evaluate(await _connectivity.checkConnectivity(), settled: true);
  }

  LinkStatus _evaluate(List<ConnectivityResult> results, {required bool settled}) {
    final ConnectivityResult effective = _pick(results);

    if (effective == ConnectivityResult.none) {
      return LinkStatus.offline(_clock());
    }

    return LinkStatus(
      quality: settled ? LinkQuality.stable : LinkQuality.unstable,
      transport: _toTransport(effective),
      observedAt: _clock(),
    );
  }

  void _publish(LinkStatus status) {
    _latest = status;
    if (!_controller.isClosed) _controller.add(status);

    _settleTimer?.cancel();
    if (status.quality != LinkQuality.unstable) return;

    // Promotion is scheduled, not immediate. If the link drops before the
    // timer fires, `_publish` cancels it and the promotion never happens.
    _settleTimer = Timer(settleDuration, () {
      final LinkStatus? current = _latest;
      if (current == null || current.quality != LinkQuality.unstable) return;

      final LinkStatus promoted = LinkStatus(
        quality: LinkQuality.stable,
        transport: current.transport,
        observedAt: _clock(),
      );
      _latest = promoted;
      if (!_controller.isClosed) _controller.add(promoted);
    });
  }

  /// Devices routinely report several transports at once (Wi-Fi plus mobile
  /// during a handover). Wired beats Wi-Fi beats mobile - the most capable
  /// link present is the one traffic will actually take.
  ConnectivityResult _pick(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.ethernet)) {
      return ConnectivityResult.ethernet;
    }
    if (results.contains(ConnectivityResult.wifi)) return ConnectivityResult.wifi;
    if (results.contains(ConnectivityResult.mobile)) return ConnectivityResult.mobile;
    if (results.contains(ConnectivityResult.vpn)) return ConnectivityResult.vpn;
    return ConnectivityResult.none;
  }

  LinkTransport _toTransport(ConnectivityResult result) => switch (result) {
        ConnectivityResult.wifi => LinkTransport.wifi,
        ConnectivityResult.mobile => LinkTransport.mobile,
        ConnectivityResult.ethernet => LinkTransport.ethernet,
        ConnectivityResult.none => LinkTransport.none,
        _ => LinkTransport.other,
      };

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
