import 'package:anchorage_harbor/core/designsystem/harbor_theme.dart';
import 'package:anchorage_harbor/domain/entities/exposure_range.dart';
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

  group('FocusReticle', () {
    const Size preview = Size(360, 640);

    /// A reticle in a Stack the size of a preview, as the page hosts it.
    Widget reticle({
      Offset at = const Offset(180, 320),
      bool isLocked = false,
      ExposureRange exposure = const ExposureRange(min: -2, max: 2, step: 0.5),
      double offset = 0,
      VoidCallback? onLockToggled,
      ValueChanged<double>? onExposureChanged,
    }) {
      return MaterialApp(
        theme: HarborTheme.build(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: preview.width,
              height: preview.height,
              child: Stack(
                children: <Widget>[
                  FocusReticle(
                    position: at,
                    bounds: preview,
                    isLocked: isLocked,
                    exposure: exposure,
                    exposureOffset: offset,
                    onLockToggled: onLockToggled ?? () {},
                    onExposureChanged: onExposureChanged ?? (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('the metering ring is a whole circle, not two arcs',
        (WidgetTester tester) async {
      await tester.pumpWidget(reticle());
      await tester.pumpAndSettle();

      // The ring is the reticle's only IgnorePointer. It used to be squeezed
      // to the padlock's width, because a Stack sizes itself from its
      // *non-positioned* children and the ring is positioned - so the circle
      // rendered as a top arc and a bottom arc with no sides.
      final Finder ring = find.descendant(
        of: find.byType(FocusReticle),
        matching: find.byType(IgnorePointer),
      );

      final Size size = tester.getSize(ring);
      expect(size.width, size.height, reason: 'a circle, not an ellipse');
      expect(size.width, greaterThan(60));
    });

    testWidgets('shows an open padlock until it is locked',
        (WidgetTester tester) async {
      await tester.pumpWidget(reticle());
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.lock_open), findsOneWidget);
      expect(find.byIcon(Icons.lock), findsNothing);
    });

    testWidgets('shows a closed padlock while locked',
        (WidgetTester tester) async {
      // The state has to be visible: a lock the user cannot see is a lock they
      // forget they set.
      await tester.pumpWidget(reticle(isLocked: true));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.lock), findsOneWidget);
    });

    testWidgets('tapping the padlock reports it', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(reticle(onLockToggled: () => taps++));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.lock_open));
      expect(taps, 1);
    });

    testWidgets('dragging the sun reports an exposure inside the range',
        (WidgetTester tester) async {
      final List<double> reported = <double>[];
      await tester.pumpWidget(
        reticle(onExposureChanged: reported.add),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byIcon(Icons.brightness_7), const Offset(40, 0));
      await tester.pumpAndSettle();

      expect(reported, isNotEmpty);
      expect(reported.last, greaterThan(0));
      expect(reported.last, lessThanOrEqualTo(2));
    });

    testWidgets('a sensor with no exposure compensation gets no slider',
        (WidgetTester tester) async {
      await tester.pumpWidget(reticle(exposure: ExposureRange.fixed));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.brightness_7), findsNothing);
      // The ring and its padlock still make sense — focus alone is lockable.
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
    });

    testWidgets('a tap near the edge keeps the whole reticle on screen',
        (WidgetTester tester) async {
      // Otherwise the slider cannot be dragged and the padlock cannot be hit.
      await tester.pumpWidget(reticle(at: const Offset(2, 2)));
      await tester.pumpAndSettle();

      final Rect box = tester.getRect(find.byType(FocusReticle));
      final Rect frame = tester.getRect(find.byType(Stack).first);

      expect(box.left, greaterThanOrEqualTo(frame.left));
      expect(box.top, greaterThanOrEqualTo(frame.top));
      expect(box.right, lessThanOrEqualTo(frame.right));
      expect(box.bottom, lessThanOrEqualTo(frame.bottom));
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
