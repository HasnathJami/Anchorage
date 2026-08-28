import 'package:equatable/equatable.dart';

/// How good the network link is *right now*.
///
/// The brief asks the engine to resume "once a stable connection is detected",
/// which means a boolean `isOnline` is not enough. Android reports a link the
/// instant a Wi-Fi association completes - several seconds before it can
/// actually carry traffic - so a naive `isConnected` listener starts an upload
/// straight into a failure and burns an attempt.
enum LinkQuality {
  /// No transport at all.
  offline,

  /// A transport exists but has not held long enough to be trusted, or is
  /// known to be poor. The engine will wait rather than spend an attempt.
  unstable,

  /// Held continuously for the settle window. Safe to start transfers.
  stable;

  bool get canTransfer => this == LinkQuality.stable;

  bool get isOnline => this != LinkQuality.offline;
}

/// A link observation with the transport that produced it.
class LinkStatus extends Equatable {
  const LinkStatus({
    required this.quality,
    required this.transport,
    required this.observedAt,
  });

  const LinkStatus.offline(this.observedAt)
      : quality = LinkQuality.offline,
        transport = LinkTransport.none;

  final LinkQuality quality;
  final LinkTransport transport;
  final DateTime observedAt;

  @override
  List<Object?> get props => <Object?>[quality, transport, observedAt];
}

enum LinkTransport { none, wifi, mobile, ethernet, other }
