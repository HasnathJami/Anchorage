import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/domain/services/permission_gateway.dart';
import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/exposure_range.dart';
import 'package:anchorage_harbor/domain/entities/flash_policy.dart';
import 'package:anchorage_harbor/domain/entities/zoom_range.dart';
import 'package:anchorage_harbor/domain/entities/zoom_stop.dart';
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

  /// [dwell] is how long the reticle stays before it fades. Zero keeps the
  /// tests that do not care about it fast and deterministic; the lock and
  /// brightness groups need a real one, because the reticle is what they act on.
  CameraBloc buildBloc({
    FlashPolicy? flashPolicy,
    Duration? dwell,
    Duration zoomSettleDelay = const Duration(milliseconds: 40),
  }) =>
      CameraBloc(
        camera: camera,
        permissions: permissions,
        enqueueBatch: EnqueueBatch(repository: queue, scheduler: scheduler),
        clock: () => DateTime(2026, 8, 28, 9),
        focusIndicatorDuration: dwell ?? Duration.zero,
        flashPolicy: flashPolicy ?? FlashPolicy.standard,
        // Short, so a test that must outlast the settle window does not spend
        // a third of a second doing it.
        zoomSettleDelay: zoomSettleDelay,
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

  group('hardware this device happens not to have', () {
    // The app cannot ask a phone what it is capable of, only try and listen.
    // Every case below is a real device shape, not a hypothetical.

    blocTest<CameraBloc, CameraState>(
      'a phone with one camera offers no flip',
      // Cheap handsets, and a good few tablets and kiosks, ship exactly one.
      // A flip button there does nothing when pressed, which is worse than no
      // button: the user cannot tell a broken app from a limited device.
      build: buildBloc,
      act: (CameraBloc bloc) async {
        camera.session = sessionFor(
          wideLens,
          lenses: <CameraLens>[wideLens],
        );
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.canFlipCamera, isFalse);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a device with only a front camera offers no flip either',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        camera.session = sessionFor(
          frontLens,
          lenses: <CameraLens>[frontLens],
        );
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.canFlipCamera, isFalse);
        expect(bloc.state.isFrontFacing, isTrue);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'an ordinary phone does offer it',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.canFlipCamera, isTrue);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a sensor that cannot meter on demand retires tap-to-focus',
      // Fixed-focus modules and many front cameras have no controllable
      // metering point. The plugin offers no way to ask, so the refusal is
      // discovered by trying - and then remembered.
      build: buildBloc,
      act: (CameraBloc bloc) async {
        camera.focusResult =
            const Result<void>.failure(MeteringUnavailableFailure());
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraFocusRequested(x: 0.5, y: 0.5));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.supportsTapToFocus, isFalse);
        expect(bloc.state.focusPoint, isNull,
            reason: 'no reticle over a frame that ignored it');
        expect(bloc.state.notice, isA<CameraFocusUnavailableNotice>());
      },
    );

    blocTest<CameraBloc, CameraState>(
      'and does not ask it again on every tap',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        camera.focusResult =
            const Result<void>.failure(MeteringUnavailableFailure());
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        for (int tap = 0; tap < 3; tap++) {
          bloc.add(const CameraFocusRequested(x: 0.5, y: 0.5));
          await Future<void>.delayed(Duration.zero);
        }
      },
      verify: (CameraBloc bloc) {
        expect(camera.focusCalls.length, 1,
            reason: 'the answer will not change while this sensor is open');
      },
    );
  });

  group('switching lens throws the old sensor away', () {
    // [_onPaused] already clears these, with the note that a new controller
    // starts at auto metering and 0 EV. A lens switch disposes and rebuilds
    // the controller in exactly the same way, and used to clear none of them.

    Future<CameraBloc> lockedThenSwitched(CameraBloc bloc) async {
      bloc.add(const CameraStarted());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const CameraFocusRequested(x: 0.4, y: 0.6));
      await Future<void>.delayed(Duration.zero);
      bloc.add(const CameraFocusLockToggled());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const CameraExposureOffsetChanged(1));
      await Future<void>.delayed(Duration.zero);

      bloc.add(const CameraLensSelected(ultraWideLens));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return bloc;
    }

    blocTest<CameraBloc, CameraState>(
      'a padlock does not survive the sensor it was locked to',
      // The inverse of the bug the padlock exists to prevent, and worse: a
      // closed padlock drawn over a camera that is metering freely tells the
      // user something untrue.
      build: buildBloc,
      act: lockedThenSwitched,
      verify: (CameraBloc bloc) {
        expect(bloc.state.isMeteringLocked, isFalse);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'the reticle does not survive it either',
      build: buildBloc,
      act: lockedThenSwitched,
      verify: (CameraBloc bloc) {
        expect(bloc.state.focusPoint, isNull,
            reason: 'it marked a point on a frame from another sensor');
      },
    );

    blocTest<CameraBloc, CameraState>(
      'and neither does the brightness the user dialled in',
      build: buildBloc,
      act: lockedThenSwitched,
      verify: (CameraBloc bloc) {
        expect(bloc.state.exposureOffset, 0,
            reason: 'the new controller is at 0 EV whatever the state says');
      },
    );
  });

  group('pinching past what the open camera can show', () {
    // The default fake device is the awkward one, and the common one: two rear
    // cameras, the open one running 1x - 8x of its own zoom, and an ultra-wide
    // beside it whose own 1.0 is the user's 0.5x. Reaching 0.5x therefore
    // means *opening another sensor*, which blanks the preview for a few
    // hundred milliseconds.
    //
    // A pinch produces dozens of values a second. Acting on each one that
    // crossed 1.0x reopened the camera over and over, and the screen flashed
    // its loading state under a moving thumb.

    /// Drives a pinch that travels below 1x without lifting the fingers.
    Future<void> pinchWide(CameraBloc bloc) async {
      bloc.add(const CameraStarted());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const CameraPinchStarted());
      await Future<void>.delayed(Duration.zero);

      for (final double scale in <double>[0.9, 0.8, 0.7, 0.6, 0.5]) {
        bloc.add(CameraPinchZoomed(scale));
        await Future<void>.delayed(Duration.zero);
      }
    }

    blocTest<CameraBloc, CameraState>(
      'opens nothing while the fingers are still moving',
      build: buildBloc,
      act: pinchWide,
      verify: (CameraBloc bloc) {
        expect(camera.lensCalls, isEmpty,
            reason: 'a sensor must not be reopened under a moving thumb');
        expect(bloc.state.effectiveZoom, 1,
            reason: 'it travels as far as the open camera honestly can, and '
                'stops there rather than showing a number it is not at');
      },
    );

    blocTest<CameraBloc, CameraState>(
      'opens the ultra-wide once, when the fingers lift',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        await pinchWide(bloc);
        bloc.add(const CameraZoomGestureEnded());
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      verify: (CameraBloc bloc) {
        expect(camera.lensCalls, <CameraLens>[ultraWideLens]);
        expect(bloc.state.effectiveZoom, closeTo(0.5, 0.001));
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a gesture that wanders across 1x and comes back opens nothing at all',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        await pinchWide(bloc);
        // Changed their mind before lifting.
        bloc.add(const CameraPinchZoomed(2));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraZoomGestureEnded());
        await Future<void>.delayed(const Duration(milliseconds: 60));
      },
      verify: (CameraBloc bloc) {
        expect(camera.lensCalls, isEmpty);
        expect(bloc.state.effectiveZoom, 2);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'the hand-over still happens if the gesture never reports its end',
      // Gesture recognisers lose arenas, and a pointer can be cancelled by the
      // system without an end event. The settle timer is the backstop.
      build: buildBloc,
      act: (CameraBloc bloc) async {
        await pinchWide(bloc);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      },
      verify: (CameraBloc bloc) {
        expect(camera.lensCalls, <CameraLens>[ultraWideLens]);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a quick-zoom pill does not wait for anything',
      // A tap is a decision, not a drag. Making it sit out a settle window
      // would be latency for no reason.
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(
          const CameraZoomStopSelected(ZoomStop(ratio: 0.5, label: '0.5')),
        );
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(camera.lensCalls, <CameraLens>[ultraWideLens]);
        expect(bloc.state.effectiveZoom, closeTo(0.5, 0.001));
      },
    );

    test('the hand-over is marked as one, so the chrome is not covered',
        () async {
      // A cold start has earned a spinner. A rear-to-rear hand-over has not:
      // it is a few hundred milliseconds mid-gesture, and a full-screen
      // loading state over it is the flicker this whole group is about. The
      // page keys its blocking overlay off this flag.
      final CameraBloc bloc = buildBloc();
      final List<CameraState> seen = <CameraState>[];
      final sub = bloc.stream.listen(seen.add);

      bloc.add(const CameraStarted());
      await Future<void>.delayed(Duration.zero);
      seen.clear();

      bloc.add(const CameraZoomStopSelected(ZoomStop(ratio: 0.5, label: '0.5')));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        seen.where((CameraState s) => s.phase == CameraPhase.initialising),
        isNotEmpty,
        reason: 'the sensor really is gone for a moment',
      );
      expect(
        seen
            .where((CameraState s) => s.phase == CameraPhase.initialising)
            .every((CameraState s) => s.isSwitchingLens),
        isTrue,
        reason: 'and every one of those moments is flagged as a hand-over',
      );
      expect(bloc.state.isSwitchingLens, isFalse,
          reason: 'the flag does not outlive the switch');

      await sub.cancel();
      await bloc.close();
    });
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

  group('metering lock', () {
    // A dwell long enough that the reticle is still there to be operated.
    CameraBloc lockBloc() => buildBloc(dwell: const Duration(seconds: 4));

    /// Taps to place a reticle, then works the padlock [times] times.
    Future<void> focusThenToggle(CameraBloc bloc, int times) async {
      bloc.add(const CameraStarted());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const CameraFocusRequested(x: 0.5, y: 0.5));
      await Future<void>.delayed(Duration.zero);
      for (int i = 0; i < times; i++) {
        bloc.add(const CameraFocusLockToggled());
        await Future<void>.delayed(Duration.zero);
      }
    }

    blocTest<CameraBloc, CameraState>(
      'the padlock holds focus and exposure together',
      build: lockBloc,
      act: (CameraBloc bloc) => focusThenToggle(bloc, 1),
      verify: (CameraBloc bloc) {
        expect(bloc.state.isMeteringLocked, isTrue);
        expect(camera.lockCalls.last, isTrue);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'tapping it again hands metering back to the sensor',
      build: lockBloc,
      act: (CameraBloc bloc) => focusThenToggle(bloc, 2),
      verify: (CameraBloc bloc) {
        expect(bloc.state.isMeteringLocked, isFalse);
        expect(camera.lockCalls.last, isFalse);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a locked reticle outlives its dwell timer',
      // A lock the user cannot see is a lock they forget they set, and every
      // photograph afterwards is metered for a subject they walked away from.
      build: () => buildBloc(dwell: const Duration(milliseconds: 20)),
      act: (CameraBloc bloc) async {
        await focusThenToggle(bloc, 1);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.isMeteringLocked, isTrue);
        expect(bloc.state.focusPoint, isNotNull);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'an unlocked reticle does not',
      build: () => buildBloc(dwell: const Duration(milliseconds: 20)),
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraFocusRequested(x: 0.5, y: 0.5));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      },
      verify: (CameraBloc bloc) => expect(bloc.state.focusPoint, isNull),
    );

    blocTest<CameraBloc, CameraState>(
      'a tap elsewhere releases the lock and re-meters',
      build: lockBloc,
      act: (CameraBloc bloc) async {
        await focusThenToggle(bloc, 1);
        bloc.add(const CameraFocusRequested(x: 0.1, y: 0.9));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.isMeteringLocked, isFalse);
        expect(camera.lockCalls.last, isFalse);
        expect(camera.focusCalls.last.x, 0.1);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a sensor that refuses the lock does not show a padlock anyway',
      build: () {
        camera.lockFailure = const CameraOperationFailure('setMeteringLocked');
        return lockBloc();
      },
      act: (CameraBloc bloc) => focusThenToggle(bloc, 1),
      verify: (CameraBloc bloc) =>
          expect(bloc.state.isMeteringLocked, isFalse),
    );

    blocTest<CameraBloc, CameraState>(
      'releasing the sensor drops the lock with it',
      // A new controller starts at auto metering, so state describing the old
      // one must not survive.
      build: lockBloc,
      act: (CameraBloc bloc) async {
        await focusThenToggle(bloc, 1);
        bloc.add(const CameraPaused());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.isMeteringLocked, isFalse);
        expect(bloc.state.focusPoint, isNull);
      },
    );
  });

  group('brightness', () {
    CameraBloc exposureBloc() => buildBloc(dwell: const Duration(seconds: 4));

    Future<void> focusThenExpose(CameraBloc bloc, double ev) async {
      bloc.add(const CameraStarted());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const CameraFocusRequested(x: 0.5, y: 0.5));
      await Future<void>.delayed(Duration.zero);
      bloc.add(CameraExposureOffsetChanged(ev));
      await Future<void>.delayed(Duration.zero);
    }

    blocTest<CameraBloc, CameraState>(
      'the slider snaps to the sensor grid before anything sees the value',
      // The session fixture reports ±2 EV in half stops.
      build: exposureBloc,
      act: (CameraBloc bloc) => focusThenExpose(bloc, 0.7),
      verify: (CameraBloc bloc) {
        expect(bloc.state.exposureOffset, 0.5);
        expect(camera.exposureCalls.last, 0.5);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a value beyond the sensor is clamped, not sent',
      build: exposureBloc,
      act: (CameraBloc bloc) => focusThenExpose(bloc, 9),
      verify: (CameraBloc bloc) => expect(camera.exposureCalls.last, 2.0),
    );

    blocTest<CameraBloc, CameraState>(
      'a brightness that has not moved is never sent to the platform',
      // Same battery argument as zoom: a finger held at an end stop produces
      // dozens of identical values a second.
      build: exposureBloc,
      act: (CameraBloc bloc) async {
        await focusThenExpose(bloc, 1.0);
        bloc.add(const CameraExposureOffsetChanged(1.0));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) => expect(camera.exposureCalls.length, 1),
    );

    blocTest<CameraBloc, CameraState>(
      'the reticle expiring returns the exposure to neutral',
      // Otherwise the brightness becomes an invisible setting, which is the one
      // thing a camera must never have.
      build: () => buildBloc(dwell: const Duration(milliseconds: 20)),
      act: (CameraBloc bloc) async {
        await focusThenExpose(bloc, 1.5);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.focusPoint, isNull);
        expect(bloc.state.exposureOffset, 0);
        expect(camera.exposureCalls.last, 0);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a sensor with no exposure compensation ignores the slider entirely',
      build: () {
        camera.session = sessionFor(
          wideLens,
          exposureRange: ExposureRange.fixed,
        );
        return exposureBloc();
      },
      act: (CameraBloc bloc) => focusThenExpose(bloc, 1.5),
      verify: (CameraBloc bloc) {
        expect(bloc.state.exposureOffset, 0);
        expect(camera.exposureCalls, isEmpty);
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
      'a discarded shot leaves the batch and the disk',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraShutterPressed());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraShotDiscarded('shot-1'));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.shotCount, 0);
        // Forgetting the entry without deleting the file would leave every
        // rejected frame on the device for good.
        expect(camera.discarded, <String>['shot-1']);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'discarding a shot that is not in the batch deletes nothing',
      build: buildBloc,
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraShotDiscarded('never-taken'));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) => expect(camera.discarded, isEmpty),
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

    test('the front camera is never a candidate for a zoom stop', () {
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

      expect(state.backLenses, <CameraLens>[ultraWideLens, wideLens]);
    });
  });

  group('quick-zoom stops', () {
    // The regression this group exists for: the row used to be built from the
    // count of physical back cameras, and on a device that reports one logical
    // rear camera - which is nearly all of them - it rendered nothing at all.
    blocTest<CameraBloc, CameraState>(
      'a single rear camera that can zoom still gets a row of stops',
      build: () {
        camera.session = sessionFor(
          wideLens,
          minZoom: 1,
          maxZoom: 8,
          lenses: <CameraLens>[wideLens],
        );
        return buildBloc();
      },
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(
          bloc.state.zoomStops.map((ZoomStop stop) => stop.ratio),
          <double>[1, 2, 3],
        );
      },
    );

    blocTest<CameraBloc, CameraState>(
      'tapping a stop the open sensor can reach just sets the zoom',
      build: () {
        camera.session = sessionFor(
          wideLens,
          minZoom: 1,
          maxZoom: 8,
          lenses: <CameraLens>[wideLens],
        );
        return buildBloc();
      },
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const CameraZoomStopSelected(ZoomStop(ratio: 2, label: '2')));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(camera.zoomCalls.last, 2);
        expect(camera.lensCalls, isEmpty);
        expect(bloc.state.settings.zoom, 2);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a device with a separate ultra-wide is still offered the 0.5 button',
      // The gap this closes: on hardware that publishes each rear sensor as its
      // own camera, the open one starts at 1x. A row built from *its* range
      // would never show 0.5, so the lens-switching fallback behind that
      // button could never be reached from the UI at all.
      build: () {
        camera.session = sessionFor(wideLens, minZoom: 1, maxZoom: 4);
        return buildBloc();
      },
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.settings.minZoom, 1);
        expect(bloc.state.zoomStops.first.ratio, 0.5);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'a stop outside the open sensor opens the rear camera that can reach it',
      build: () {
        camera.session = sessionFor(wideLens, minZoom: 1, maxZoom: 4);
        return buildBloc();
      },
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(
          const CameraZoomStopSelected(ZoomStop(ratio: 0.5, label: '0.5')),
        );
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(camera.lensCalls.single, ultraWideLens);
      },
    );

    blocTest<CameraBloc, CameraState>(
      'the offered range never exceeds the app ceiling of 8x',
      build: () {
        // Plenty of phones report 10x, 30x or more. Past ~8x it is upscaling.
        camera.session = sessionFor(
          wideLens,
          minZoom: 1,
          maxZoom: 30,
          lenses: <CameraLens>[wideLens],
        );
        return buildBloc();
      },
      act: (CameraBloc bloc) async {
        bloc.add(const CameraStarted());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (CameraBloc bloc) {
        expect(bloc.state.reachableZoomRange.max, ZoomRange.preferredMax);
      },
    );
  });
}
