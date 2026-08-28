import 'dart:async';

import 'package:anchorage_harbor/domain/entities/batch_progress.dart';
import 'package:anchorage_harbor/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/domain/services/sync_ports.dart';
import 'package:anchorage_harbor/domain/usecases/process_upload_queue.dart';
import 'package:anchorage_harbor/domain/usecases/sync_use_cases.dart';
import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:equatable/equatable.dart';

// ------------------------------------------------------------------- events

sealed class UploadManagerEvent extends Equatable {
  const UploadManagerEvent();

  @override
  List<Object?> get props => <Object?>[];
}

final class UploadManagerStarted extends UploadManagerEvent {
  const UploadManagerStarted();
}

/// Internal: the queue changed.
final class UploadQueueUpdated extends UploadManagerEvent {
  const UploadQueueUpdated(this.snapshot);

  final QueueSnapshot snapshot;

  @override
  List<Object?> get props => <Object?>[snapshot.tasks, snapshot.progress];
}

/// Internal: the network changed.
final class UploadLinkChanged extends UploadManagerEvent {
  const UploadLinkChanged(this.status);

  final LinkStatus status;

  @override
  List<Object?> get props => <Object?>[status];
}

final class UploadSyncRequested extends UploadManagerEvent {
  const UploadSyncRequested({this.automatic = false});

  final bool automatic;

  @override
  List<Object?> get props => <Object?>[automatic];
}

final class UploadPauseAllRequested extends UploadManagerEvent {
  const UploadPauseAllRequested();
}

final class UploadResumeAllRequested extends UploadManagerEvent {
  const UploadResumeAllRequested();
}

final class UploadRetryRequested extends UploadManagerEvent {
  const UploadRetryRequested(this.taskId);

  final String taskId;

  @override
  List<Object?> get props => <Object?>[taskId];
}

final class UploadDiscardRequested extends UploadManagerEvent {
  const UploadDiscardRequested(this.taskId);

  final String taskId;

  @override
  List<Object?> get props => <Object?>[taskId];
}

final class UploadClearSyncedRequested extends UploadManagerEvent {
  const UploadClearSyncedRequested();
}

// -------------------------------------------------------------------- state

class UploadManagerState extends Equatable {
  const UploadManagerState({
    this.tasks = const <UploadTask>[],
    this.progress = BatchProgress.empty,
    this.link = LinkQuality.offline,
    this.isSweeping = false,
    this.isPaused = false,
    this.lastSweep,
  });

  final List<UploadTask> tasks;
  final BatchProgress progress;
  final LinkQuality link;

  /// True while a sweep is in flight - drives the header spinner.
  final bool isSweeping;

  final bool isPaused;
  final SyncSweepReport? lastSweep;

  bool get isEmpty => tasks.isEmpty;

  List<UploadTask> get pending => tasks
      .where((UploadTask task) => task.status != UploadStatus.synced)
      .toList(growable: false);

  int get pendingCount => pending.length;

  /// True when something is genuinely waiting on the network rather than on
  /// the user or the server - the state the "STABLE LINK" chip explains.
  bool get isWaitingForConnection => tasks.any(
        (UploadTask task) => task.status == UploadStatus.waitingForConnection,
      );

  UploadManagerState copyWith({
    List<UploadTask>? tasks,
    BatchProgress? progress,
    LinkQuality? link,
    bool? isSweeping,
    bool? isPaused,
    SyncSweepReport? lastSweep,
  }) {
    return UploadManagerState(
      tasks: tasks ?? this.tasks,
      progress: progress ?? this.progress,
      link: link ?? this.link,
      isSweeping: isSweeping ?? this.isSweeping,
      isPaused: isPaused ?? this.isPaused,
      lastSweep: lastSweep ?? this.lastSweep,
    );
  }

  @override
  List<Object?> get props =>
      <Object?>[tasks, progress, link, isSweeping, isPaused];
}

// --------------------------------------------------------------------- bloc

