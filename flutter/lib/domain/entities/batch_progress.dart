import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:equatable/equatable.dart';

/// The aggregate read-out at the top of the Upload Manager.
///
/// Computed from the queue rather than tracked separately, so it can never
/// disagree with the rows underneath it - the classic bug where a header says
/// "100%" over a list that still shows two pending items.
class BatchProgress extends Equatable {
  const BatchProgress({
    required this.totalTasks,
    required this.syncedTasks,
    required this.failedTasks,
    required this.totalBytes,
    required this.uploadedBytes,
    required this.activeThroughputBytesPerSecond,
  });

  factory BatchProgress.from(List<UploadTask> tasks) {
    int totalBytes = 0;
    int uploadedBytes = 0;
    int synced = 0;
    int failed = 0;
    int throughput = 0;

    for (final UploadTask task in tasks) {
      totalBytes += task.sizeBytes;

      // A synced task counts its whole size even if the last progress event
      // was lost, so the bar always reaches the end when the queue drains.
      uploadedBytes += task.status == UploadStatus.synced
          ? task.sizeBytes
          : task.bytesTransferred;

      if (task.status == UploadStatus.synced) synced++;
      if (task.status == UploadStatus.failed) failed++;
      if (task.status == UploadStatus.uploading) {
        throughput += task.throughputBytesPerSecond ?? 0;
      }
    }

    return BatchProgress(
      totalTasks: tasks.length,
      syncedTasks: synced,
      failedTasks: failed,
      totalBytes: totalBytes,
      uploadedBytes: uploadedBytes,
      activeThroughputBytesPerSecond: throughput,
    );
  }

  static const BatchProgress empty = BatchProgress(
    totalTasks: 0,
    syncedTasks: 0,
    failedTasks: 0,
    totalBytes: 0,
    uploadedBytes: 0,
    activeThroughputBytesPerSecond: 0,
  );

  final int totalTasks;
  final int syncedTasks;
  final int failedTasks;
  final int totalBytes;
  final int uploadedBytes;
  final int activeThroughputBytesPerSecond;

  int get pendingTasks => totalTasks - syncedTasks;

  /// 0.0 - 1.0 by *bytes*, not by item count: one 1.2 GB scan among four
  /// thumbnails should not read as "80 % done" the moment the thumbnails land.
  double get fraction =>
      totalBytes <= 0 ? 0 : (uploadedBytes / totalBytes).clamp(0.0, 1.0);

  int get percent => (fraction * 100).round();

  bool get isComplete => totalTasks > 0 && syncedTasks == totalTasks;

  @override
  List<Object?> get props => <Object?>[
        totalTasks,
        syncedTasks,
        failedTasks,
        totalBytes,
        uploadedBytes,
        activeThroughputBytesPerSecond,
      ];
}
