import 'package:anchorage_harbor/domain/services/sync_ports.dart';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

/// Task identifiers. Constants, because a typo in a string passed to the OS
/// produces a job that silently never runs.
abstract final class SyncTasks {
  /// The safety net: runs on the OS's own schedule so a queue left behind by
  /// a killed app still drains.
  static const String periodicSweep = 'anchorage.harbor.sync.periodic';

  /// Fired when new work arrives, constrained to "when a network exists".
  static const String opportunisticSweep = 'anchorage.harbor.sync.opportunistic';

  static const String uniquePeriodicName = 'anchorage-harbor-periodic-sync';
}

/// [BackgroundSchedulerPort] on top of WorkManager.
///
/// Two jobs, for two different reasons:
///
///  * **Periodic** (15 min, the OS minimum) is the safety net. It exists for
///    the case the app is never opened again: photographs still leave the
///    device.
///  * **Opportunistic** is a one-shot with a `NetworkType.connected`
///    constraint. This is the piece that satisfies "automatically retry once a
///    stable connection is detected without user intervention" *properly* -
///    the OS itself watches the radio and wakes the app, which is far cheaper
///    and far more reliable than an in-process listener that dies with the
///    app.
///
/// `ExistingWorkPolicy.keep` on the one-shot is deliberate: enqueueing a batch
/// of twelve photographs must not schedule twelve wake-ups.
class WorkManagerScheduler implements BackgroundSchedulerPort {
  WorkManagerScheduler({Workmanager? workmanager})
      : _workmanager = workmanager ?? Workmanager();

  final Workmanager _workmanager;

  @override
  Future<void> ensurePeriodicSyncScheduled() async {
    try {
      await _workmanager.registerPeriodicTask(
        SyncTasks.uniquePeriodicName,
        SyncTasks.periodicSweep,
        frequency: const Duration(minutes: 15),
        // `keep` makes this idempotent: calling it on every cold start does
        // not reset the interval or stack duplicate jobs.
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 1),
      );
    } catch (error, stackTrace) {
      // A scheduling failure must never take the app down - the in-process
      // engine still works while the app is open.
      debugPrint('Harbor: periodic sync could not be scheduled: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  Future<void> requestSyncWhenConnected({String? reason}) async {
    try {
      await _workmanager.registerOneOffTask(
        // A stable unique name plus `keep` collapses a burst of requests
        // (twelve files enqueued at once) into a single scheduled wake-up.
        SyncTasks.opportunisticSweep,
        SyncTasks.opportunisticSweep,
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(seconds: 30),
        inputData: <String, dynamic>{'reason': reason ?? 'unspecified'},
      );
    } catch (error) {
      debugPrint('Harbor: opportunistic sync could not be scheduled: $error');
    }
  }

  @override
  Future<void> cancelAll() async {
    try {
      await _workmanager.cancelAll();
    } catch (error) {
      debugPrint('Harbor: could not cancel background work: $error');
    }
  }
}

/// A no-op scheduler for tests and for platforms where background execution is
/// unavailable. Returning a silent no-op is better than a null check at every
/// call site in the engine.
class NoopBackgroundScheduler implements BackgroundSchedulerPort {
  const NoopBackgroundScheduler();

  @override
  Future<void> ensurePeriodicSyncScheduled() async {}

  @override
  Future<void> requestSyncWhenConnected({String? reason}) async {}

  @override
  Future<void> cancelAll() async {}
}
