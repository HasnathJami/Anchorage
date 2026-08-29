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

/// The service locator.
final GetIt getIt = GetIt.instance;

/// Composition root.
///
/// Written by hand rather than generated, on purpose. A generated container
/// hides the wiring order, and the wiring order is precisely where the
/// interesting decisions live here: which implementation stands behind
/// [UploaderPort], whether background scheduling is real or a no-op, and how
/// long a link must hold before it counts as stable. All of that should be
/// visible in one readable file to anyone auditing the app.
///
/// Every binding is against an *interface*. That is what lets the entire sync
/// engine be tested with fakes, and what makes swapping [MockUploadApi] for the
/// real HTTP transport a single-line change.
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
