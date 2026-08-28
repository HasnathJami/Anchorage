import 'dart:io';
import 'dart:ui' show Offset;

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/domain/entities/camera_lens.dart';
import 'package:anchorage_harbor/domain/entities/capture_batch.dart';
import 'package:anchorage_harbor/domain/services/camera_port.dart';
import 'package:camera/camera.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// [CameraPort] backed by the `camera` plugin.
///
/// This class is the app's entire blast radius for camera failures. Its
/// contract is that it **never throws**: every `CameraException`, missing
/// sensor and revoked permission is translated into a typed [Failure] and
/// returned as a value. A camera app that crashes when a phone call arrives
/// mid-preview is a camera app nobody trusts with their evidence.
class CameraPluginAdapter implements CameraPort {
  CameraPluginAdapter({Uuid? uuid, Directory Function()? overrideDirectory})
      : _uuid = uuid ?? const Uuid(),
        _overrideDirectory = overrideDirectory;

  final Uuid _uuid;
  final Directory Function()? _overrideDirectory;

  CameraController? _controller;
  List<CameraDescription> _descriptions = <CameraDescription>[];
  List<CameraLens> _lenses = <CameraLens>[];
  CameraLens? _activeLens;
  int _previewKey = 0;

  /// The open controller's zoom range, read once when it is opened.
  ///
  /// These are fixed properties of a sensor, but they used to be fetched over
  /// the platform channel on *every* [setZoom] call — and a pinch fires dozens
  /// of those a second, so a single gesture cost hundreds of round-trips to
  /// re-learn two numbers that cannot change. Caching them is the cheapest
  /// battery win on this screen.
  double _minZoom = 1;
  double _maxZoom = 1;

  /// The live controller, for the widget that hosts the platform preview.
  /// Nullable by design: there is no controller before initialise and none
  /// after dispose, and pretending otherwise is how camera apps get late-init
  /// crashes on resume.
  CameraController? get controller => _controller;

  @override
  Future<Result<CameraSession>> initialise() async {
    try {
      _descriptions = await availableCameras();
      if (_descriptions.isEmpty) {
        return const Result<CameraSession>.failure(CameraUnavailableFailure());
      }

      _lenses = _describeLenses(_descriptions);
      final CameraLens lens = _lenses.firstWhere(
        (CameraLens lens) => lens.kind == CameraLensKind.wide,
        orElse: () => _lenses.first,
      );

      return await _open(lens);
    } on CameraException catch (error, stackTrace) {
      return Result<CameraSession>.failure(_translate(error, 'initialise', stackTrace));
    } catch (error) {
      return Result<CameraSession>.failure(
        CameraUnavailableFailure(cause: error),
      );
    }
  }

  @override
  Future<Result<CameraSession>> selectLens(CameraLens lens) => _open(lens);

  Future<Result<CameraSession>> _open(CameraLens lens) async {
    try {
      // Dispose first: holding two controllers open is the fastest way to a
      // "camera in use" error on mid-range Android hardware.
      await _controller?.dispose();

      final CameraDescription description = _descriptions.firstWhere(
        (CameraDescription camera) => camera.name == lens.id,
        orElse: () => _descriptions.first,
      );

      final CameraController controller = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();

      final double minZoom = await controller.getMinZoomLevel();
      final double maxZoom = await controller.getMaxZoomLevel();

      _controller = controller;
      _activeLens = lens;
      _minZoom = minZoom;
      _maxZoom = maxZoom;
      _previewKey++;

      return Result<CameraSession>.success(
        CameraSession(
          previewAspectRatio: controller.value.aspectRatio,
          settings: CameraSettings(
            zoom: minZoom,
            minZoom: minZoom,
            maxZoom: maxZoom,
            isFrontFacing: description.lensDirection == CameraLensDirection.front,
          ),
          availableLenses: _lenses,
          activeLens: lens,
          previewKey: _previewKey,
        ),
      );
    } on CameraException catch (error, stackTrace) {
      return Result<CameraSession>.failure(_translate(error, 'selectLens', stackTrace));
    }
  }

  @override
  Future<Result<void>> setZoom(double zoom) async {
    final CameraController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Result<void>.failure(CameraInterruptedFailure());
    }

