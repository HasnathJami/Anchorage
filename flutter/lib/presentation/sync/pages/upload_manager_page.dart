import 'package:anchorage_harbor/app/anchorage_harbor_app.dart';
import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
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
class UploadManagerPage extends StatefulWidget {
  const UploadManagerPage({super.key});

  @override
  State<UploadManagerPage> createState() => _UploadManagerPageState();
}

class _UploadManagerPageState extends State<UploadManagerPage> {
  @override
  void initState() {
    super.initState();
    // Stateful for exactly this. The Bloc is hoisted above the navigator, so
    // it cannot tell that the user has walked over to look at the queue -
    // and that visit is what re-arms the rows that had given up and sweeps.
    context.read<UploadManagerBloc>().add(const UploadManagerOpened());
  }

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
                          onCapture: () => _startNewBatch(context),
                        )
                      : _QueueList(state: state),
                ),
                const _BottomBar(),
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
      // Symmetric padding now that the leading icon has gone. It used to be
      // tight on the left to sit under an [IconButton]'s own 8 dp.
      padding: const EdgeInsets.fromLTRB(
        HarborSpacing.md,
        HarborSpacing.sm,
        HarborSpacing.md,
        HarborSpacing.sm,
      ),
      // No back arrow. The system back gesture already leaves this screen, and
      // the bottom of the page carries START NEW UPLOAD BATCH, which is the
      // way back to the camera that the user actually wants - a second, weaker
      // exit in the corner was two answers to one question.
      child: Row(
        children: <Widget>[
          // Expanded rather than a Spacer: the title, the sweep spinner and the
          // link chip together fill the width on a 320 dp phone, and at a large
          // system text scale they exceed it. The title is the part that can
          // afford to give way; the chip is state the user needs.
          Expanded(
            child: Text(
              'Upload Manager',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  context.harborText.screenTitle.copyWith(color: colors.textPrimary),
            ),
          ),
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
          // Both labels are eyebrow type, which carries +1.6 of tracking, and
          // together they overflowed a 360 dp phone by 32 dp - every handset
          // narrower than the one this was designed on, and every handset at
          // all once the user turns their type size up. The count is the part
          // that gives: `CLEAR SYNCED` is a control and has to stay whole.
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Flexible(
                child: Text(
                  'PENDING UPLOADS (${state.pendingCount})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.harborText.eyebrow
                      .copyWith(color: colors.textSecondary),
                ),
              ),
              if (state.progress.syncedTasks > 0) ...<Widget>[
                const SizedBox(width: HarborSpacing.sm),
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

/// The bottom call to action, exactly as the reference shows it: one blue
/// button, nothing else competing with it.
class _BottomBar extends StatelessWidget {
  const _BottomBar();

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
      child: SizedBox(
        height: 50,
        width: double.infinity,
        child: FilledButton(
          onPressed: () => _startNewBatch(context),
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
    );
  }
}

/// Back to the camera, whichever way the user arrived.
///
/// `maybePop` alone is not enough: the Upload Manager is usually pushed on top
/// of the camera, but it can also be the first route the user lands on after a
/// process death, and there a pop would do nothing at all - leaving the
/// screen's only call to action inert.
void _startNewBatch(BuildContext context) {
  final NavigatorState navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.pop();
  } else {
    navigator.pushReplacementNamed(HarborRoutes.camera);
  }
}
