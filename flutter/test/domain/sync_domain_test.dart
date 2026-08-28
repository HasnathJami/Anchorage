import 'dart:math';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/domain/entities/batch_progress.dart';
import 'package:anchorage_harbor/domain/entities/retry_policy.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  group('RetryPolicy', () {
    const RetryPolicy policy = RetryPolicy(
      baseDelay: Duration(seconds: 4),
      maxDelay: Duration(minutes: 15),
    );

    test('the first attempt has no delay', () {
      expect(policy.delayForAttempt(0), Duration.zero);
    });

    test('delay grows exponentially with the attempt number', () {
      // Full jitter picks uniformly in [0, computed], so the *ceiling* is what
      // the schedule guarantees - assert on that rather than on a sample.
      Duration ceiling(int attempt) => Duration(
            milliseconds: (4000 * pow(2, attempt - 1)).round(),
          );

      for (int attempt = 1; attempt <= 4; attempt++) {
        final Duration delay = policy.delayForAttempt(attempt, random: Random(3));
        expect(delay, lessThanOrEqualTo(ceiling(attempt)));
        expect(delay, greaterThanOrEqualTo(Duration.zero));
      }
    });

    test('delay is capped', () {
      final Duration delay = policy.delayForAttempt(40, random: Random(3));

      expect(delay, lessThanOrEqualTo(const Duration(minutes: 15)));
    });

    test('jitter actually varies, so a herd does not retry in lockstep', () {
      final Set<int> observed = <int>{
        for (int seed = 0; seed < 12; seed++)
          policy.delayForAttempt(5, random: Random(seed)).inMilliseconds,
      };

      expect(observed.length, greaterThan(1));
    });

    test('the attempt budget is respected', () {
      const RetryPolicy budget = RetryPolicy(maxAttempts: 3);

      expect(budget.hasAttemptsLeft(2), isTrue);
      expect(budget.hasAttemptsLeft(3), isFalse);
    });
  });

  group('UploadTask', () {
    test('progress is a clamped fraction of the file size', () {
      final UploadTask task = taskFixture(sizeBytes: 1000, bytesTransferred: 250);

      expect(task.progress, 0.25);
    });

    test('a zero-byte file reports zero rather than dividing by zero', () {
      expect(taskFixture(sizeBytes: 0).progress, 0);
    });

    test('readiness respects the backoff deadline', () {
      final DateTime now = DateTime(2026, 8, 28, 10);

      expect(taskFixture().isReadyAt(now), isTrue);
      expect(
        taskFixture(nextAttemptAt: now.add(const Duration(minutes: 1)))
            .isReadyAt(now),
        isFalse,
      );
      expect(
        taskFixture(nextAttemptAt: now.subtract(const Duration(minutes: 1)))
            .isReadyAt(now),
        isTrue,
      );
    });

    test('only the pickup-eligible statuses are eligible', () {
      expect(UploadStatus.queued.isEligibleForPickup, isTrue);
      expect(UploadStatus.waitingForConnection.isEligibleForPickup, isTrue);
      expect(UploadStatus.retrying.isEligibleForPickup, isTrue);

      expect(UploadStatus.uploading.isEligibleForPickup, isFalse);
      expect(UploadStatus.paused.isEligibleForPickup, isFalse);
      expect(UploadStatus.synced.isEligibleForPickup, isFalse);
      expect(UploadStatus.failed.isEligibleForPickup, isFalse);
    });

    test('copyWith can explicitly clear the backoff', () {
      final UploadTask task =
          taskFixture(nextAttemptAt: DateTime(2026, 8, 28, 11));

      expect(task.copyWith(clearNextAttemptAt: true).nextAttemptAt, isNull);
    });
  });

  group('BatchProgress', () {
    test('is measured in bytes, not item count', () {
      // One large file and three small ones: finishing the small ones must not
      // read as most of the way done.
      final List<UploadTask> tasks = <UploadTask>[
        taskFixture(id: 'big', sizeBytes: 1000),
        taskFixture(id: 's1', sizeBytes: 10, status: UploadStatus.synced),
        taskFixture(id: 's2', sizeBytes: 10, status: UploadStatus.synced),
        taskFixture(id: 's3', sizeBytes: 10, status: UploadStatus.synced),
      ];

      final BatchProgress progress = BatchProgress.from(tasks);

      expect(progress.syncedTasks, 3);
      expect(progress.percent, 3, reason: '30 of 1030 bytes');
    });

    test('a synced task counts its full size even without a final tick', () {
      final BatchProgress progress = BatchProgress.from(<UploadTask>[
        taskFixture(sizeBytes: 500, bytesTransferred: 100, status: UploadStatus.synced),
      ]);

      expect(progress.uploadedBytes, 500);
      expect(progress.isComplete, isTrue);
    });

    test('an empty queue is zero rather than NaN', () {
      final BatchProgress progress = BatchProgress.from(<UploadTask>[]);

      expect(progress.fraction, 0);
      expect(progress.percent, 0);
      expect(progress.isComplete, isFalse);
    });

    test('sums the throughput of active transfers only', () {
      final BatchProgress progress = BatchProgress.from(<UploadTask>[
        taskFixture(id: 'a', status: UploadStatus.uploading)
            .copyWith(throughputBytesPerSecond: 1000),
        taskFixture(id: 'b', status: UploadStatus.retrying)
            .copyWith(throughputBytesPerSecond: 9999),
      ]);

      expect(progress.activeThroughputBytesPerSecond, 1000);
    });
  });

  group('Failure retryability', () {
    test('transport problems are retryable', () {
      expect(const NoConnectionFailure().isRetryable, isTrue);
      expect(const LowBandwidthFailure().isRetryable, isTrue);
      expect(const TimeoutFailure().isRetryable, isTrue);
      expect(const ServerFailure(503).isRetryable, isTrue);
    });

    test('client errors and missing files are not', () {
      expect(const ServerFailure(400, isRetryable: false).isRetryable, isFalse);
      expect(const MissingArtifactFailure('/gone').isRetryable, isFalse);
      expect(
        const PermissionDeniedFailure(AppPermission.camera).isRetryable,
        isFalse,
      );
    });

    test('only network faults count as connectivity-related', () {
      expect(const NoConnectionFailure().isConnectivityRelated, isTrue);
      expect(const LowBandwidthFailure().isConnectivityRelated, isTrue);
      expect(const TimeoutFailure().isConnectivityRelated, isFalse);
      expect(const ServerFailure(503).isConnectivityRelated, isFalse);
    });
  });
}
