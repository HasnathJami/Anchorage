import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/permissions/permission_gateway.dart';
import 'package:anchorage_harbor/features/capture/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/features/capture/presentation/bloc/camera_bloc.dart';
import 'package:anchorage_harbor/features/sync/domain/usecases/sync_use_cases.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late FakeCamera camera;
  late FakePermissionGateway permissions;
  late FakeUploadQueueRepository queue;
  late RecordingScheduler scheduler;

  CameraBloc buildBloc() => CameraBloc(
        camera: camera,
        permissions: permissions,
        enqueueBatch: EnqueueBatch(repository: queue, scheduler: scheduler),
        clock: () => DateTime(2026, 8, 28, 9),
        // Zero dwell keeps the focus tests fast and deterministic.
        focusIndicatorDuration: Duration.zero,
      );

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

  group('zoom', () {
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
