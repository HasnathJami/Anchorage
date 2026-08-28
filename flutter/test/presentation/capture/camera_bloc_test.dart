import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/domain/services/permission_gateway.dart';
import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/flash_policy.dart';
import 'package:anchorage_harbor/presentation/capture/bloc/camera_bloc.dart';
import 'package:anchorage_harbor/domain/usecases/sync_use_cases.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late FakeCamera camera;
  late FakePermissionGateway permissions;
  late FakeUploadQueueRepository queue;
  late RecordingScheduler scheduler;

  CameraBloc buildBloc({FlashPolicy? flashPolicy}) => CameraBloc(
        camera: camera,
        permissions: permissions,
        enqueueBatch: EnqueueBatch(repository: queue, scheduler: scheduler),
        clock: () => DateTime(2026, 8, 28, 9),
        // Zero dwell keeps the focus tests fast and deterministic.
        focusIndicatorDuration: Duration.zero,
        flashPolicy: flashPolicy ?? FlashPolicy.standard,
      );

  /// Drives the flash button [presses] times over an open camera.
  Future<void> cycleFlash(CameraBloc bloc, int presses) async {
    for (int press = 0; press < presses; press++) {
      bloc.add(const CameraFlashToggled());
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    camera = FakeCamera();
    permissions = FakePermissionGateway();
    queue = FakeUploadQueueRepository();
    scheduler = RecordingScheduler();
  });

  tearDown(() async => queue.dispose());

  group('startup and permissions', () {
    blocTest<CameraBloc, CameraState>(
      'opens the camera when permission is already granted',
      build: buildBloc,
      act: (CameraBloc bloc) => bloc.add(const CameraStarted()),
      verify: (CameraBloc bloc) {
        expect(bloc.state.phase, CameraPhase.ready);
        expect(bloc.state.session, isNotNull);
        expect(camera.initialiseCount, 1);
        expect(permissions.requestCount, 0);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'asks for permission when it is missing, then opens',
      build: () {
        permissions = FakePermissionGateway(
          status: PermissionOutcome.denied,
          requestResult: PermissionOutcome.granted,
        );
        return buildBloc();
      },
      act: (CameraBloc bloc) => bloc.add(const CameraStarted()),
      verify: (CameraBloc bloc) {
        expect(permissions.requestCount, 1);
        expect(bloc.state.phase, CameraPhase.ready);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a soft denial leaves the screen askable',
      build: () {
        permissions = FakePermissionGateway(
          status: PermissionOutcome.denied,
          requestResult: PermissionOutcome.denied,
        );
        return buildBloc();
      },
      act: (CameraBloc bloc) => bloc.add(const CameraStarted()),
      verify: (CameraBloc bloc) {
        expect(bloc.state.phase, CameraPhase.permissionRequired);
        expect(bloc.state.notice, const CameraPermissionNotice(blocked: false));
        expect(camera.initialiseCount, 0);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a permanent denial switches the remedy to Settings',
      build: () {
        permissions = FakePermissionGateway(
          status: PermissionOutcome.denied,
          requestResult: PermissionOutcome.blocked,
        );
        return buildBloc();
      },
      act: (CameraBloc bloc) => bloc.add(const CameraStarted()),
      verify: (CameraBloc bloc) {
        expect(bloc.state.phase, CameraPhase.permissionBlocked);
        expect(bloc.state.notice, const CameraPermissionNotice(blocked: true));
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a device with no camera degrades instead of crashing',
      build: () {
        camera = FakeCamera()..initialiseFailure = const CameraUnavailableFailure();
        return buildBloc();
      },
      act: (CameraBloc bloc) => bloc.add(const CameraStarted()),
      verify: (CameraBloc bloc) {
        expect(bloc.state.phase, CameraPhase.unavailable);
        expect(bloc.state.notice, const CameraHardwareNotice('no-camera'));
      },
    );
  });

  group('lifecycle', () {
    blocTest<CameraBloc, CameraState>(
      'releases the sensor when the app is backgrounded',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraPaused());
      },
      verify: (CameraBloc bloc) {
        expect(camera.disposeCount, greaterThanOrEqualTo(1));
        expect(bloc.state.session, isNull);
        expect(bloc.state.phase, CameraPhase.idle);
      },
    );

    blocTest<CameraBloc, CameraState>(
      're-opens on resume and rebuilds the preview',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraPaused());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraResumed());
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.phase, CameraPhase.ready);
        expect(camera.initialiseCount, 2);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'resume re-checks permission, in case it was revoked in Settings',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        permissions.status = PermissionOutcome.denied;
        bloc.add(const CameraResumed());
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.phase, CameraPhase.permissionRequired);
        expect(bloc.state.session, isNull);
      },
    );
  });

  group('flash', () {
    blocTest<CameraBloc, CameraState>(
      'the button can reach the torch',
      // The original defect: the cycle stopped at `always`, so the torch was
      // unreachable and "the flashlight does not work" was literally true.
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        await cycleFlash(bloc, 3);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.flashMode, CaptureFlashMode.torch);
        expect(camera.flashCalls.last, CaptureFlashMode.torch);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a fresh controller is set explicitly, even to off',
      // A new CameraController does not start where the last one left off; the
      // plugin's own default is `auto`. Without an explicit write the hardware
      // would fire a flash while the button on screen read "off".
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(camera.flashCalls, contains(CaptureFlashMode.off));
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a chosen mode is re-applied to the new sensor after a lens switch',
      // The second defect: settings lived on the session, and a lens switch
      // replaced the session wholesale, so the mode silently reverted to off.
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        await cycleFlash(bloc, 2); // off -> auto -> always
        camera.flashCalls.clear();

        bloc.add(const CameraLensSelected(ultraWideLens));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.flashMode, CaptureFlashMode.always);
        expect(camera.flashCalls, <CaptureFlashMode>[CaptureFlashMode.always]);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a chosen mode survives being backgrounded',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        await cycleFlash(bloc, 2); // off -> auto -> always

        bloc.add(const CameraPaused());
        await Future<void>.delayed(Duration.zero);
        camera.flashCalls.clear();
        bloc.add(const CameraResumed());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.flashMode, CaptureFlashMode.always);
        expect(camera.flashCalls, <CaptureFlashMode>[CaptureFlashMode.always]);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'the torch does not come back lit after being backgrounded',
      // Battery: the sensor is disposed on pause, so the LED is already dark.
      // Relighting it unattended on resume is the most expensive thing this
      // screen can do.
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        await cycleFlash(bloc, 3); // off -> auto -> always -> torch

        bloc.add(const CameraPaused());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraResumed());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.flashMode, CaptureFlashMode.off);
        expect(camera.flashCalls.last, CaptureFlashMode.off);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'the torch switches itself off when its deadline passes',
      build: () => buildBloc(
        flashPolicy: const FlashPolicy(torchIdleTimeout: Duration(milliseconds: 20)),
      ),
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        await cycleFlash(bloc, 3);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.flashMode, CaptureFlashMode.off);
        expect(camera.flashCalls.last, CaptureFlashMode.off);
        expect(bloc.state.notice, isA<TorchTimedOutNotice>());
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a mode that is not the torch has no deadline',
      build: () => buildBloc(
        flashPolicy: const FlashPolicy(torchIdleTimeout: Duration(milliseconds: 20)),
      ),
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        await cycleFlash(bloc, 2); // off -> auto -> always
        await Future<void>.delayed(const Duration(milliseconds: 60));
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.flashMode, CaptureFlashMode.always);
        expect(bloc.state.notice, isNot(isA<TorchTimedOutNotice>()));
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a sensor with no flash falls back to off and says so once',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        camera.flashFailure = const FlashUnavailableFailure();
        await cycleFlash(bloc, 1);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.flashMode, CaptureFlashMode.off);
        expect(bloc.state.notice, isA<CameraFlashUnavailableNotice>());
        // A missing LED is not a broken camera: the preview stays up.
        expect(bloc.state.phase, CameraPhase.ready);
      },
    );
  });

  group('zoom', () {
    blocTest<CameraBloc, CameraState>(
      'a zoom that has not moved is never sent to the platform',
      // Battery: a pinch held against the end of the range produces dozens of
      // identical values a second, and each one used to cross the channel to
      // set the zoom it was already at.
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraZoomChanged(99));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraZoomChanged(99));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraZoomChanged(120));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        // Three requests, all clamping to the same 8x: one write.
        expect(camera.zoomCalls, <double>[8]);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'clamps a slider value to the supported range',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraZoomChanged(99));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.settings.zoom, 8);
        expect(camera.zoomCalls.last, 8);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a pinch is measured from the zoom it started at, not compounded',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraZoomChanged(2));
        await Future<void>.delayed(Duration.zero);

        bloc.add(const CameraPinchStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraPinchZoomed(1.5));
        await Future<void>.delayed(Duration.zero);
        // A second frame of the *same* gesture at the same scale must not
        // multiply again - that is the bug this test exists to catch.
        bloc.add(const CameraPinchZoomed(1.5));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.settings.zoom, closeTo(3, 0.001));
      },
    );
  });

  group('focus', () {
    blocTest<CameraBloc, CameraState>(
      'shows the reticle immediately and forwards normalised coordinates',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraFocusRequested(x: 0.4, y: 0.7));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(camera.focusCalls.single.x, 0.4);
        expect(camera.focusCalls.single.y, 0.7);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'clamps an out-of-bounds tap rather than passing it to the platform',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraFocusRequested(x: 1.4, y: -0.2));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(camera.focusCalls.single.x, 1.0);
        expect(camera.focusCalls.single.y, 0.0);
      },
    );
  });

  group('capture and batching', () {
    blocTest<CameraBloc, CameraState>(
      'each shutter press adds one shot to the batch',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraShutterPressed());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraShutterPressed());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.shotCount, 2);
        expect(camera.captureCount, 2);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a failed capture surfaces a notice and does not add a phantom shot',
      build: () {
        camera = FakeCamera()..captureFailure = const StorageWriteFailure();
        return buildBloc();
      },
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraShutterPressed());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.shotCount, 0);
        expect(bloc.state.notice, const CameraStorageNotice());
        expect(bloc.state.isCapturing, isFalse);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a discarded shot leaves the batch',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraShutterPressed());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraShotDiscarded('shot-1'));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) => expect(bloc.state.shotCount, 0),
    );

    blocTest<CameraBloc, CameraState>(
      'submitting hands every shot to the queue and starts a fresh batch',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraShutterPressed());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraShutterPressed());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraBatchSubmitted());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(queue.tasks.length, 2);
        expect(bloc.state.shotCount, 0, reason: 'a fresh batch is started');
        expect(bloc.state.notice, const BatchQueuedNotice(2));
        expect(scheduler.connectedRequests, isNotEmpty);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'submitting an empty batch does nothing',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraBatchSubmitted());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(queue.tasks, isEmpty);
        expect(bloc.state.isSubmitting, isFalse);
      },
    );
  });

  group('lens selection', () {
    blocTest<CameraBloc, CameraState>(
      'switching lens re-opens the sensor and changes the preview key',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraLensSelected(ultraWideLens));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(camera.lensCalls.single, ultraWideLens);
        expect(bloc.state.session!.activeLens, ultraWideLens);
        expect(bloc.state.session!.previewKey, 2);
      },
    );

    test('the front camera is excluded from the zoom pills', () {
      const CameraLens front = CameraLens(
        id: 'front-0',
        zoomFactor: 1,
        label: 'Front',
        kind: CameraLensKind.front,
      );

      final CameraState state = CameraState(
        phase: CameraPhase.ready,
        session: sessionFor(wideLens).copyWith(
          availableLenses: <CameraLens>[ultraWideLens, wideLens, front],
        ),
      );

      expect(state.selectableLenses, <CameraLens>[ultraWideLens, wideLens]);
    });
  });
}