    return guard<void>(
      // Clamping here, not in the Bloc: the platform throws on an
      // out-of-range value, and a pinch gesture will absolutely produce one.
      // The bounds come from the cache filled when this controller was opened,
      // not from two fresh channel calls per frame.
      () => controller.setZoomLevel(zoom.clamp(_minZoom, _maxZoom)),
      onError: (Object error, StackTrace stackTrace) =>
          CameraOperationFailure('setZoom', cause: error),
    );
  }

  @override
  Future<Result<void>> setFlashMode(CaptureFlashMode mode) async {
    final CameraController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Result<void>.failure(CameraInterruptedFailure());
    }

    return guard<void>(
      () => controller.setFlashMode(_toPluginFlash(mode)),
      // A sensor with no LED reports `setFlashModeFailed`. That is a different
      // fact from "the camera is unwell", and it gets a different remedy: the
      // app stops offering the mode rather than inviting a retry that cannot
      // succeed. Every other code stays a generic operation failure.
      onError: (Object error, StackTrace stackTrace) =>
          error is CameraException && error.code == 'setFlashModeFailed'
              ? FlashUnavailableFailure(cause: error)
              : CameraOperationFailure('setFlashMode', cause: error),
    );
  }

  @override
  Future<Result<void>> focusAt(FocusPoint point) async {
    final CameraController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Result<void>.failure(CameraInterruptedFailure());
    }

    return guard<void>(
      () async {
        final Offset offset = Offset(point.x, point.y);
        // Exposure is set alongside focus deliberately: tapping a dark corner
        // and getting a sharp but unreadable frame is not what the gesture
        // means to a user.
        await controller.setFocusPoint(offset);
        await controller.setExposurePoint(offset);
        await controller.setFocusMode(FocusMode.auto);
      },
      onError: (Object error, StackTrace stackTrace) =>
          CameraOperationFailure('focusAt', cause: error),
    );
  }

  @override
  Future<Result<CapturedShot>> capture({required double zoomLevel}) async {
    final CameraController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Result<CapturedShot>.failure(CameraInterruptedFailure());
    }
    if (controller.value.isTakingPicture) {
      // Not an error worth surfacing - the user double-tapped the shutter.
      return const Result<CapturedShot>.failure(
        CameraOperationFailure('capture-in-progress'),
      );
    }

    try {
      final XFile file = await controller.takePicture();
      final Directory directory = await _captureDirectory();

      final String id = _uuid.v4();
      final DateTime now = DateTime.now();
      final String name = 'HARBOR_${now.millisecondsSinceEpoch}.jpg';
      final String destination = p.join(directory.path, name);

      // Move out of the plugin's cache and into app-private storage: the OS
      // may clear the cache directory at any moment, and a queued upload must
      // still find its bytes tomorrow morning.
      final File stored = await File(file.path).copy(destination);
      await File(file.path).delete().catchError((_) => File(file.path));

      return Result<CapturedShot>.success(
        CapturedShot(
          id: id,
          filePath: stored.path,
          displayName: name,
          sizeBytes: await stored.length(),
          capturedAt: now,
          lensLabel: _activeLens?.label ?? '1',
          zoomLevel: zoomLevel,
        ),
      );
    } on CameraException catch (error, stackTrace) {
      return Result<CapturedShot>.failure(_translate(error, 'capture', stackTrace));
    } on FileSystemException catch (error) {
      return Result<CapturedShot>.failure(StorageWriteFailure(cause: error));
    }
  }

  @override
  Future<void> dispose() async {
    final CameraController? controller = _controller;
    _controller = null;
    await controller?.dispose();
  }

  Future<Directory> _captureDirectory() async {
    final Directory base =
        _overrideDirectory?.call() ?? await getApplicationDocumentsDirectory();
    final Directory captures = Directory(p.join(base.path, 'captures'));
    if (!captures.existsSync()) {
      await captures.create(recursive: true);
    }
    return captures;
  }

  /// Builds the "0.5 / 1 / 2" pills from the sensors this device actually has.
  ///
  /// The `camera` plugin does not expose focal lengths, so the mapping uses
  /// the platform's ordering convention: on both Android and iOS the first
  /// back camera is the main one, and any additional back cameras are the
  /// ultra-wide and telephoto. Devices with a single back camera get exactly
  /// one pill rather than three that do nothing.
  List<CameraLens> _describeLenses(List<CameraDescription> cameras) {
    final List<CameraDescription> back = cameras
        .where((CameraDescription camera) =>
            camera.lensDirection == CameraLensDirection.back)
        .toList();

    final List<CameraLens> lenses = <CameraLens>[];

    for (int index = 0; index < back.length; index++) {
      final (double factor, String label, CameraLensKind kind) = switch (index) {
        0 => (1.0, '1', CameraLensKind.wide),
        1 => (0.5, '0.5', CameraLensKind.ultraWide),
        2 => (2.0, '2', CameraLensKind.telephoto),
        _ => (index.toDouble(), '$index', CameraLensKind.unknown),
      };

      lenses.add(
        CameraLens(id: back[index].name, zoomFactor: factor, label: label, kind: kind),
      );
    }

    // Present them in optical order (0.5, 1, 2) rather than platform order.
    lenses.sort((CameraLens a, CameraLens b) => a.zoomFactor.compareTo(b.zoomFactor));

    final CameraDescription? front = cameras
        .where((CameraDescription camera) =>
            camera.lensDirection == CameraLensDirection.front)
        .cast<CameraDescription?>()
        .firstWhere((CameraDescription? camera) => camera != null, orElse: () => null);

    if (front != null) {
      lenses.add(
        CameraLens(
          id: front.name,
          zoomFactor: 1,
          label: 'Front',
          kind: CameraLensKind.front,
        ),
      );
    }

    return lenses;
  }

  FlashMode _toPluginFlash(CaptureFlashMode mode) => switch (mode) {
        CaptureFlashMode.off => FlashMode.off,
        CaptureFlashMode.auto => FlashMode.auto,
        CaptureFlashMode.always => FlashMode.always,
        CaptureFlashMode.torch => FlashMode.torch,
      };

  Failure _translate(CameraException error, String operation, StackTrace stackTrace) {
    return switch (error.code) {
      'CameraAccessDenied' ||
      'CameraAccessDeniedWithoutPrompt' ||
      'AudioAccessDenied' =>
        PermissionDeniedFailure(AppPermission.camera, cause: error),
      'CameraAccessRestricted' =>
        PermissionRestrictedFailure(AppPermission.camera, cause: error),
      'cameraNotFound' || 'CameraNotFound' =>
        CameraUnavailableFailure(cause: error),
      _ => CameraOperationFailure(operation, cause: error),
    };
  }
}
