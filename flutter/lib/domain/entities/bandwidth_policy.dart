import 'package:equatable/equatable.dart';

/// When a link that is technically up is too slow to be worth using.
///
/// "No internet" and "low bandwidth" are different failures with different
/// remedies, and only the first one the operating system will tell you about.
/// `connectivity_plus` reports a transport, not a speed: a phone on one bar of
/// GPRS, or on a hotel Wi-Fi behind a saturated uplink, is *connected* by every
/// signal Android exposes while a 300 KB photograph takes four minutes and
/// usually dies before it lands.
///
/// So bandwidth is not asked about, it is **measured** — from the bytes the
/// transport actually moves — and this class holds the one rule that reads
/// that measurement. It lives in the domain because it is a product decision
/// about what "too slow" means, not a property of any transport.
///
/// Being under the floor is not itself a failure: TCP slow-start, a lift, a
/// tunnel and a Wi-Fi roam all produce a second or two of nothing on a link
/// that is about to be fine. It has to *stay* under the floor for [grace]
/// before the transfer is given up on.
///
/// Giving up parks the task in `waitingForConnection` **without spending an
/// attempt** — the same treatment as no connection at all, because it is the
/// same situation: the network, not the file or the server, is the problem.
class BandwidthPolicy extends Equatable {
  const BandwidthPolicy({
    this.floorBytesPerSecond = 24 * 1024,
    this.grace = const Duration(seconds: 6),
  });

  /// The shipping configuration.
  static const BandwidthPolicy standard = BandwidthPolicy();

  /// Below this, a transfer is not worth continuing.
  ///
  /// 24 KB/s is roughly the point where a single evidence photograph stops
  /// arriving inside ten seconds, and where a batch of twelve becomes minutes
  /// of held-open sockets. It is deliberately well under a bad 3G connection:
  /// the floor is there to catch a link that is *failing*, not to refuse a
  /// slow one that is still making progress.
  final int floorBytesPerSecond;

  /// How long throughput must stay under the floor before the transfer is
  /// abandoned.
  final Duration grace;

  bool isTooSlow(int observedBytesPerSecond) =>
      observedBytesPerSecond < floorBytesPerSecond;

  /// Whether a transfer that has been under the floor for [slowFor] should be
  /// abandoned and parked.
  bool shouldPark({
    required int observedBytesPerSecond,
    required Duration slowFor,
  }) =>
      isTooSlow(observedBytesPerSecond) && slowFor >= grace;

  @override
  List<Object?> get props => <Object?>[floorBytesPerSecond, grace];
}
