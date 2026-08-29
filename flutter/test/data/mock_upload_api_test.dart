import 'dart:io';

import 'package:anchorage_harbor/core/error/failure.dart';
import 'package:anchorage_harbor/core/result/result.dart';
import 'package:anchorage_harbor/data/datasources/mock_upload_api.dart';
import 'package:anchorage_harbor/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/domain/services/sync_ports.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// Big enough that the mock's per-tick chunk does not deliver it whole on the
/// first tick — otherwise 'fails part-way' is untestable.
const int _fileBytes = 4 * 1024 * 1024;

/// The brief supplies no API, so this class *is* the transport for the
/// assessment build. It answers for the **server** only: the two options behind
/// the settings sheet are "it took the file" and "it did not". Whether the link
/// can carry the file is a separate question, answered by the device — which is
/// why there is no scripted "no internet" or "low bandwidth" here any more.
void main() {
  late Directory files;
  late FakeConnectivity connectivity;

  /// A task whose bytes actually exist on disk.
  UploadTask taskOn(String id, {int attempt = 0, int sizeBytes = _fileBytes}) {
    File('${files.path}/$id.bin').writeAsBytesSync(List<int>.filled(16, 0));
    return UploadTask(
      id: id,
      batchId: 'batch',
      filePath: '${files.path}/$id.bin',
      displayName: '$id.bin',
      sizeBytes: sizeBytes,
      createdAt: DateTime(2026, 8, 28, 9),
      attempt: attempt,
    );
  }

  MockUploadApi api(MockUploadBehaviour behaviour) => MockUploadApi(
        behaviour: behaviour,
        connectivity: connectivity,
        // No pacing: these assert on outcomes, not on transfer speed.
        simulateTime: false,
      );

  setUp(() {
    files = Directory.systemTemp.createTempSync('harbor_mock_api');
    connectivity = FakeConnectivity();
  });

  tearDown(() async {
    await connectivity.dispose();
    files.deleteSync(recursive: true);
  });

  group('success', () {
    test('completes and reports progress all the way to the end', () async {
      final List<UploadProgress> ticks = <UploadProgress>[];

      final Result<void> result = await api(MockUploadBehaviour.succeed)
          .upload(taskOn('ok'), onProgress: ticks.add);

      expect(result.isSuccess, isTrue);
      expect(ticks, isNotEmpty);
      expect(ticks.last.bytesTransferred, _fileBytes);
    });

    test('reports a throughput it measured rather than one it was given',
        () async {
      // The bandwidth watchdog acts on this number. A mock that echoed its own
      // configured rate would make that check a tautology.
      final List<UploadProgress> ticks = <UploadProgress>[];

      await api(MockUploadBehaviour.succeed)
          .upload(taskOn('measured'), onProgress: ticks.add);

      expect(ticks.every((UploadProgress tick) =>
          tick.throughputBytesPerSecond > 0), isTrue);
    });
  });

  group('the server rejecting the upload', () {
    test('is retryable, so the engine decides when to stop, not the mock',
        () async {
      final Result<void> result =
          await api(MockUploadBehaviour.fail).upload(taskOn('sick'));

      final ServerFailure failure = result.failureOrNull! as ServerFailure;
      expect(failure.statusCode, MockUploadApi.rejectionStatusCode);
      expect(failure.isRetryable, isTrue);
    });

    test('is the same answer however many attempts have been made', () async {
      // The mock holds no counters of its own: the foreground sweep and the
      // WorkManager isolate have separate object graphs, and a mock that
      // remembered would give them different answers for the same task.
      for (final int attempt in <int>[0, 1, 5, 99]) {
        final Result<void> result = await api(MockUploadBehaviour.fail)
            .upload(taskOn('sick', attempt: attempt));

        expect(
          (result.failureOrNull! as ServerFailure).statusCode,
          MockUploadApi.rejectionStatusCode,
        );
      }
    });

    test('lands part-way, after real progress', () async {
      final List<UploadProgress> ticks = <UploadProgress>[];

      await api(MockUploadBehaviour.fail)
          .upload(taskOn('sick'), onProgress: ticks.add);

      expect(ticks, isNotEmpty);
      expect(ticks.last.bytesTransferred, lessThan(_fileBytes));
    });

    test('rejects even on a perfectly good link', () async {
      // The whole point of the two-option switch: FAILED means the server said
      // no, and no amount of signal changes that.
      connectivity.quality = LinkQuality.stable;

      final Result<void> result =
          await api(MockUploadBehaviour.fail).upload(taskOn('sick'));

      expect(result.failureOrNull, isA<ServerFailure>());
      expect(result.failureOrNull!.isConnectivityRelated, isFalse,
          reason: 'a rejection must not be mistaken for a network problem, or '
              'it would be parked instead of retried');
    });
  });

  group('a device that is genuinely offline', () {
    test('fails with no connection, whatever the switch says', () async {
      // Pulling the device off Wi-Fi mid-demo must produce a real failure, not
      // the success that happens to be selected.
      connectivity.quality = LinkQuality.offline;

      final Result<void> result =
          await api(MockUploadBehaviour.succeed).upload(taskOn('grounded'));

      expect(result.failureOrNull, isA<NoConnectionFailure>());
      expect(result.failureOrNull!.isConnectivityRelated, isTrue,
          reason: 'costs no attempt');
    });

    test('does not move a single byte', () async {
      connectivity.quality = LinkQuality.offline;
      final List<UploadProgress> ticks = <UploadProgress>[];

      await api(MockUploadBehaviour.succeed)
          .upload(taskOn('grounded'), onProgress: ticks.add);

      expect(ticks, isEmpty);
    });
  });

  group('a cancelled transfer', () {
    test('stops rather than running to completion', () async {
      // This is the path the bandwidth watchdog uses to abandon a transfer.
      final MockUploadApi transport = api(MockUploadBehaviour.succeed);
      final UploadTask task = taskOn('slow');

      await transport.cancel(task.id);
      // A cancellation lodged before the call is cleared on entry — the guard
      // is for a cancel arriving *during* a transfer, so drive one that way.
      final Result<void> result = await transport.upload(
        task,
        onProgress: (UploadProgress progress) => transport.cancel(task.id),
      );

      expect(result.isSuccess, isFalse);
    });
  });

  group('a file that is no longer there', () {
    test('is terminal, and is reported from the transport', () async {
      // Checked here because this is where the filesystem actually lives.
      final UploadTask task = taskOn('gone');
      File(task.filePath).deleteSync();

      final Result<void> result =
          await api(MockUploadBehaviour.succeed).upload(task);

      expect(result.failureOrNull, isA<MissingArtifactFailure>());
      expect(result.failureOrNull!.isRetryable, isFalse);
    });
  });
}
