import 'dart:io';

import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/data/datasources/camera_plugin_adapter.dart';
import 'package:anchorage_harbor/di/injector.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/domain/usecases/process_upload_queue.dart';
import 'package:anchorage_harbor/domain/usecases/sync_use_cases.dart';
import 'package:anchorage_harbor/presentation/capture/bloc/camera_bloc.dart';
import 'package:anchorage_harbor/presentation/capture/pages/camera_preview_page.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/camera_chrome.dart';
import 'package:anchorage_harbor/presentation/sync/bloc/upload_manager_bloc.dart';
import 'package:anchorage_harbor/presentation/sync/pages/upload_manager_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// One phone, described the way a device matrix actually varies.
class Device {
  const Device(this.name, this.size, this.dpr);

  final String name;
  final Size size;
  final double dpr;

  /// Logical pixels — what the layout actually gets.
  Size get logical => size / dpr;

  @override
  String toString() => name;
}

/// The shapes this app has to survive, chosen for what each one breaks.
const List<Device> devices = <Device>[
  // The floor. 320 dp wide is the narrowest Android worth supporting, and a
  // 16:9 body is *short* — the camera stacks its zoom row, shutter row and a
  // full-width call to action, and short is what runs out first.
  Device('small 16:9', Size(720, 1280), 2),
  // The commonest baseline.
  Device('baseline 360dp', Size(1080, 1920), 3),
  // The device this was built against: a 20:9 body, so the preview is cropped
  // hard at the sides and there is more vertical room than the design needs.
  Device('tall 20:9', Size(1080, 2340), 3),
  // Wide and short: the layout must not assume a phone.
  Device('tablet', Size(1600, 2560), 2),
];

/// Accessibility text scaling. 1.3 is a common system setting, not an extreme.
const List<double> textScales = <double>[1, 1.3];

const List<int> _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

/// Layout guards across the device matrix.
///
/// Not golden tests, and not a substitute for looking at the thing: these
/// assert the two failures that a design built against one phone actually
/// produces on another. An overflow, which Flutter reports as an exception and
/// paints as a black-and-yellow bar; and a control drifting off the bottom of
/// a short screen, where it cannot be pressed at all.
///
/// Text scaling is in the matrix because it is the axis most often forgotten.
/// A user with 1.3x type is not an edge case, and every string in this app is
/// laid out beside a fixed-size control.
void main() {
  late Directory captures;
  late FakeCamera camera;
  late FakeUploadQueueRepository queue;
  late RecordingScheduler scheduler;
  late FakeUploader uploader;
  late FakeConnectivity connectivity;

  setUp(() {
    captures = Directory.systemTemp.createTempSync('harbor_matrix');
    File('${captures.path}/shot-1.png').writeAsBytesSync(_onePixelPng);

    camera = FakeCamera(captureDirectory: captures.path)
      ..session = sessionFor(wideLens, minZoom: 1, maxZoom: 8);
    queue = FakeUploadQueueRepository();
    scheduler = RecordingScheduler();
    uploader = FakeUploader();
    connectivity = FakeConnectivity();

    getIt.registerLazySingleton<CameraPluginAdapter>(CameraPluginAdapter.new);
  });

  tearDown(() async {
    await getIt.reset();
    await queue.dispose();
    await connectivity.dispose();
    captures.deleteSync(recursive: true);
  });

  /// Sizes the surface, and restores it afterwards.
  void useDevice(WidgetTester tester, Device device, double textScale) {
    tester.view.physicalSize = device.size;
    tester.view.devicePixelRatio = device.dpr;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Widget host(Widget child) => MaterialApp(
        theme: HarborTheme.build(),
        home: child,
      );

  Future<void> pumpCamera(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      host(
        BlocProvider<CameraBloc>(
          create: (_) => CameraBloc(
            camera: camera,
            permissions: FakePermissionGateway(),
            enqueueBatch: EnqueueBatch(repository: queue, scheduler: scheduler),
          )..add(const CameraStarted()),
          child: const CameraPreviewPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpUploads(WidgetTester tester) async {
    await queue.enqueueAll(<UploadTask>[
      taskFixture(id: 'a', status: UploadStatus.uploading, bytesTransferred: 400),
      taskFixture(id: 'b', status: UploadStatus.retrying, attempt: 2),
      taskFixture(id: 'c', status: UploadStatus.waitingForConnection),
      taskFixture(id: 'd', status: UploadStatus.synced),
      taskFixture(id: 'e', status: UploadStatus.failed),
    ]);

    await tester.pumpWidget(
      host(
        BlocProvider<UploadManagerBloc>(
          create: (_) => UploadManagerBloc(
            watchQueue: WatchUploadQueue(queue),
            processQueue: ProcessUploadQueue(
              repository: queue,
              uploader: uploader,
              connectivity: connectivity,
              scheduler: scheduler,
            ),
            connectivity: connectivity,
            pauseAll: PauseAllUploads(queue),
            resumeAll:
                ResumeAllUploads(repository: queue, scheduler: scheduler),
            retryFailed:
                RetryFailedUploads(repository: queue, scheduler: scheduler),
            retryUpload: RetryUpload(repository: queue, scheduler: scheduler),
            discardUpload: DiscardUpload(queue),
            clearSynced: ClearSyncedUploads(queue),
          )..add(const UploadManagerStarted()),
          child: const UploadManagerPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final Device device in devices) {
    for (final double scale in textScales) {
      final String label = '$device at ${scale}x type';

      testWidgets('the camera lays out on $label', (WidgetTester tester) async {
        useDevice(tester, device, scale);
        await pumpCamera(tester);

        expect(tester.takeException(), isNull);
      });

      testWidgets('the camera keeps its shutter and its call to action on '
          'screen on $label', (WidgetTester tester) async {
        // The two controls the screen exists for. An overflow is loud; a
        // control pushed past the bottom edge on a short phone is silent, and
        // it is the one that makes the app unusable.
        useDevice(tester, device, scale);
        await pumpCamera(tester);

        final Size screen = device.logical;

        for (final Finder control in <Finder>[
          find.byType(ShutterButton),
          find.byType(FilledButton),
        ]) {
          final Rect rect = tester.getRect(control);
          expect(rect.bottom, lessThanOrEqualTo(screen.height + 0.5),
              reason: '$control runs off the bottom on $label');
          expect(rect.left, greaterThanOrEqualTo(-0.5),
              reason: '$control runs off the left on $label');
          expect(rect.right, lessThanOrEqualTo(screen.width + 0.5),
              reason: '$control runs off the right on $label');
        }
      });

      testWidgets('the upload manager lays out on $label',
          (WidgetTester tester) async {
        useDevice(tester, device, scale);
        await pumpUploads(tester);

        expect(tester.takeException(), isNull);
      });
    }
  }
}
