import 'package:anchorage_harbor/core/di/injector.dart';
import 'package:anchorage_harbor/features/sync/data/services/connectivity_monitor.dart';
import 'package:anchorage_harbor/features/sync/data/services/workmanager_scheduler.dart';
import 'package:anchorage_harbor/features/sync/domain/usecases/process_upload_queue.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

/// The background half of the sync engine.
///
/// This function runs in a **separate isolate** that WorkManager spawns after
/// the app may have been dead for hours. Three consequences drive everything
/// below, and each one is a common source of "works in debug, silently does
/// nothing in release" bugs:
///
///  1. **The isolate starts empty.** No `main()` has run, no service locator
///     exists, no plugin is registered. `ensureInitialized()` and a fresh
///     `Injector.configure()` are mandatory, not defensive.
///  2. **There is no widget tree.** Nothing here may touch a Bloc, a context
///     or a `setState`. It calls the same [ProcessUploadQueue] use case the UI
///     calls - which is exactly why that use case was built with no UI
///     dependency.
///  3. **The return value is a contract with the OS.** `true` means "done",
///     `false` means "retry me with backoff". Returning `true` after a failure
///     tells Android the work succeeded and it will not wake us again; that
///     single mistake is what makes most background-sync implementations
///     quietly stop working after the first bad network.
///
/// Background scheduling is disabled inside the isolate itself
/// (`enableBackgroundScheduling: false`): asking WorkManager to schedule more
/// work from inside a WorkManager task is how you build an accidental
/// wake-up loop. Rescheduling is expressed by the return value instead.
@pragma('vm:entry-point')
void syncCallbackDispatcher() {
  Workmanager().executeTask((String task, Map<String, dynamic>? inputData) async {
    WidgetsFlutterBinding.ensureInitialized();

    try {
      await Injector.configure(enableBackgroundScheduling: false);

      // Sample the link directly - the monitor has no history in a cold
      // isolate, and WorkManager only launched us because its network
      // constraint was already satisfied.
      await getIt<ConnectivityMonitor>().start();

      final ProcessUploadQueue processQueue = getIt<ProcessUploadQueue>();
      final report = await processQueue();

      return report.fold(
        (SyncSweepReport sweep) {
          debugPrint(
            'Harbor[$task]: attempted=${sweep.attempted} '
            'ok=${sweep.succeeded} parked=${sweep.parkedForConnectivity} '
            'retry=${sweep.scheduledForRetry} failed=${sweep.permanentlyFailed}',
          );

          // Ask the OS to come back only while work genuinely remains. The
          // periodic task ([SyncTasks.periodicSweep]) is the long-term safety
          // net and always reports success so its own cadence is preserved.
          if (task == SyncTasks.periodicSweep) return true;
          return !sweep.shouldReschedule;
        },
        (failure) {
          debugPrint('Harbor[$task]: sweep failed - $failure');
          return false;
        },
      );
    } catch (error, stackTrace) {
      // A throw here would be reported to the OS as a crash and can get the
      // app's background execution throttled, so nothing escapes.
      debugPrint('Harbor[$task]: unexpected background error - $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    }
  });
}
