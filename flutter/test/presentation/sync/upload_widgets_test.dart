import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/domain/entities/batch_progress.dart';
import 'package:anchorage_harbor/domain/entities/link_quality.dart';
import 'package:anchorage_harbor/domain/entities/upload_task.dart';
import 'package:anchorage_harbor/presentation/sync/widgets/upload_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

/// The Upload Manager's rows, checked against the reference design's
/// vocabulary: one status per row, in the reference's own words.
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: HarborTheme.build(),
        home: Scaffold(body: child),
      );

  Widget tileFor(UploadTask task) => host(
        UploadTaskTile(task: task, onRetry: () {}, onDiscard: () {}),
      );

  group('the status line', () {
    testWidgets('a parked task says what it is waiting for',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        tileFor(taskFixture(status: UploadStatus.waitingForConnection)),
      );

      expect(find.text('WAITING FOR CONNECTION'), findsOneWidget);
    });

    testWidgets('a transfer in flight shows its percentage',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        tileFor(
          taskFixture(
            status: UploadStatus.uploading,
            sizeBytes: 1000,
            bytesTransferred: 450,
          ),
        ),
      );

      expect(find.text('UPLOADING - 45%'), findsOneWidget);
    });

    testWidgets('a retry names the attempt out of the budget',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        tileFor(taskFixture(status: UploadStatus.retrying, attempt: 2)),
      );

      expect(find.text('RETRYING... (ATTEMPT 2/3)'), findsOneWidget);
    });

    testWidgets('a delivered row recedes but stays readable',
        (WidgetTester tester) async {
      await tester.pumpWidget(tileFor(taskFixture(status: UploadStatus.synced)));

      expect(find.text('SYNCED'), findsOneWidget);
      // Dimmed, not hidden: "did that one actually land?" is the question this
      // screen exists to answer.
      expect(
        tester.widget<Opacity>(find.byType(Opacity)).opacity,
        lessThan(1),
      );
    });
  });

  group('the file name', () {
    testWidgets('sets the extension apart from the stem',
        (WidgetTester tester) async {
      await tester.pumpWidget(tileFor(taskFixture(id: 'RAW_DATA_NODE_081')));

      // One Text, two spans - the reference sets `.dat` in a muted weight so a
      // column of near-identical generated names stays scannable.
      final Text name = tester.widget<Text>(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Text && widget.textSpan is TextSpan &&
              (widget.textSpan! as TextSpan).text == 'RAW_DATA_NODE_081',
        ),
      );

      expect((name.textSpan! as TextSpan).children, hasLength(1));
      expect(name.semanticsLabel, 'RAW_DATA_NODE_081.jpg');
    });
  });

  group('LinkBadge', () {
    testWidgets('distinguishes connected from usable',
        (WidgetTester tester) async {
      // Three states, not two: the whole retry engine turns on the difference
      // between "there is a network" and "the network can carry a byte".
      await tester.pumpWidget(host(const LinkBadge(quality: LinkQuality.stable)));
      expect(find.text('STABLE LINK'), findsOneWidget);

      await tester
          .pumpWidget(host(const LinkBadge(quality: LinkQuality.unstable)));
      expect(find.text('WEAK LINK'), findsOneWidget);

      await tester.pumpWidget(host(const LinkBadge(quality: LinkQuality.offline)));
      expect(find.text('NO LINK'), findsOneWidget);
    });
  });

  group('BatchProgressHeader', () {
    testWidgets('reads out the reference design\'s three facts',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          BatchProgressHeader(
            progress: BatchProgress.from(<UploadTask>[
              taskFixture(id: 'a', status: UploadStatus.synced, sizeBytes: 300),
              taskFixture(id: 'b', sizeBytes: 100),
            ]),
            isPaused: false,
            onTogglePause: () {},
          ),
        ),
      );

      expect(find.text('BATCH SYNC PROGRESS'), findsOneWidget);
      expect(find.text('75%'), findsOneWidget);
      expect(find.text('PAUSE ALL'), findsOneWidget);
    });

    testWidgets('the pause control names the action it will take',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          BatchProgressHeader(
            progress: BatchProgress.empty,
            isPaused: true,
            onTogglePause: () {},
          ),
        ),
      );

      expect(find.text('RESUME ALL'), findsOneWidget);
    });
  });
}
