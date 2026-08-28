import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/di/injector.dart';
import 'package:anchorage_harbor/domain/services/permission_gateway.dart';
import 'package:anchorage_harbor/domain/services/camera_port.dart';
import 'package:anchorage_harbor/presentation/capture/bloc/camera_bloc.dart';
import 'package:anchorage_harbor/presentation/capture/pages/camera_preview_page.dart';
import 'package:anchorage_harbor/domain/services/sync_ports.dart';
import 'package:anchorage_harbor/domain/usecases/process_upload_queue.dart';
import 'package:anchorage_harbor/domain/usecases/sync_use_cases.dart';
import 'package:anchorage_harbor/presentation/sync/bloc/upload_manager_bloc.dart';
import 'package:anchorage_harbor/presentation/sync/pages/upload_manager_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Route names, in one place so a typo is caught at the call site.
abstract final class HarborRoutes {
  static const String camera = '/';
  static const String uploads = '/uploads';
}

/// The application shell.
///
/// [UploadManagerBloc] is hoisted above the navigator on purpose: the sync
/// engine must keep watching the network and draining the queue while the user
/// is on the camera screen, and a Bloc scoped to the Upload Manager route would
/// be disposed the moment they navigated away - exactly when a long batch needs
/// it most. The camera Bloc, by contrast, is scoped to its route so the sensor
/// is released when that screen leaves the stack.
class AnchorageHarborApp extends StatelessWidget {
  const AnchorageHarborApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<UploadManagerBloc>(
      create: (_) => UploadManagerBloc(
        watchQueue: getIt<WatchUploadQueue>(),
        processQueue: getIt<ProcessUploadQueue>(),
        connectivity: getIt<ConnectivityPort>(),
        pauseAll: getIt<PauseAllUploads>(),
        resumeAll: getIt<ResumeAllUploads>(),
        retryUpload: getIt<RetryUpload>(),
        discardUpload: getIt<DiscardUpload>(),
        clearSynced: getIt<ClearSyncedUploads>(),
      )..add(const UploadManagerStarted()),
      child: MaterialApp(
        title: 'Anchorage Harbor',
        debugShowCheckedModeBanner: false,
        theme: HarborTheme.build(),
        initialRoute: HarborRoutes.camera,
        routes: <String, WidgetBuilder>{
          HarborRoutes.camera: (BuildContext context) => BlocProvider<CameraBloc>(
                create: (_) => CameraBloc(
                  camera: getIt<CameraPort>(),
                  permissions: getIt<PermissionGateway>(),
                  enqueueBatch: getIt<EnqueueBatch>(),
                )..add(const CameraStarted()),
                child: const CameraPreviewPage(),
              ),
          HarborRoutes.uploads: (BuildContext context) => const UploadManagerPage(),
        },
      ),
    );
  }
}
