import 'package:desktop_kit/desktop_kit_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_test/flutter_test.dart';

// ── helpers ────────────────────────────────────────────────────────────────

const double _kBarHeight = kBottomNavigationBarHeight;

/// Wraps [AutoHideBottomBar] in a minimal testable app.
Widget _buildApp({
  Duration? autoHideAfter,
  ValueChanged<bool>? onVisibilityChanged,
}) {
  return MaterialApp(
    home: Scaffold(
      body: AutoHideBottomBar(
        autoHideAfter: autoHideAfter,
        onVisibilityChanged: onVisibilityChanged,
        body: ListView.builder(
          itemCount: 30,
          itemBuilder: (BuildContext ctx, int i) =>
              ListTile(title: Text('Item $i')),
        ),
        bar: NavigationBar(
          selectedIndex: 0,
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.home),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.star),
              label: 'Star',
            ),
          ],
        ),
      ),
    ),
  );
}

/// Dispatches a [UserScrollNotification] with the given [direction] on the
/// first [ListView] in the tree.
void _dispatchScrollNotification(
  WidgetTester tester,
  ScrollDirection direction,
) {
  final ScrollMetrics metrics = FixedScrollMetrics(
    pixels: 0,
    minScrollExtent: 0,
    maxScrollExtent: 1000,
    viewportDimension: 600,
    axisDirection: AxisDirection.down,
    devicePixelRatio: 1.0,
  );
  final UserScrollNotification note = UserScrollNotification(
    metrics: metrics,
    context: tester.element(find.byType(ListView)),
    direction: direction,
  );
  // Dispatch via the NotificationListener wrapping the body.
  tester.element(find.byType(ListView)).dispatchNotification(note);
}

/// Finds the [AnimatedSlide] wrapping the bar.
Finder get _barSlide => find.byType(AnimatedSlide);

/// Returns the current [Offset] of the [AnimatedSlide] wrapping the bar.
Offset _slideOffset(WidgetTester tester) =>
    tester.widget<AnimatedSlide>(_barSlide).offset;

/// Finds the peek-handle [GestureDetector] by its stable key.
Finder get _peekHandle =>
    find.byKey(const ValueKey<String>('auto_hide_peek_handle'));

// ── tests ──────────────────────────────────────────────────────────────────

void main() {
  group('AutoHideBottomBar', () {
    testWidgets('bar starts visible (offset zero)', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();
      expect(_slideOffset(tester), Offset.zero);
    });

    testWidgets(
      'ScrollDirection.reverse hides the bar (offset 0,1)',
      (WidgetTester tester) async {
        await tester.pumpWidget(_buildApp());
        await tester.pump();

        // Start visible.
        expect(_slideOffset(tester), Offset.zero);

        _dispatchScrollNotification(tester, ScrollDirection.reverse);
        await tester.pump(); // trigger setState
        await tester.pumpAndSettle(); // wait for AnimatedSlide

        expect(_slideOffset(tester), const Offset(0, 1));
      },
    );

    testWidgets(
      'ScrollDirection.forward after hide reveals bar (offset back to zero)',
      (WidgetTester tester) async {
        await tester.pumpWidget(_buildApp());
        await tester.pump();

        // Hide.
        _dispatchScrollNotification(tester, ScrollDirection.reverse);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(_slideOffset(tester), const Offset(0, 1));

        // Reveal.
        _dispatchScrollNotification(tester, ScrollDirection.forward);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(_slideOffset(tester), Offset.zero);
      },
    );

    testWidgets(
      'onVisibilityChanged fires false when bar hides, true when shown',
      (WidgetTester tester) async {
        final List<bool> events = <bool>[];
        await tester.pumpWidget(
          _buildApp(onVisibilityChanged: events.add),
        );
        await tester.pump();

        _dispatchScrollNotification(tester, ScrollDirection.reverse);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(events, <bool>[false]);

        _dispatchScrollNotification(tester, ScrollDirection.forward);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(events, <bool>[false, true]);
      },
    );

    testWidgets('peek handle is shown when bar is hidden', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      // No peek handle while bar is visible.
      expect(_peekHandle, findsNothing);

      // Hide bar.
      _dispatchScrollNotification(tester, ScrollDirection.reverse);
      await tester.pump();
      await tester.pumpAndSettle();

      // Peek handle GestureDetector appears at the bottom.
      expect(_peekHandle, findsOneWidget);
    });

    testWidgets('drag-up on peek handle reveals the bar', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      // Hide bar first.
      _dispatchScrollNotification(tester, ScrollDirection.reverse);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(_slideOffset(tester), const Offset(0, 1));

      // Drag upward on the peek handle at the bottom edge.
      await tester.drag(
        _peekHandle,
        const Offset(0, -30), // negative dy = upward drag
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(_slideOffset(tester), Offset.zero);
    });

    testWidgets('tapping peek handle reveals the bar', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      // Hide bar.
      _dispatchScrollNotification(tester, ScrollDirection.reverse);
      await tester.pump();
      await tester.pumpAndSettle();

      // Tap the peek handle.
      await tester.tap(_peekHandle);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(_slideOffset(tester), Offset.zero);
    });

    testWidgets('body has positive bottom padding while bar is visible', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      // The Positioned for the body has bottom = kBottomNavigationBarHeight.
      final Positioned bodyPositioned = tester
          .widgetList<Positioned>(find.byType(Positioned))
          .firstWhere((Positioned p) => p.bottom == _kBarHeight);
      expect(bodyPositioned.bottom, _kBarHeight);
    });

    testWidgets('body bottom padding is zero when bar is hidden', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await tester.pump();

      _dispatchScrollNotification(tester, ScrollDirection.reverse);
      await tester.pump();
      await tester.pumpAndSettle();

      // After hiding, no Positioned should have bottom == _kBarHeight for the
      // body; it should be 0 now.
      final Iterable<Positioned> allPositioned =
          tester.widgetList<Positioned>(find.byType(Positioned));
      final bool hasPaddedBody =
          allPositioned.any((Positioned p) => p.bottom == _kBarHeight);
      expect(hasPaddedBody, isFalse);
    });

    testWidgets('autoHideAfter hides bar after the timer fires', (
      WidgetTester tester,
    ) async {
      const Duration timeout = Duration(seconds: 3);
      await tester.pumpWidget(_buildApp(autoHideAfter: timeout));
      await tester.pump();

      // Reveal the bar via a forward scroll (which also resets the timer).
      _dispatchScrollNotification(tester, ScrollDirection.forward);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(_slideOffset(tester), Offset.zero);

      // Advance time past the timeout — the bar should auto-hide.
      await tester.pump(timeout + const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(_slideOffset(tester), const Offset(0, 1));
    });
  });
}
