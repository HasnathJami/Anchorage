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
///  * While the app is open, **this Bloc** is what makes the engine feel
///    immediate.
///  * While the app is closed, **WorkManager** does the same job on the OS's
///    schedule — reliably, but with a latency measured in minutes.
///
/// Both call the *same* [ProcessUploadQueue], whose internal in-flight guard
/// and per-row claim make the overlap safe. Duplicating the rules in two
/// places would be the obvious mistake here.
///
/// A sweep starts on four occasions, and all four are needed:
///
///  1. **On launch**, so a queue left behind by a previous run drains.
///  2. **When the link becomes stable**, which is the requirement in one line:
///     uploads resume the moment the network returns, with no button.
///  3. **When new work is queued.** Without this, tapping `UPLOAD BATCH` on an
///     already-stable link uploaded nothing until WorkManager next woke — the
///     rows just sat at `IN QUEUE` while the user watched.
///  4. **When a backoff elapses.** A retry scheduled four seconds out has no
///     other foreground trigger; without a timer the row reads `RETRYING...`
///     and then does nothing for the fifteen minutes until the periodic sweep.
///  5. **While work is parked and the link says it is usable.** (2) fires on a
///     *transition*, and the transition does not always come — see
///     [_scheduleParkedRetry].
///
/// Only (2) existed at first. The rest are why the engine now looks as
/// resilient as it actually is.
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
    DateTime Function() clock = DateTime.now,
    Duration parkedRetryInterval = defaultParkedRetryInterval,
  })  : _parkedRetryInterval = parkedRetryInterval,
        _watchQueue = watchQueue,
        _processQueue = processQueue,
        _connectivity = connectivity,
        _pauseAll = pauseAll,
        _resumeAll = resumeAll,
        _retryUpload = retryUpload,
        _discardUpload = discardUpload,
        _clearSynced = clearSynced,
        _clock = clock,
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
  final DateTime Function() _clock;

  StreamSubscription<QueueSnapshot>? _queueSubscription;
  StreamSubscription<LinkStatus>? _linkSubscription;

  /// Fires when the earliest scheduled retry comes due.
  Timer? _backoffWake;

  /// Fires while work sits parked for want of a connection.
  Timer? _parkedRetryWake;

  /// How long parked work waits before the engine asks again by itself.
  ///
  /// Short enough that a user watching the Upload Manager sees it move, long
  /// enough that a genuinely dead link is not hammered.
  static const Duration defaultParkedRetryInterval = Duration(seconds: 20);

  final Duration _parkedRetryInterval;

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

    // Work that is ready *later* gets a timer; work that is ready *now* gets a
    // sweep. Between them these are what make the engine feel immediate while
    // the app is open — WorkManager is the safety net for when it is not, and
    // its scheduling latency is measured in minutes.
    _scheduleBackoffWake(event.snapshot.tasks);
    _scheduleParkedRetry(event.snapshot.tasks);

    if (_hasWorkReadyNow(event.snapshot.tasks)) {
      add(const UploadSyncRequested(automatic: true));
    }
  }

  /// Wakes the engine while work is parked for want of a connection.
  ///
  /// Trigger (2) — the link becoming stable — fires on a *transition*, and
  /// there are two ordinary situations where that transition never arrives:
  ///
  ///  * **The link never technically dropped.** A weak mobile signal reports
  ///    itself connected the whole time while every transfer collapses on
  ///    bandwidth. The task parks waiting for an event that already happened,
  ///    and nothing asks again.
  ///  * **The failure was not the radio's.** A transport that dies mid-body
  ///    parks the task rather than spending an attempt, which is the right
  ///    call, but the network it is waiting for is already there.
  ///
  /// Parking still spends no attempt — that rule is untouched. This only makes
  /// sure something eventually asks again, which is the difference between
  /// "waiting for a connection" and "stuck".
  void _scheduleParkedRetry(List<UploadTask> tasks) {
    _parkedRetryWake?.cancel();
    _parkedRetryWake = null;

    // An unusable link needs no timer: the transition into a usable one is
    // trigger (2), and it will come.
    if (state.isPaused || !state.link.canTransfer) return;

    final bool anyParked = tasks.any(
      (UploadTask task) => task.status == UploadStatus.waitingForConnection,
    );
    if (!anyParked) return;

    _parkedRetryWake = Timer(
      _parkedRetryInterval,
      () {
        if (!isClosed) add(const UploadSyncRequested(automatic: true));
      },
    );
  }

  /// Whether a sweep started right now would actually do something.
  ///
  /// Every clause is load-bearing. Without the link check, parking a task for
  /// want of a network would republish the queue, start another sweep, park it
  /// again, and spin. Without the readiness check, a task sitting out its
  /// backoff would be swept continuously until the backoff elapsed — which is
  /// the opposite of what backoff is for.
  bool _hasWorkReadyNow(List<UploadTask> tasks) {
    if (state.isPaused || state.isSweeping || !state.link.canTransfer) {
      return false;
    }

    final DateTime now = _clock();
    return tasks.any(
      (UploadTask task) =>
          task.status.isEligibleForPickup &&
          // Parked work is deliberately excluded. It carries no backoff, so it
          // reads as "ready now" forever - and a sweep that parks it again
          // republishes the queue, which would land straight back here. That
          // is a hot loop against a server that is failing every attempt.
          // [_scheduleParkedRetry] owns the re-drive for these instead.
          task.status != UploadStatus.waitingForConnection &&
          task.isReadyAt(now),
    );
  }

  /// Wakes the engine when the earliest backoff elapses.
  ///
  /// A retry scheduled four seconds out used to wait for WorkManager, because
  /// nothing in the foreground was watching the clock. On screen that reads as
  /// a queue that has given up: the row says `RETRYING...` and then nothing
  /// happens for the fifteen minutes until the periodic sweep.
  void _scheduleBackoffWake(List<UploadTask> tasks) {
    _backoffWake?.cancel();
    _backoffWake = null;

    final DateTime now = _clock();
    DateTime? earliest;

    for (final UploadTask task in tasks) {
      final DateTime? at = task.nextAttemptAt;
      if (at == null || !task.status.isEligibleForPickup) continue;
      if (!at.isAfter(now)) continue;
      if (earliest == null || at.isBefore(earliest)) earliest = at;
    }

    if (earliest == null) return;

    _backoffWake = Timer(
      // A small margin, so the sweep's own `readEligible` sees the deadline as
      // passed rather than landing on the same millisecond and finding nothing.
      earliest.difference(now) + const Duration(milliseconds: 250),
      () {
        if (!isClosed) add(const UploadSyncRequested(automatic: true));
      },
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
    _backoffWake?.cancel();
    _parkedRetryWake?.cancel();
    await _queueSubscription?.cancel();
    await _linkSubscription?.cancel();
    return super.close();
  }
}
