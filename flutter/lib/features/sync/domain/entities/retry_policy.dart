import 'dart:math';

import 'package:equatable/equatable.dart';

/// Exponential backoff with full jitter.
///
/// Why jitter matters here: a batch of twelve photographs all fail together
/// the moment a tunnel swallows the signal. With plain exponential backoff all
/// twelve wake at exactly the same millisecond, hit the server together, and
/// - if the server was the problem - knock it over again. Randomising each
/// delay across `[0, computed]` spreads the herd. This is the "full jitter"
/// variant, which minimises both collision and total wait.
///
/// The [Random] is injected so the policy is deterministic under test; the
/// production default is seeded by the platform.
class RetryPolicy extends Equatable {
  const RetryPolicy({
    this.baseDelay = const Duration(seconds: 4),
    this.multiplier = 2.0,
    this.maxDelay = const Duration(minutes: 15),
    this.maxAttempts = 5,
  });

  final Duration baseDelay;
  final double multiplier;
  final Duration maxDelay;
  final int maxAttempts;

  /// Delay before attempt number [attempt] (1-based).
  ///
  /// attempt 1 -> up to 4s, 2 -> up to 8s, 3 -> up to 16s, 4 -> up to 32s ...
  /// capped at [maxDelay].
  Duration delayForAttempt(int attempt, {Random? random}) {
    if (attempt <= 0) return Duration.zero;

    final double exponential =
        baseDelay.inMilliseconds * pow(multiplier, attempt - 1).toDouble();
    final int capped = min(exponential.round(), maxDelay.inMilliseconds);

    final Random source = random ?? Random();
    // Full jitter: uniform in [0, capped]. `nextInt` needs a positive bound.
    return Duration(milliseconds: capped <= 0 ? 0 : source.nextInt(capped + 1));
  }

  bool hasAttemptsLeft(int attemptsSpent) => attemptsSpent < maxAttempts;

  @override
  List<Object?> get props => <Object?>[baseDelay, multiplier, maxDelay, maxAttempts];
}
