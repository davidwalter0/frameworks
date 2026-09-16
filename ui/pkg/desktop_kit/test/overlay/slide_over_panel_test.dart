import 'package:desktop_kit/desktop_kit_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

const Key _kOpenButton = ValueKey<String>('open-panel');
const Key _kPanel = ValueKey<String>('slide-over-panel');
const Key _kClose = ValueKey<String>('slide-over-panel-close');
const Key _kBody = ValueKey<String>('slide-over-panel-body');

Widget _harness({
  required SlideEdge edge,
  required WidgetBuilder contentBuilder,
  String? title,
  bool disableAnimations = false,
}) {
  final Widget scaffold = Scaffold(
    body: Builder(
      builder: (BuildContext context) => Center(
        child: ElevatedButton(
          key: _kOpenButton,
          onPressed: () => showSlideOverPanel<void>(
            context: context,
            edge: edge,
            title: title,
            builder: contentBuilder,
          ),
          child: const Text('Open'),
        ),
      ),
    ),
  );
  return MaterialApp(
    home: !disableAnimations
        ? scaffold
        : Builder(
            builder: (BuildContext appContext) => MediaQuery(
              data: MediaQuery.of(appContext).copyWith(disableAnimations: true),
              child: scaffold,
            ),
          ),
  );
}

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('SlideOverPanel edges (800x600 window)', () {
    testWidgets('SlideEdge.right: clamped width, full height, right-aligned',
        (WidgetTester tester) async {
      _setSize(tester, const Size(800, 600));
      await tester.pumpWidget(
        _harness(
          edge: SlideEdge.right,
          contentBuilder: (_) => const Text('panel content'),
        ),
      );
      await tester.tap(find.byKey(_kOpenButton));
      await tester.pumpAndSettle();

      final Finder panel = find.byKey(_kPanel);
      expect(panel, findsOneWidget);
      // maxWidth 560 vs 0.9*800=720 -> 560 wins; full 600 height.
      expect(tester.getSize(panel), const Size(560, 600));
      expect(tester.getTopLeft(panel), const Offset(240, 0));
    });

    testWidgets('SlideEdge.bottom: full width, clamped height, bottom-aligned',
        (WidgetTester tester) async {
      _setSize(tester, const Size(800, 600));
      await tester.pumpWidget(
        _harness(
          edge: SlideEdge.bottom,
          contentBuilder: (_) => const Text('panel content'),
        ),
      );
      await tester.tap(find.byKey(_kOpenButton));
      await tester.pumpAndSettle();

      final Finder panel = find.byKey(_kPanel);
      expect(panel, findsOneWidget);
      // maxHeight 600 vs 0.7*600=420 -> 420 wins; full 800 width.
      expect(tester.getSize(panel), const Size(800, 420));
      expect(tester.getTopLeft(panel), const Offset(0, 180));
    });

    testWidgets('SlideEdge.top: full width, clamped height, top-aligned',
        (WidgetTester tester) async {
      _setSize(tester, const Size(800, 600));
      await tester.pumpWidget(
        _harness(
          edge: SlideEdge.top,
          contentBuilder: (_) => const Text('panel content'),
        ),
      );
      await tester.tap(find.byKey(_kOpenButton));
      await tester.pumpAndSettle();

      final Finder panel = find.byKey(_kPanel);
      expect(panel, findsOneWidget);
      expect(tester.getSize(panel), const Size(800, 420));
      expect(tester.getTopLeft(panel), Offset.zero);
    });
  });

  group('SlideOverPanel scrolling', () {
    testWidgets(
      'content taller than the panel scrolls rather than overflows',
      (WidgetTester tester) async {
        _setSize(tester, const Size(800, 600));
        await tester.pumpWidget(
          _harness(
            edge: SlideEdge.bottom,
            contentBuilder: (_) => Column(
              children: <Widget>[
                for (int i = 0; i < 60; i++)
                  SizedBox(height: 40, child: Text('item $i')),
              ],
            ),
          ),
        );
        await tester.tap(find.byKey(_kOpenButton));
        await tester.pumpAndSettle();

        // 60 * 40 = 2400px of content in a 420px-tall panel -- must not
        // overflow (a bare Column would throw a RenderFlex overflow here).
        expect(tester.takeException(), isNull);

        final Finder scrollable = find.descendant(
          of: find.byKey(_kBody),
          matching: find.byType(Scrollable),
        );
        expect(scrollable, findsOneWidget);
        final ScrollableState state = tester.state<ScrollableState>(scrollable);
        expect(state.position.maxScrollExtent, greaterThan(0));

        // The scroll is also functionally real, not just theoretically
        // possible: the last item is unreachable by a plain tap/ensureVisible
        // before scrolling occurs, and dragging the scrollable moves the
        // scroll position off zero -- both would be false for a Column that
        // silently clipped instead of scrolling.
        expect(state.position.pixels, 0);
        await tester.drag(scrollable, const Offset(0, -2000));
        await tester.pumpAndSettle();
        expect(state.position.pixels, greaterThan(0));
        await tester.ensureVisible(find.text('item 59'));
        expect(find.text('item 59'), findsOneWidget);
      },
    );
  });

  group('SlideOverPanel dismissal', () {
    testWidgets('tapping the barrier dismisses the panel',
        (WidgetTester tester) async {
      _setSize(tester, const Size(800, 600));
      await tester.pumpWidget(
        _harness(
          edge: SlideEdge.right,
          contentBuilder: (_) => const Text('panel content'),
        ),
      );
      await tester.tap(find.byKey(_kOpenButton));
      await tester.pumpAndSettle();
      expect(find.byKey(_kPanel), findsOneWidget);

      // The panel spans x=240..800 at this window size; (10,10) is on the
      // barrier, well clear of the panel itself.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byKey(_kPanel), findsNothing);
    });

    testWidgets('pressing Escape dismisses the panel',
        (WidgetTester tester) async {
      _setSize(tester, const Size(800, 600));
      await tester.pumpWidget(
        _harness(
          edge: SlideEdge.right,
          contentBuilder: (_) => const Text('panel content'),
        ),
      );
      await tester.tap(find.byKey(_kOpenButton));
      await tester.pumpAndSettle();
      expect(find.byKey(_kPanel), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(_kPanel), findsNothing);
    });

    testWidgets(
        'the header close button dismisses the panel and shows the title',
        (WidgetTester tester) async {
      _setSize(tester, const Size(800, 600));
      await tester.pumpWidget(
        _harness(
          edge: SlideEdge.right,
          title: 'Compare runs',
          contentBuilder: (_) => const Text('panel content'),
        ),
      );
      await tester.tap(find.byKey(_kOpenButton));
      await tester.pumpAndSettle();
      expect(find.text('Compare runs'), findsOneWidget);

      await tester.tap(find.byKey(_kClose));
      await tester.pumpAndSettle();
      expect(find.byKey(_kPanel), findsNothing);
    });
  });

  group('SlideOverPanel reduced motion', () {
    testWidgets(
      'MediaQuery.disableAnimationsOf skips the transition duration',
      (WidgetTester tester) async {
        _setSize(tester, const Size(800, 600));
        await tester.pumpWidget(
          _harness(
            edge: SlideEdge.right,
            disableAnimations: true,
            contentBuilder: (_) => const Text('panel content'),
          ),
        );
        await tester.tap(find.byKey(_kOpenButton));
        // A single pump (not pumpAndSettle) is enough when the transition
        // duration is truly zero -- if reduced-motion were NOT honoured,
        // the panel would still be mid-slide here and this would fail.
        await tester.pump();
        expect(find.byKey(_kPanel), findsOneWidget);
        expect(tester.getTopLeft(find.byKey(_kPanel)), const Offset(240, 0));
      },
    );
  });

  group('SlideOverPanel vs. a dialog opened from inside it', () {
    testWidgets(
      'a dialog pushed from inside the panel renders ABOVE it -- the '
      'OverlayEntry-trap regression test (see slide_over_panel.dart\'s '
      'library doc)',
      (WidgetTester tester) async {
        _setSize(tester, const Size(800, 600));
        bool dialogButtonPressed = false;

        await tester.pumpWidget(
          _harness(
            edge: SlideEdge.right,
            contentBuilder: (BuildContext panelContext) => ElevatedButton(
              key: const ValueKey<String>('open-inner-dialog'),
              onPressed: () => showDialog<void>(
                context: panelContext,
                builder: (BuildContext dialogContext) => AlertDialog(
                  content: ElevatedButton(
                    key: const ValueKey<String>('inner-dialog-button'),
                    onPressed: () => dialogButtonPressed = true,
                    child: const Text('inside dialog'),
                  ),
                ),
              ),
              child: const Text('open dialog'),
            ),
          ),
        );

        await tester.tap(find.byKey(_kOpenButton));
        await tester.pumpAndSettle();

        await tester
            .tap(find.byKey(const ValueKey<String>('open-inner-dialog')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);

        // If the panel were a hand-inserted OverlayEntry (the exact trap
        // this component exists to avoid -- see the library doc), the
        // panel's OverlayEntry would sit ABOVE the dialog's route in the
        // ambient Overlay's paint/hit-test order, and this tap would never
        // reach the dialog's own button. Reaching it here is the proof the
        // dialog renders on top, because both the panel and the dialog are
        // real Navigator routes, stacked in push order.
        await tester
            .tap(find.byKey(const ValueKey<String>('inner-dialog-button')));
        await tester.pump();
        expect(dialogButtonPressed, isTrue);
      },
    );
  });
}
