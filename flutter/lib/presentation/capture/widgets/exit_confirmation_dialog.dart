import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:flutter/material.dart';

/// What the user chose in [ExitConfirmationDialog].
enum ExitIntent {
  /// Stay in the app.
  cancel,

  /// Leave now, whatever is or is not in the batch.
  exit,

  /// Hand the batch to the sync engine first, then leave.
  ///
  /// Only ever offered when there is something to hand over.
  uploadThenExit,
}

/// The "are you sure?" before the app closes.
///
/// A confirmation on exit is usually friction for its own sake — most apps
/// should just close. This one earns it, because of what closing can cost
/// here: photographs live in the working batch from the moment the shutter
/// fires until **UPLOAD BATCH** hands them to the queue, and only the queue is
/// durable. Leaving with an unsubmitted batch strands those frames on the
/// device, outside the engine that would have delivered them.
///
/// So the dialog is not one message with two buttons. It says something
/// different depending on what is actually at stake, and when something is, it
/// offers the action that resolves it rather than only the two that do not.
class ExitConfirmationDialog extends StatelessWidget {
  const ExitConfirmationDialog({required this.pendingShots, super.key});

  /// Photographs captured but not yet handed to the sync engine.
  final int pendingShots;

  /// Shows the dialog and resolves to what the user chose.
  ///
  /// Dismissing it by tapping outside or by a second back press resolves to
  /// [ExitIntent.cancel] — the safe reading of "I did not answer" is "do not
  /// close my app".
  static Future<ExitIntent> show(
    BuildContext context, {
    required int pendingShots,
  }) async {
    final ExitIntent? choice = await showDialog<ExitIntent>(
      context: context,
      builder: (BuildContext dialogContext) =>
          ExitConfirmationDialog(pendingShots: pendingShots),
    );

    return choice ?? ExitIntent.cancel;
  }

  bool get _hasUnsavedWork => pendingShots > 0;

  @override
  Widget build(BuildContext context) {
    final HarborColors colors = context.harborColors;
    final HarborTypography text = context.harborText;

    return AlertDialog(
      backgroundColor: colors.panel,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(HarborRadius.card),
      ),
      icon: Icon(
        _hasUnsavedWork ? Icons.warning_amber_rounded : Icons.logout,
        color: _hasUnsavedWork ? colors.caution : colors.primaryBright,
        size: 32,
      ),
      title: Text(
        _hasUnsavedWork ? 'Leave with an unsent batch?' : 'Close Anchorage Harbor?',
        textAlign: TextAlign.center,
        style: text.screenTitle.copyWith(color: colors.textPrimary),
      ),
      content: Text(
        _hasUnsavedWork
            ? '$pendingShots photograph${pendingShots == 1 ? '' : 's'} '
                '${pendingShots == 1 ? 'has' : 'have'} not been handed to the '
                'sync engine yet. Close now and ${pendingShots == 1 ? 'it stays' : 'they stay'} '
                'on this device, outside the upload queue.'
            : 'The upload queue is durable — anything already handed over keeps '
                'syncing in the background, even while the app is closed.',
        textAlign: TextAlign.center,
        style: TextStyle(color: colors.textSecondary, fontSize: 13, height: 1.45),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        HarborSpacing.md,
        0,
        HarborSpacing.md,
        HarborSpacing.md,
      ),
      // A column, not the default row. Three actions side by side on a 320 dp
      // screen wrap into an unreadable stack of half-words, and the ordering
      // here matters more than the horizontal habit: the safe action is the
      // one under the thumb.
      actions: <Widget>[
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_hasUnsavedWork) ...<Widget>[
              _PrimaryAction(
                label: 'UPLOAD & CLOSE',
                onPressed: () =>
                    Navigator.of(context).pop(ExitIntent.uploadThenExit),
              ),
              const SizedBox(height: HarborSpacing.xs),
              _SecondaryAction(
                label: 'CLOSE ANYWAY',
                colour: colors.danger,
                onPressed: () => Navigator.of(context).pop(ExitIntent.exit),
              ),
            ] else
              _PrimaryAction(
                label: 'CLOSE',
                onPressed: () => Navigator.of(context).pop(ExitIntent.exit),
              ),
            const SizedBox(height: HarborSpacing.xs),
            _SecondaryAction(
              label: 'CANCEL',
              colour: colors.textSecondary,
              onPressed: () => Navigator.of(context).pop(ExitIntent.cancel),
            ),
          ],
        ),
      ],
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 46,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: context.harborColors.primary,
          foregroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(HarborRadius.button),
          ),
        ),
        child: Text(label, style: context.harborText.button),
      ),
    );
  }
}

class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({
    required this.label,
    required this.colour,
    required this.onPressed,
  });

  final String label;
  final Color colour;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: colour,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(HarborRadius.button),
          ),
        ),
        child: Text(label, style: context.harborText.button.copyWith(color: colour)),
      ),
    );
  }
}
