import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/domain/entities/zoom_stop.dart';
import 'package:anchorage_harbor/presentation/capture/widgets/camera_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget-level guards on the pieces of chrome the reference design shows.
///
/// These are not golden tests. They assert the things that *broke* in review:
/// a control that renders nothing at all, a selected state that shows the
/// wrong number, a slider that cannot be dragged. A pixel diff would catch
/// none of those any better and would fail on every font tweak.
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: HarborTheme.build(),
        home: Scaffold(body: Center(child: child)),
      );

  group('ZoomStopSelector', () {
    final List<ZoomStop> stops = ZoomLadder.forRange(minZoom: 0.5, maxZoom: 8);

    testWidgets('renders one button per stop', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          ZoomStopSelector(stops: stops, zoom: 1, onSelected: (_) {}),
        ),
      );

      expect(find.text('0.5'), findsOneWidget);
      expect(find.text('1x'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('the selected button shows the live zoom between stops',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          ZoomStopSelector(stops: stops, zoom: 1.7, onSelected: (_) {}),
        ),
      );

      // "1" stays lit until 2x is actually reached, and reads the truth.
      expect(find.text('1.7x'), findsOneWidget);
      expect(find.text('1x'), findsNothing);
    });

    testWidgets('a tap reports the stop that was tapped',
        (WidgetTester tester) async {
      ZoomStop? tapped;
      await tester.pumpWidget(
        host(
          ZoomStopSelector(
            stops: stops,
            zoom: 1,
            onSelected: (ZoomStop stop) => tapped = stop,
          ),
        ),
      );

      await tester.tap(find.text('2'));
      expect(tapped?.ratio, 2);
    });

    testWidgets('a sensor with a single stop gets no row at all',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          ZoomStopSelector(
            stops: ZoomLadder.forRange(minZoom: 1, maxZoom: 1),
            zoom: 1,
            onSelected: (_) {},
          ),
        ),
      );

      expect(find.text('1x'), findsNothing);
    });
  });

  group('VerticalZoomSlider', () {
    testWidgets('labels both ends of the range', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          VerticalZoomSlider(
            zoom: 1,
            minZoom: 1,
            maxZoom: 8,
            onZoomChanged: (_) {},
          ),
        ),
      );

      expect(find.text('8x'), findsOneWidget);
      expect(find.text('1x'), findsOneWidget);
    });

    testWidgets('dragging towards the top of the screen zooms in',
        (WidgetTester tester) async {
      // The defect a rotated Material Slider would reintroduce: its gesture
      // axis inverts, so dragging up zooms out.
      double? reported;
      await tester.pumpWidget(
        host(
          VerticalZoomSlider(
            zoom: 4,
            minZoom: 1,
            maxZoom: 8,
            onZoomChanged: (double zoom) => reported = zoom,
          ),
        ),
      );

      await tester.drag(
        find.byType(VerticalZoomSlider),
        const Offset(0, -40),
      );

      expect(reported, isNotNull);
      expect(reported, greaterThan(4));
    });

    testWidgets('a sensor that cannot zoom gets no slider',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          VerticalZoomSlider(
            zoom: 1,
            minZoom: 1,
            maxZoom: 1,
            onZoomChanged: (_) {},
          ),
        ),
      );

      expect(find.text('1x'), findsNothing);
    });
  });

  group('BatchThumbnail', () {
    testWidgets('shows the pending count as a badge',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        host(BatchThumbnail(count: 12, latestPath: null, onTap: () {})),
      );

      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('an empty batch shows no badge', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(BatchThumbnail(count: 0, latestPath: null, onTap: () {})),
      );

      expect(find.text('0'), findsNothing);
    });
  });

  group('ShutterButton', () {
    testWidgets('a disabled shutter does not fire', (WidgetTester tester) async {
      int fired = 0;
      await tester.pumpWidget(
        host(
          ShutterButton(
            onPressed: () => fired++,
            isCapturing: false,
            enabled: false,
          ),
        ),
      );

      await tester.tap(find.byType(ShutterButton));
      expect(fired, 0);
    });
  });
}