/// Drives the Upload Manager screen and the *foreground* half of the sync
/// engine.
///
/// The division of labour with WorkManager is deliberate and worth stating:
///
///  * While the app is open, this Bloc reacts to the link becoming stable and
///    sweeps immediately - the user watching the screen sees uploads resume
///    the moment the Wi-Fi comes back, with no delay and no button.
///  * While the app is closed, WorkManager does the same job on the OS's
///    schedule.
///
/// Both call the *same* [ProcessUploadQueue], whose internal in-flight guard
/// makes the overlap safe. Duplicating the rules in two places would be the
/// obvious mistake here.
class UploadManagerBloc extends Bloc<UploadManagerEvent, UploadManagerState> {
  UploadManagerBloc({
    required WatchUploadQueue watchQueue,
    required ProcessUploadQueue processQueue,
    required ConnectivityPort connectivity,
    required PauseAllUploads pauseAll,
    required ResumeAllUploads resumeAll,
    required RetryUpload retryUpload,
    required DiscardUpload discardUpload,
    required ClearSyncedUploads clearSynced,
  })  : _watchQueue = watchQueue,
        _processQueue = processQueue,
        _connectivity = connectivity,
        _pauseAll = pauseAll,
        _resumeAll = resumeAll,
        _retryUpload = retryUpload,
        _discardUpload = discardUpload,
        _clearSynced = clearSynced,
        super(const UploadManagerState()) {
    on<UploadManagerStarted>(_onStarted, transformer: droppable());
    on<UploadQueueUpdated>(_onQueueUpdated);
    on<UploadLinkChanged>(_onLinkChanged, transformer: sequential());
    on<UploadSyncRequested>(_onSyncRequested, transformer: droppable());
    on<UploadPauseAllRequested>(_onPauseAll, transformer: sequential());
    on<UploadResumeAllRequested>(_onResumeAll, transformer: sequential());
    on<UploadRetryRequested>(_onRetry, transformer: sequential());
    on<UploadDiscardRequested>(_onDiscard, transformer: sequential());
    on<UploadClearSyncedRequested>(_onClearSynced, transformer: sequential());
  }

  final WatchUploadQueue _watchQueue;
  final ProcessUploadQueue _processQueue;
  final ConnectivityPort _connectivity;
  final PauseAllUploads _pauseAll;
  final ResumeAllUploads _resumeAll;
  final RetryUpload _retryUpload;
  final DiscardUpload _discardUpload;
  final ClearSyncedUploads _clearSynced;

  StreamSubscription<QueueSnapshot>? _queueSubscription;
  StreamSubscription<LinkStatus>? _linkSubscription;

  Future<void> _onStarted(
    UploadManagerStarted event,
    Emitter<UploadManagerState> emit,
  ) async {
    await _queueSubscription?.cancel();
    _queueSubscription = _watchQueue().listen(
      (QueueSnapshot snapshot) => add(UploadQueueUpdated(snapshot)),
    );

    await _linkSubscription?.cancel();
    _linkSubscription = _connectivity.watch().listen(
      (LinkStatus status) => add(UploadLinkChanged(status)),
    );

    add(const UploadSyncRequested(automatic: true));
  }

  void _onQueueUpdated(
    UploadQueueUpdated event,
    Emitter<UploadManagerState> emit,
  ) {
    emit(
      state.copyWith(
        tasks: event.snapshot.tasks,
        progress: event.snapshot.progress,
        isPaused: event.snapshot.isPaused,
      ),
    );
  }

  Future<void> _onLinkChanged(
    UploadLinkChanged event,
    Emitter<UploadManagerState> emit,
  ) async {
    final LinkQuality previous = state.link;
    emit(state.copyWith(link: event.status.quality));

    // The requirement in one line: the transition *into* a stable link is what
    // resumes the queue, with no user intervention. Reacting to any `isOnline`
    // event instead would fire on the half-connected state and waste attempts.
    final bool becameStable =
        event.status.quality.canTransfer && !previous.canTransfer;

    if (becameStable && !state.isPaused && state.pendingCount > 0) {
      add(const UploadSyncRequested(automatic: true));
    }
  }

  Future<void> _onSyncRequested(
    UploadSyncRequested event,
    Emitter<UploadManagerState> emit,
  ) async {
    if (state.isPaused && event.automatic) return;

    emit(state.copyWith(isSweeping: true));
    final report = await _processQueue();
    emit(
      state.copyWith(
        isSweeping: false,
        lastSweep: report.valueOrNull,
      ),
    );
  }

  Future<void> _onPauseAll(
    UploadPauseAllRequested event,
    Emitter<UploadManagerState> emit,
  ) async {
    await _pauseAll();
    emit(state.copyWith(isPaused: true));
  }

  Future<void> _onResumeAll(
    UploadResumeAllRequested event,
    Emitter<UploadManagerState> emit,
  ) async {
    await _resumeAll();
    emit(state.copyWith(isPaused: false));
    add(const UploadSyncRequested());
  }

  Future<void> _onRetry(
    UploadRetryRequested event,
    Emitter<UploadManagerState> emit,
  ) async {
    await _retryUpload(event.taskId);
    add(const UploadSyncRequested());
  }

  Future<void> _onDiscard(
    UploadDiscardRequested event,
    Emitter<UploadManagerState> emit,
  ) async {
    await _discardUpload(event.taskId);
  }

  Future<void> _onClearSynced(
    UploadClearSyncedRequested event,
    Emitter<UploadManagerState> emit,
  ) async {
    await _clearSynced();
  }

  @override
  Future<void> close() async {
    await _queueSubscription?.cancel();
    await _linkSubscription?.cancel();
    return super.close();
  }
}
