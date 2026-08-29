import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/core/designsystem/harbor_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rules in [HarborToast]'s doc comment, one test each.
///
/// The two that matter are the two the snackbar got wrong: it sat on the
/// bottom edge, over the shutter, and it stayed there for four seconds.
void main() {
  const String message = '1 photograph handed to the sync engine.';

  /// A screen with a button that raises a toast, so the call happens under a
  /// real [Overlay] rather than a synthesised context.
  Widget host({
    String text = message,
    Duration duration = HarborToast.brief,
    HarborToastAction? action,
  }) {
    return MaterialApp(
      theme: HarborTheme.build(),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () => HarborToast.show(
                context,
                message: text,
                duration: duration,
                action: action,
              ),
              child: const Text('raise'),
            ),
          ),
        ),
      ),
    );
  }

  /// Runs past the dwell and the exit animation, so no timer outlives a test.
  Future<void> waitOut(WidgetTester tester, Duration duration) async {
    await tester.pump(duration + const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  }

  testWidgets('sits at the top of the screen, not over the shutter',
      (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('raise'));
    await tester.pumpAndSettle();

    final double screenHeight = tester.getSize(find.byType(Scaffold)).height;
    expect(find.text(message), findsOneWidget);
    // The whole surface, not just its centre: a toast whose bottom edge
    // reaches the middle of the screen is not a top toast.
    expect(
      tester.getBottomLeft(find.text(message)).dy,
      lessThan(screenHeight / 4),
    );

    await waitOut(tester, HarborToast.brief);
  });

  testWidgets('vanishes on its own after 2.5 seconds',
      (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('raise'));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 2000));
    expect(find.text(message), findsOneWidget,
        reason: 'still inside the 2.5 second dwell');

    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();
    expect(find.text(message), findsNothing);
  });

  testWidgets('an error is given longer to be read than a confirmation',
      (WidgetTester tester) async {
    expect(HarborToast.standard, greaterThan(HarborToast.brief));

    await tester.pumpWidget(
      host(text: 'Could not write to local storage.',
          duration: HarborToast.standard),
    );
    await tester.tap(find.text('raise'));
    await tester.pumpAndSettle();

    await tester.pump(HarborToast.brief + const Duration(milliseconds: 500));
    expect(find.text('Could not write to local storage.'), findsOneWidget,
        reason: 'a confirmation would already be gone by now');

    await waitOut(tester, HarborToast.standard);
  });

  testWidgets('a second message replaces the first rather than stacking',
      (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('raise'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('raise'));
    await tester.pumpAndSettle();

    expect(find.text(message), findsOneWidget);

    await waitOut(tester, HarborToast.brief);
  });

  testWidgets('a touch retires it early', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('raise'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(message));
    await tester.pumpAndSettle();

    expect(find.text(message), findsNothing);
  });

  testWidgets('an action fires and takes the toast with it',
      (WidgetTester tester) async {
    bool pressed = false;
    await tester.pumpWidget(
      host(action: (label: 'VIEW', onPressed: () => pressed = true)),
    );
    await tester.tap(find.text('raise'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('VIEW'));
    await tester.pumpAndSettle();

    expect(pressed, isTrue);
    expect(find.text(message), findsNothing);
  });
}
