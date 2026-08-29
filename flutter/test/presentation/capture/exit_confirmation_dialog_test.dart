import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/exit_confirmation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The dialog says something different depending on what is at stake, so each
/// of those things is asserted rather than the fact that a dialog appeared.
void main() {
  /// Opens the dialog and returns what it resolved to.
  Future<ExitIntent?> open(
    WidgetTester tester, {
    required int pendingShots,
    required String tapLabel,
  }) async {
    ExitIntent? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: HarborTheme.build(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await ExitConfirmationDialog.show(
                  context,
                  pendingShots: pendingShots,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    if (tapLabel.isNotEmpty) {
      await tester.tap(find.text(tapLabel));
      await tester.pumpAndSettle();
    }

    return result;
  }

  group('with nothing waiting to be handed over', () {
    testWidgets('offers a plain close, and says the queue keeps working',
        (WidgetTester tester) async {
      await open(tester, pendingShots: 0, tapLabel: '');

      expect(find.text('Close Anchorage Harbor?'), findsOneWidget);
      expect(find.textContaining('keeps syncing in the background'),
          findsOneWidget);
      expect(find.text('CLOSE'), findsOneWidget);
      expect(find.text('CANCEL'), findsOneWidget);
      // Nothing to upload, so nothing to offer uploading.
      expect(find.text('UPLOAD & CLOSE'), findsNothing);
    });

    testWidgets('CLOSE resolves to exit', (WidgetTester tester) async {
      expect(
        await open(tester, pendingShots: 0, tapLabel: 'CLOSE'),
        ExitIntent.exit,
      );
    });

    testWidgets('CANCEL resolves to cancel', (WidgetTester tester) async {
      expect(
        await open(tester, pendingShots: 0, tapLabel: 'CANCEL'),
        ExitIntent.cancel,
      );
    });
  });

  group('with an unsent batch', () {
    testWidgets('warns, counts the frames, and offers to upload first',
        (WidgetTester tester) async {
      await open(tester, pendingShots: 3, tapLabel: '');

      expect(find.text('Leave with an unsent batch?'), findsOneWidget);
      expect(find.textContaining('3 photographs'), findsOneWidget);
      expect(find.textContaining('outside the upload queue'), findsOneWidget);
      expect(find.text('UPLOAD & CLOSE'), findsOneWidget);
      expect(find.text('CLOSE ANYWAY'), findsOneWidget);
      expect(find.text('CANCEL'), findsOneWidget);
    });

    testWidgets('reads as a singular sentence for one frame',
        (WidgetTester tester) async {
      await open(tester, pendingShots: 1, tapLabel: '');

      expect(find.textContaining('1 photograph has'), findsOneWidget);
      expect(find.textContaining('it stays'), findsOneWidget);
    });

    testWidgets('UPLOAD & CLOSE resolves to uploadThenExit',
        (WidgetTester tester) async {
      expect(
        await open(tester, pendingShots: 2, tapLabel: 'UPLOAD & CLOSE'),
        ExitIntent.uploadThenExit,
      );
    });

    testWidgets('CLOSE ANYWAY resolves to exit', (WidgetTester tester) async {
      expect(
        await open(tester, pendingShots: 2, tapLabel: 'CLOSE ANYWAY'),
        ExitIntent.exit,
      );
    });
  });

  testWidgets('dismissing without answering means stay', (WidgetTester tester) async {
    // "I did not answer" must never be read as "yes, close my app".
    ExitIntent? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: HarborTheme.build(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await ExitConfirmationDialog.show(
                  context,
                  pendingShots: 0,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Tap the barrier.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(result, ExitIntent.cancel);
  });
}
