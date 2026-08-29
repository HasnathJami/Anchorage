import 'package:anchorage_harbor/domain/entities/bandwidth_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rules in [BandwidthPolicy]'s doc comment, one group each.
///
/// The reason this class exists at all: the operating system will tell you
/// there is a transport, and will not tell you it is useless. "Connected" and
/// "usable" are different questions, and only the second one decides whether a
/// photograph is going to arrive.
void main() {
  const BandwidthPolicy policy = BandwidthPolicy(
    floorBytesPerSecond: 24 * 1024,
    grace: Duration(seconds: 6),
  );

  group('the floor', () {
    test('a link under it is too slow', () {
      expect(policy.isTooSlow(1024), isTrue);
      expect(policy.isTooSlow(24 * 1024 - 1), isTrue);
    });

    test('a link at or above it is not', () {
      expect(policy.isTooSlow(24 * 1024), isFalse);
      expect(policy.isTooSlow(2 * 1024 * 1024), isFalse);
    });

    test('a stalled link is the worst case of a slow one, not a separate one',
        () {
      expect(policy.isTooSlow(0), isTrue);
    });
  });

  group('the grace window', () {
    test('a brief dip is not a collapse', () {
      // Slow-start, a lift, a Wi-Fi roam. Parking on the first slow tick would
      // abandon transfers that were about to be fine.
      expect(
        policy.shouldPark(
          observedBytesPerSecond: 500,
          slowFor: const Duration(seconds: 2),
        ),
        isFalse,
      );
    });

    test('staying slow for the whole window is', () {
      expect(
        policy.shouldPark(
          observedBytesPerSecond: 500,
          slowFor: const Duration(seconds: 6),
        ),
        isTrue,
      );
    });

    test('a fast link is never parked, however long it has been running', () {
      expect(
        policy.shouldPark(
          observedBytesPerSecond: 5 * 1024 * 1024,
          slowFor: const Duration(hours: 1),
        ),
        isFalse,
      );
    });
  });

  group('the shipping configuration', () {
    test('is well under a usable mobile link', () {
      // The floor catches a link that is failing, not one that is merely slow.
      // A bad but working 3G connection sits comfortably above it.
      expect(BandwidthPolicy.standard.isTooSlow(64 * 1024), isFalse);
      expect(BandwidthPolicy.standard.isTooSlow(2 * 1024), isTrue);
    });

    test('gives a transfer a few seconds before giving up on it', () {
      expect(
        BandwidthPolicy.standard.grace,
        greaterThanOrEqualTo(const Duration(seconds: 3)),
      );
    });
  });
}
