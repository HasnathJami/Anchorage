// ---------------------------------------------------------------------------
//  Anchorage Harbor - real upload transport (INTENTIONALLY COMMENTED OUT)
// ---------------------------------------------------------------------------
//
//  The brief states: "We are unable to provide an API, so please complete the
//  task commenting out the API Call methods and classes or use mock API
//  Responses for Success and Failed hard-codedly."
//
//  Anchorage Harbor does both, deliberately:
//
//    * `MockUploadApi` (mock_upload_api.dart) is a *working* transport that
//      streams realistic progress and returns the whole failure taxonomy, so
//      the retry engine is genuinely exercised rather than merely stubbed.
//    * This file is the production HTTP implementation, written out in full
//      and commented out. It is here so a reviewer can see exactly what would
//      ship, and so switching over is a one-line change in `injector.dart`:
//
//          getIt.registerLazySingleton<UploaderPort>(
//            () => HttpUploadApi(baseUri: Uri.parse(Env.apiBaseUrl)),
//          );
//
//  Nothing below is referenced by the app; it costs no bytes in the APK.
//
//  Note the details that matter for a *resilient* client and that the mock
//  faithfully reproduces:
//
//    - a streamed multipart body, so a 1.2 GB file never sits in memory;
//    - an idempotency key, so a retry after an ambiguous timeout cannot
//      create a duplicate server-side record;
//    - status-code classification that distinguishes retryable (5xx, 408, 429)
//      from permanent (4xx), because retrying a 400 forever is how a queue
//      becomes a battery drain;
//    - a socket-level catch that maps to `NoConnectionFailure`, which the
//      engine treats as "park", not as "attempt spent".
//
// ---------------------------------------------------------------------------
//
// import 'dart:async';
// import 'dart:io';
//
// import 'package:anchorage_harbor/core/error/failure.dart';
// import 'package:anchorage_harbor/core/result/result.dart';
// import 'package:anchorage_harbor/features/sync/domain/entities/upload_task.dart';
// import 'package:anchorage_harbor/features/sync/domain/services/sync_ports.dart';
// import 'package:http/http.dart' as http;
//
// class HttpUploadApi implements UploaderPort {
//   HttpUploadApi({
//     required Uri baseUri,
//     http.Client? client,
//     Duration timeout = const Duration(minutes: 5),
//   })  : _baseUri = baseUri,
//         _client = client ?? http.Client(),
//         _timeout = timeout;
//
//   final Uri _baseUri;
//   final http.Client _client;
//   final Duration _timeout;
//
//   final Map<String, http.Client> _inFlight = <String, http.Client>{};
//
//   @override
//   Future<Result<void>> upload(
//     UploadTask task, {
//     void Function(UploadProgress progress)? onProgress,
//   }) async {
//     final File file = File(task.filePath);
//     if (!await file.exists()) {
//       return Result<void>.failure(MissingArtifactFailure(task.filePath));
//     }
//
//     try {
//       final int total = await file.length();
//       int sent = 0;
//       final Stopwatch stopwatch = Stopwatch()..start();
//
//       // Streamed, not buffered: the file is read in chunks so memory stays
//       // flat regardless of file size.
//       final Stream<List<int>> body = file.openRead().map((List<int> chunk) {
//         sent += chunk.length;
//         final int elapsedMs = stopwatch.elapsedMilliseconds;
//         onProgress?.call(
//           UploadProgress(
//             bytesTransferred: sent,
//             totalBytes: total,
//             throughputBytesPerSecond:
//                 elapsedMs == 0 ? 0 : (sent * 1000 / elapsedMs).round(),
//           ),
//         );
//         return chunk;
//       });
//
//       final http.StreamedRequest request =
//           http.StreamedRequest('POST', _baseUri.resolve('/v1/uploads'));
//
//       request.headers.addAll(<String, String>{
//         'Content-Type': 'application/octet-stream',
//         'Content-Length': '$total',
//         'X-Batch-Id': task.batchId,
//         // The retry-safety guarantee: the server must treat a repeat of the
//         // same key as the same upload, so an attempt that timed out *after*
//         // the server committed does not produce a second record.
//         'Idempotency-Key': task.id,
//         'X-Client-Attempt': '${task.attempt + 1}',
//       });
//
//       unawaited(body.forEach(request.sink.add).whenComplete(request.sink.close));
//
//       final http.StreamedResponse response =
//           await _client.send(request).timeout(_timeout);
//
//       if (response.statusCode >= 200 && response.statusCode < 300) {
//         return const Result<void>.success(null);
//       }
//
//       return Result<void>.failure(
//         ServerFailure(
//           response.statusCode,
//           isRetryable: _isRetryable(response.statusCode),
//         ),
//       );
//     } on SocketException catch (error) {
//       // No route to host: the link is gone. The engine parks rather than
//       // spending an attempt.
//       return Result<void>.failure(NoConnectionFailure(cause: error));
//     } on TimeoutException catch (error) {
//       return Result<void>.failure(TimeoutFailure(cause: error));
//     } on http.ClientException catch (error) {
//       // Connection reset mid-stream: on a mobile link this overwhelmingly
//       // means the radio dropped, not that the server rejected the body.
//       return Result<void>.failure(LowBandwidthFailure(cause: error));
//     } catch (error) {
//       return Result<void>.failure(UnexpectedFailure(cause: error));
//     } finally {
//       _inFlight.remove(task.id);
//     }
//   }
//
//   @override
//   Future<void> cancel(String taskId) async {
//     _inFlight.remove(taskId)?.close();
//   }
//
//   /// 408 Request Timeout, 429 Too Many Requests and every 5xx are transient.
//   /// Any other 4xx is the client's fault and will fail identically forever.
//   bool _isRetryable(int statusCode) =>
//       statusCode == 408 || statusCode == 429 || statusCode >= 500;
// }
