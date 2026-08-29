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
    this.maxAttempts = defaultMaxAttempts,
  });

  /// How many times a task may be *attempted* before it is given up on.
  ///
  /// Three, not five. The number only ever counts attempts that were the
  /// task's own fault - a rejection from the server, a transport that broke
  /// for a reason the radio cannot explain. Losing the network does not
  /// consume one, and neither does a link too slow to carry the file: those
  /// park the row and cost nothing, however long they last. So the budget is
  /// spent only on failures that are *repeating for the same reason*, and by
  /// the third of those the fourth is not going to be the one that works. It
  /// is a better use of the user's battery and the server's patience to stop,
  /// say so, and offer a manual retry.
  ///
  /// The single source of truth: [UploadTask.defaultMaxAttempts] and the queue
  /// table's own column default both follow this, so a row's `2/3` label and
  /// the engine's decision to stop can never disagree.
  static const int defaultMaxAttempts = 3;

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
