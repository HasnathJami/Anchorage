import 'dart:async';

import 'package:anchorage_harbor/app/anchorage_harbor_app.dart';
import 'package:anchorage_harbor/background/sync_worker.dart';
import 'package:anchorage_harbor/di/injector.dart';
import 'package:anchorage_harbor/data/services/connectivity_monitor.dart';
import 'package:anchorage_harbor/domain/services/sync_ports.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';

/// Cold-start sequence.
///
/// The order is not arbitrary:
///
///  1. Bindings first - everything after this touches a platform channel.
///  2. The object graph - so the connectivity monitor and the queue exist
///     before anything asks for them.
///  3. WorkManager - registered before the first UI frame so a sweep triggered
///     by the OS while we are starting up has somewhere to land.
///  4. The connectivity monitor's settle window starts running now, which
///     means the link is usually already trusted by the time the user reaches
///     the Upload Manager, instead of showing "unstable" for three seconds.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    // Portrait-only: the reference design is a portrait camera, and rotating
    // a live preview mid-capture is a well-known source of dropped frames and
    // wrongly-oriented JPEGs.
    DeviceOrientation.portraitUp,
  ]);

  await Injector.configure();

  await _initialiseBackgroundSync();

  // Fire and forget: the monitor publishes its first observation immediately
  // and promotes to "stable" three seconds later, so blocking the first frame
  // on it would only delay the UI.
  unawaited(getIt<ConnectivityMonitor>().start());

  runApp(const AnchorageHarborApp());
}

Future<void> _initialiseBackgroundSync() async {
  try {
    await Workmanager().initialize(
      syncCallbackDispatcher,
    );
    await getIt<BackgroundSchedulerPort>().ensurePeriodicSyncScheduled();
  } catch (error) {
    // Background execution is a resilience *enhancement*. If the platform
    // refuses it (an unsupported OEM, a restricted work profile), the app must
    // still run and sync in the foreground rather than fail to start.
    debugPrint('Harbor: background sync unavailable - $error');
  }
}
