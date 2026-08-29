import 'dart:io';

import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/data/datasources/camera_plugin_adapter.dart';
import 'package:anchorage_harbor/di/injector.dart';
import 'package:anchorage_harbor/domain/usecases/sync_use_cases.dart';
import 'package:anchorage_harbor/presentation/capture/bloc/camera_bloc.dart';
import 'package:anchorage_harbor/presentation/capture/pages/camera_preview_page.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/camera_chrome.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/exit_confirmation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

/// A 1x1 transparent PNG. The batch thumbnail renders a real file, so a test
/// that captures shots has to put real bytes where the fake says it wrote them
/// — otherwise every frame raises a decode error the test then fails on.
const List<int> _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

void main() {
  late Directory captures;
  late FakeCamera camera;
  late FakeUploadQueueRepository queue;
  late RecordingScheduler scheduler;
  late List<String> platformCalls;

  setUp(() {
    captures = Directory.systemTemp.createTempSync('harbor_page_test');
    for (int i = 1; i <= 12; i++) {
      File('${captures.path}/shot-$i.png').writeAsBytesSync(_onePixelPng);
    }

    camera = FakeCamera(captureDirectory: captures.path)
      ..session = sessionFor(wideLens, minZoom: 0.5, maxZoom: 8);
    queue = FakeUploadQueueRepository();
    scheduler = RecordingScheduler();
    platformCalls = <String>[];

    getIt.registerLazySingleton<CameraPluginAdapter>(CameraPluginAdapter.new);
  });

  tearDown(() async {
    await getIt.reset();
    await queue.dispose();
    captures.deleteSync(recursive: true);
  });

  Future<void> pumpCamera(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // `SystemNavigator.pop` is a platform message, so the way to assert the app
    // actually closed is to listen for it rather than to mock a wrapper.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        platformCalls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: HarborTheme.build(),
        home: BlocProvider<CameraBloc>(
          create: (_) => CameraBloc(
            camera: camera,
            permissions: FakePermissionGateway(),
            enqueueBatch:
                EnqueueBatch(repository: queue, scheduler: scheduler),
          )..add(const CameraStarted()),
          child: const CameraPreviewPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, int shots) async {
    for (int i = 0; i < shots; i++) {
      await tester.tap(find.byType(ShutterButton));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
  }

  group('the shutter row', () {
    testWidgets('the shutter is centred on the screen',
        (WidgetTester tester) async {
      // It used to sit 9 dp right of centre: `spaceBetween` with a 62 dp
      // thumbnail on one side and a 44 dp flip button on the other cannot
      // centre the middle child, however symmetrical it looks in code.
      await pumpCamera(tester);

      final Rect shutter = tester.getRect(find.byType(ShutterButton));
      final double screenCentre =
          tester.view.physicalSize.width / tester.view.devicePixelRatio / 2;

      expect(shutter.center.dx, moreOrLessEquals(screenCentre, epsilon: 0.5));
    });

    testWidgets('the thumbnail, shutter and flip share one centre line',
        (WidgetTester tester) async {
      // The thumbnail used to hang 4 dp low, because its box was padded at the
      // top to make room for the count badge.
      await pumpCamera(tester);
      await capture(tester, 3);

      final double shutter = tester.getRect(find.byType(ShutterButton)).center.dy;
      final double thumbnail =
          tester.getRect(find.byType(BatchThumbnail)).center.dy;
      final double flip =
          tester.getRect(find.byType(GlassCircleButton).last).center.dy;

      expect(thumbnail, moreOrLessEquals(shutter, epsilon: 0.5));
      expect(flip, moreOrLessEquals(shutter, epsilon: 0.5));
    });
  });

  group('closing the app', () {
    testWidgets('the close button asks before closing',
        (WidgetTester tester) async {
      // The regression this guards: on the root route the ✕ called `maybePop`,
      // which has nothing to pop, so the button did nothing whatsoever.
      await pumpCamera(tester);

      await tester.tap(find.bySemanticsLabel('Close Anchorage Harbor'));
      await tester.pumpAndSettle();

      expect(find.byType(ExitConfirmationDialog), findsOneWidget);
      expect(platformCalls, isNot(contains('SystemNavigator.pop')));
    });

    testWidgets('a system back press asks the same question',
        (WidgetTester tester) async {
      await pumpCamera(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(ExitConfirmationDialog), findsOneWidget);
    });

    testWidgets('confirming closes the app', (WidgetTester tester) async {
      await pumpCamera(tester);

      await tester.tap(find.bySemanticsLabel('Close Anchorage Harbor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CLOSE'));
      await tester.pumpAndSettle();

      expect(platformCalls, contains('SystemNavigator.pop'));
    });

    testWidgets('cancelling leaves the app open', (WidgetTester tester) async {
      await pumpCamera(tester);

      await tester.tap(find.bySemanticsLabel('Close Anchorage Harbor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CANCEL'));
      await tester.pumpAndSettle();

      expect(platformCalls, isNot(contains('SystemNavigator.pop')));
      expect(find.byType(ExitConfirmationDialog), findsNothing);
    });

    testWidgets('an unsent batch is warned about, not silently abandoned',
        (WidgetTester tester) async {
      await pumpCamera(tester);
      await capture(tester, 2);

      await tester.tap(find.bySemanticsLabel('Close Anchorage Harbor'));
      await tester.pumpAndSettle();

      expect(find.text('Leave with an unsent batch?'), findsOneWidget);
      expect(find.textContaining('2 photographs'), findsOneWidget);
    });

    testWidgets('UPLOAD & CLOSE hands the batch over before closing',
        (WidgetTester tester) async {
      await pumpCamera(tester);
      await capture(tester, 2);

      await tester.tap(find.bySemanticsLabel('Close Anchorage Harbor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('UPLOAD & CLOSE'));
      await tester.pumpAndSettle();

      // The order is the whole point: durable first, then close.
      expect(queue.tasks, hasLength(2));
      expect(platformCalls, contains('SystemNavigator.pop'));
    });

    testWidgets('a batch that could not be queued keeps the app open',
        (WidgetTester tester) async {
      // Closing here would do exactly the thing the user chose to avoid.
      await pumpCamera(tester);
      await capture(tester, 1);

      queue.writeFailure = const StorageWriteFailure();

      await tester.tap(find.bySemanticsLabel('Close Anchorage Harbor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('UPLOAD & CLOSE'));
      await tester.pumpAndSettle();

      expect(platformCalls, isNot(contains('SystemNavigator.pop')));
    });

    testWidgets('a back press on the dialog dismisses it, and stays open',
        (WidgetTester tester) async {
      // Backing out of the question is not an answer to it, so it must not be
      // read as consent to close — and it must not stack a second dialog
      // behind the first either.
      await pumpCamera(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ExitConfirmationDialog), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(ExitConfirmationDialog), findsNothing);
      expect(platformCalls, isNot(contains('SystemNavigator.pop')));
    });
  });
}
