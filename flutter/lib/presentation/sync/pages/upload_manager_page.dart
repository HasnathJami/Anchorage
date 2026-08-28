import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/di/injector.dart';
import 'package:anchorage_harbor/data/datasources/mock_upload_api.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/presentation/sync/bloc/upload_manager_bloc.dart';
import 'package:anchorage_harbor/presentation/sync/widgets/upload_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// The Upload Manager.
///
/// A transcription of the reference design: title row with the link chip, the
/// batch progress header on its own raised panel, the "PENDING UPLOADS (n)"
/// list, and the blue call to action pinned to the bottom.
///
/// The screen deliberately has no "upload now" button in its primary position.
/// The engine is autonomous - it starts when the link becomes stable, whether
/// or not anyone is looking - and a prominent manual trigger would imply
/// otherwise. Manual controls exist (pause, per-item retry) but as secondary
/// affordances.
class UploadManagerPage extends StatelessWidget {
  const UploadManagerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: BlocBuilder<UploadManagerBloc, UploadManagerState>(
          builder: (BuildContext context, UploadManagerState state) {
            final UploadManagerBloc bloc = context.read<UploadManagerBloc>();

            return Column(
              children: <Widget>[
                _TitleRow(state: state),
                BatchProgressHeader(
                  progress: state.progress,
                  isPaused: state.isPaused,
                  onTogglePause: () => bloc.add(
                    state.isPaused
                        ? const UploadResumeAllRequested()
                        : const UploadPauseAllRequested(),
                  ),
                ),
                Expanded(
                  child: state.isEmpty
                      ? EmptyQueueView(
                          onCapture: () => Navigator.of(context).maybePop(),
                        )
                      : _QueueList(state: state),
                ),
                _BottomBar(state: state),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.state});

  final UploadManagerState state;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;

    return Container(
      color: colors.panel,
      padding: const EdgeInsets.fromLTRB(
        HarborSpacing.xs,
        HarborSpacing.xs,
        HarborSpacing.md,
        HarborSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.arrow_back, color: colors.textPrimary, size: 20),
            tooltip: 'Back to camera',
          ),
          Text(
            'Upload Manager',
            style: context.harborText.screenTitle.copyWith(color: colors.textPrimary),
          ),
          const Spacer(),
          if (state.isSweeping)
            Padding(
              padding: const EdgeInsets.only(right: HarborSpacing.xs),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primaryBright,
                ),
              ),
            ),
          LinkBadge(quality: state.link),
        ],
      ),
    );
  }
}

class _QueueList extends StatelessWidget {
  const _QueueList({required this.state});

  final UploadManagerState state;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;
    final UploadManagerBloc bloc = context.read<UploadManagerBloc>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HarborSpacing.md,
        HarborSpacing.md,
        HarborSpacing.md,
        HarborSpacing.xs,
      ),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: HarborSpacing.sm),
          child: Row(
            children: <Widget>[
              Text(
                'PENDING UPLOADS (${state.pendingCount})',
                style: context.harborText.eyebrow.copyWith(color: colors.textSecondary),
              ),
              const Spacer(),
              if (state.progress.syncedTasks > 0)
                GestureDetector(
                  onTap: () => bloc.add(const UploadClearSyncedRequested()),
                  behavior: HitTestBehavior.opaque,
                  child: Text(
                    'CLEAR SYNCED',
                    style: context.harborText.eyebrow
                        .copyWith(color: colors.textTertiary),
                  ),
                ),
            ],
          ),
        ),
        ...state.tasks.map(
          (UploadTask task) => UploadTaskTile(
            key: ValueKey<String>(task.id),
            task: task,
            onRetry: () => bloc.add(UploadRetryRequested(task.id)),
            onDiscard: () => bloc.add(UploadDiscardRequested(task.id)),
          ),
        ),
      ],
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.state});

  final UploadManagerState state;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        HarborSpacing.md,
        HarborSpacing.sm,
        HarborSpacing.md,
        HarborSpacing.md,
      ),
      decoration: BoxDecoration(
        color: colors.backgroundElevated,
        border: Border(top: BorderSide(color: colors.hairline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _MockBehaviourSwitcher(),
          const SizedBox(height: HarborSpacing.sm),
          SizedBox(
            height: 50,
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              style: FilledButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: Colors.white,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(HarborRadius.button),
                ),
              ),
              child: Text('START NEW UPLOAD BATCH', style: context.harborText.button),
            ),
          ),
        ],
      ),
    );
  }
}

/// The demonstration control the brief's "no API available" note implies.
///
/// Rather than hard-coding one canned response, the mock transport's behaviour
/// is switchable at runtime, so a reviewer can watch the engine handle success,
/// a mid-transfer bandwidth collapse, a total loss of connectivity and a
/// permanent server rejection - on a real device, in the real UI, in seconds.
///
/// It is scoped to debug affordances only: nothing in the engine reads it, and
/// swapping in the real `HttpUploadApi` makes it inert.
class _MockBehaviourSwitcher extends StatefulWidget {
  const _MockBehaviourSwitcher();

  @override
  State<_MockBehaviourSwitcher> createState() => _MockBehaviourSwitcherState();
}

class _MockBehaviourSwitcherState extends State<_MockBehaviourSwitcher> {
  static const Map<MockUploadBehaviour, String> _labels =
      <MockUploadBehaviour, String>{
    MockUploadBehaviour.succeed: 'SUCCESS',
    MockUploadBehaviour.failLowBandwidth: 'LOW BANDWIDTH',
    MockUploadBehaviour.failNoConnection: 'NO INTERNET',
    MockUploadBehaviour.failServerRetryable: 'SERVER 503',
    MockUploadBehaviour.failServerPermanent: 'SERVER 400',
    MockUploadBehaviour.flaky: 'FLAKY',
  };

  @override
  Widget build(BuildContext context) {
    if (!getIt.isRegistered<MockUploadApi>()) return const SizedBox.shrink();

    final MockUploadApi api = getIt<MockUploadApi>();
    final HarborColors colors = context.harborColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'MOCK API RESPONSE',
          style: context.harborText.eyebrow.copyWith(color: colors.textTertiary),
        ),
        const SizedBox(height: HarborSpacing.xs),
        SizedBox(
          height: 30,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: _labels.entries.map((entry) {
              final bool selected = api.behaviour == entry.key;

              return Padding(
                padding: const EdgeInsets.only(right: HarborSpacing.xs),
                child: GestureDetector(
                  onTap: () {
                    api.behaviour = entry.key;
                    setState(() {});
                    context
                        .read<UploadManagerBloc>()
                        .add(const UploadSyncRequested());
                  },
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: selected ? colors.primaryGhost : Colors.transparent,
                      borderRadius: const BorderRadius.all(HarborRadius.pill),
                      border: Border.all(
                        color: selected ? colors.primaryBright : colors.hairline,
                      ),
                    ),
                    child: Text(
                      entry.value,
                      style: context.harborText.eyebrow.copyWith(
                        color: selected ? colors.primaryBright : colors.textTertiary,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(growable: false),
          ),
        ),
      ],
    );
  }
}
