import 'package:anchorage_harbor/data/datasources/camera_plugin_adapter.dart';
import 'package:anchorage_harbor/data/datasources/mock_upload_api.dart';
import 'package:anchorage_harbor/data/datasources/upload_queue_database.dart';
import 'package:anchorage_harbor/data/repositories/upload_queue_repository_impl.dart';
import 'package:anchorage_harbor/data/services/connectivity_monitor.dart';
import 'package:anchorage_harbor/data/services/permission_handler_gateway.dart';
import 'package:anchorage_harbor/data/services/workmanager_scheduler.dart';
import 'package:anchorage_harbor/domain/entities/retry_policy.dart';
import 'package:anchorage_harbor/domain/repositories/upload_queue_repository.dart';
import 'package:anchorage_harbor/domain/services/camera_port.dart';
import 'package:anchorage_harbor/domain/services/permission_gateway.dart';
import 'package:anchorage_harbor/domain/services/sync_ports.dart';
import 'package:anchorage_harbor/domain/usecases/process_upload_queue.dart';
import 'package:anchorage_harbor/domain/usecases/sync_use_cases.dart';
import 'package:get_it/get_it.dart';
import 'package:uuid/uuid.dart';

// ── THE COMPOSITION ROOT ─────────────────────────────────────────────────
//
// The one place that decides which real class stands behind each interface.
// If you want to know what this app is actually made of, read this file.
//
//   asked for                  gets built as
//   ──────────────────────────────────────────────────────────
//   UploadQueueRepository  →   UploadQueueRepositoryImpl  (SQLite)
//   UploaderPort           →   MockUploadApi              (or HttpUploadApi)
//   ConnectivityPort       →   ConnectivityMonitor
//   BackgroundSchedulerPort→   WorkManagerScheduler       (or a no-op)
//   CameraPort             →   CameraPluginAdapter
//
// WRITTEN BY HAND, NOT GENERATED, on purpose. A generated container hides the
// wiring order, and the wiring order is exactly where the interesting
// decisions live: which transport is real, whether background scheduling is
// on, how long a link must hold before it counts as stable. All of that
// should be visible in one readable file to anyone auditing the app.
//
// EVERY BINDING IS AGAINST AN INTERFACE. That is what lets the whole sync
// engine be tested with fakes, and what makes going live a ONE-LINE change -
// see the "Transport" section below.
//
// `registerLazySingleton` means "build it the first time somebody asks, then
// reuse it". Nothing here is constructed at startup, so none of it costs
// launch time.

/// The service locator.
final GetIt getIt = GetIt.instance;

/// Builds the object graph. See the file banner above for the full picture.
///
/// Call [configure] once at startup, before anything asks [getIt] for
/// something.
abstract final class Injector {
  static Future<void> configure({
    bool enableBackgroundScheduling = true,
    MockUploadBehaviour mockBehaviour = MockUploadBehaviour.succeed,
  }) async {
    if (getIt.isRegistered<UploadQueueRepository>()) return;

    // --- Foundational -----------------------------------------------------
    getIt
      ..registerLazySingleton<Uuid>(() => const Uuid())
      ..registerLazySingleton<PermissionGateway>(
        () => const PermissionHandlerGateway(),
      );

    // --- Connectivity -----------------------------------------------------
    // Registered as a concrete type as well, so `main` can `start()` it
    // without the port having to expose lifecycle methods it does not own.
    getIt
      ..registerLazySingleton<ConnectivityMonitor>(ConnectivityMonitor.new)
      ..registerLazySingleton<ConnectivityPort>(() => getIt<ConnectivityMonitor>());

    // --- Persistence ------------------------------------------------------
    getIt
      ..registerLazySingleton<UploadQueueDatabase>(UploadQueueDatabase.new)
      ..registerLazySingleton<UploadQueueRepository>(
        () => UploadQueueRepositoryImpl(database: getIt<UploadQueueDatabase>()),
      );

    // --- Transport --------------------------------------------------------
    // The one line that would change to go live:
    //   () => HttpUploadApi(baseUri: Uri.parse(Env.apiBaseUrl))
    getIt.registerLazySingleton<UploaderPort>(
      () => MockUploadApi(
        behaviour: mockBehaviour,
        connectivity: getIt<ConnectivityPort>(),
      ),
    );
    // Also exposed concretely so the in-app demo panel can change the mock's
    // behaviour at runtime. Debug affordance only; nothing in the engine
    // depends on it.
    getIt.registerLazySingleton<MockUploadApi>(
      () => getIt<UploaderPort>() as MockUploadApi,
    );

    // --- Background -------------------------------------------------------
    getIt.registerLazySingleton<BackgroundSchedulerPort>(
      () => enableBackgroundScheduling
          ? WorkManagerScheduler()
          : const NoopBackgroundScheduler(),
    );

    // --- Camera -----------------------------------------------------------
    getIt
      ..registerLazySingleton<CameraPluginAdapter>(
        () => CameraPluginAdapter(uuid: getIt<Uuid>()),
      )
      ..registerLazySingleton<CameraPort>(() => getIt<CameraPluginAdapter>());

    // --- Policy -----------------------------------------------------------
    getIt.registerLazySingleton<RetryPolicy>(() => const RetryPolicy());

    // --- Use cases --------------------------------------------------------
    getIt
      ..registerLazySingleton<ProcessUploadQueue>(
        () => ProcessUploadQueue(
          repository: getIt<UploadQueueRepository>(),
          uploader: getIt<UploaderPort>(),
          connectivity: getIt<ConnectivityPort>(),
          scheduler: getIt<BackgroundSchedulerPort>(),
          retryPolicy: getIt<RetryPolicy>(),
        ),
      )
      ..registerLazySingleton<EnqueueBatch>(
        () => EnqueueBatch(
          repository: getIt<UploadQueueRepository>(),
          scheduler: getIt<BackgroundSchedulerPort>(),
        ),
      )
      ..registerLazySingleton<WatchUploadQueue>(
        () => WatchUploadQueue(getIt<UploadQueueRepository>()),
      )
      ..registerLazySingleton<PauseAllUploads>(
        () => PauseAllUploads(getIt<UploadQueueRepository>()),
      )
      ..registerLazySingleton<ResumeAllUploads>(
        () => ResumeAllUploads(
          repository: getIt<UploadQueueRepository>(),
          scheduler: getIt<BackgroundSchedulerPort>(),
        ),
      )
      ..registerLazySingleton<RetryFailedUploads>(
        () => RetryFailedUploads(
          repository: getIt<UploadQueueRepository>(),
          scheduler: getIt<BackgroundSchedulerPort>(),
        ),
      )
      ..registerLazySingleton<RetryUpload>(
        () => RetryUpload(
          repository: getIt<UploadQueueRepository>(),
          scheduler: getIt<BackgroundSchedulerPort>(),
        ),
      )
      ..registerLazySingleton<DiscardUpload>(
        () => DiscardUpload(getIt<UploadQueueRepository>()),
      )
      ..registerLazySingleton<ClearSyncedUploads>(
        () => ClearSyncedUploads(getIt<UploadQueueRepository>()),
      );
  }

  /// Tears the graph down. Used by tests between cases.
  static Future<void> reset() => getIt.reset();
}
