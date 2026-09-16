// Tests for SpanHost: side composition, double clamping (settings ∩
// viewport−minBody), drag sign semantics (down grows top / shrinks bottom),
// debounced commit, height-field commit, close — and BODY IDENTITY: pinning,
// unpinning or re-siding a span must never dispose the page body's Element,
// because that silently destroys unsaved state the body holds.

import 'package:desktop_kit/desktop_kit_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A page body that OWNS state, so a remount is observable rather than
/// invisible. Deliberately carries NO key: the point of the identity tests is
/// that a host needs no `GlobalKey` of its own to keep its body alive.
class _StatefulBody extends StatefulWidget {
  const _StatefulBody();

  /// Number of times a fresh State was created across the whole test run;
  /// reset by each identity test. A remount increments it.
  static int mounts = 0;

  @override
  State<_StatefulBody> createState() => _StatefulBodyState();
}

class _StatefulBodyState extends State<_StatefulBody> {
  /// Stands in for unsaved work — an open editor buffer, a dirty form.
  int unsaved = 0;

  /// Counts deactivate/activate cycles. A `GlobalKey`-based fix keeps the
  /// State but still moves the element THROUGH the inactive list, so this
  /// separates "survived a reparent" from "was never uprooted".
  int deactivations = 0;

  @override
  void initState() {
    super.initState();
    _StatefulBody.mounts += 1;
  }

  @override
  void deactivate() {
    deactivations += 1;
    super.deactivate();
  }

  void edit() => setState(() => unsaved += 1);

  @override
  Widget build(BuildContext context) => Text('unsaved: $unsaved');
}

void main() {
  Widget host({
    required bool showSpan,
    required SpanSide side,
    required double height,
    required ValueChanged<double> onHeightCommitted,
    VoidCallback? onClose,
    Widget child = const Text('page-body'),
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SpanHost(
          showSpan: showSpan,
          side: side,
          height: height,
          spanTitle: 'Pinned',
          onHeightCommitted: onHeightCommitted,
          onClose: onClose,
          spanBuilder: (_) => const Text('span-content'),
          child: child,
        ),
      ),
    );
  }

  testWidgets('hidden span renders only the child', (tester) async {
    await tester.pumpWidget(host(
      showSpan: false,
      side: SpanSide.top,
      height: 200,
      onHeightCommitted: (_) {},
    ));
    expect(find.text('page-body'), findsOneWidget);
    expect(find.text('span-content'), findsNothing);
  });

  testWidgets('top span renders pane above body; bottom below', (tester) async {
    for (final SpanSide side in SpanSide.values) {
      await tester.pumpWidget(host(
        showSpan: true,
        side: side,
        height: 200,
        onHeightCommitted: (_) {},
      ));
      await tester.pump();
      final Offset pane = tester.getCenter(find.text('span-content'));
      final Offset body = tester.getCenter(find.text('page-body'));
      if (side == SpanSide.top) {
        expect(pane.dy, lessThan(body.dy), reason: 'top span above body');
      } else {
        expect(pane.dy, greaterThan(body.dy), reason: 'bottom span below body');
      }
    }
  });

  testWidgets('viewport clamp: body keeps minBodyHeight', (tester) async {
    // Request an absurd height; the effective pane must leave
    // kSpanMinBodyHeight + handle for the body.
    await tester.pumpWidget(host(
      showSpan: true,
      side: SpanSide.top,
      height: 5000,
      onHeightCommitted: (_) {},
    ));
    await tester.pump();
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final Size paneSize = tester.getSize(
      find.byType(SpanPane),
    );
    expect(
      paneSize.height,
      lessThanOrEqualTo(
        screen.height - kSpanHandleThickness - kSpanMinBodyHeight + 0.01,
      ),
    );
  });

  testWidgets('drag down grows a TOP span (debounced commit)', (tester) async {
    double? committed;
    await tester.pumpWidget(host(
      showSpan: true,
      side: SpanSide.top,
      height: 200,
      onHeightCommitted: (h) => committed = h,
    ));
    await tester.pump();

    final Finder handle = find.byKey(const ValueKey('span-drag-handle'));
    await tester.drag(handle, const Offset(0, 40));
    await tester.pump();
    // Not yet committed (300ms debounce).
    expect(committed, isNull);
    await tester.pump(kSpanCommitDebounce + const Duration(milliseconds: 50));
    expect(committed, isNotNull);
    expect(committed!, greaterThan(200));
  });

  testWidgets('drag down SHRINKS a bottom span', (tester) async {
    double? committed;
    await tester.pumpWidget(host(
      showSpan: true,
      side: SpanSide.bottom,
      height: 300,
      onHeightCommitted: (h) => committed = h,
    ));
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('span-drag-handle')),
      const Offset(0, 40),
    );
    await tester.pump(kSpanCommitDebounce + const Duration(milliseconds: 50));
    expect(committed, isNotNull);
    expect(committed!, lessThan(300));
  });

  testWidgets('committed height respects settings clamp floor', (tester) async {
    double? committed;
    await tester.pumpWidget(host(
      showSpan: true,
      side: SpanSide.top,
      height: kSpanMinHeight,
      onHeightCommitted: (h) => committed = h,
    ));
    await tester.pump();
    // Drag far upward (shrink below floor).
    await tester.drag(
      find.byKey(const ValueKey('span-drag-handle')),
      const Offset(0, -500),
    );
    await tester.pump(kSpanCommitDebounce + const Duration(milliseconds: 50));
    expect(committed, kSpanMinHeight);
  });

  testWidgets('height field commits on submit', (tester) async {
    double? committed;
    await tester.pumpWidget(host(
      showSpan: true,
      side: SpanSide.top,
      height: 200,
      onHeightCommitted: (h) => committed = h,
    ));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('span-height-field')),
      '250',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(committed, 250);
  });

  testWidgets('close button fires onClose', (tester) async {
    bool closed = false;
    await tester.pumpWidget(host(
      showSpan: true,
      side: SpanSide.top,
      height: 200,
      onHeightCommitted: (_) {},
      onClose: () => closed = true,
    ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('span-close-button')));
    expect(closed, isTrue);
  });

  // ── Body identity ────────────────────────────────────────────────────────
  //
  // Flutter reconciles a slot by (runtimeType, key). A build that returns the
  // body BARE in one state and wrapped in another puts two structurally
  // different Elements in the same slot, so toggling the span DISPOSES the
  // whole body subtree and inflates a fresh one — every State object in it,
  // and every unsaved edit those States hold, is gone. The failure is silent:
  // the page looks identical afterwards because it rebuilt from scratch.
  //
  // These tests assert Element identity directly (same State instance, one
  // initState) rather than "the widget is still on screen", which a remount
  // satisfies just as well.

  /// Pumps [frames] and returns the body's State, asserting it is the one
  /// created by the first pump of the test.
  _StatefulBodyState bodyState(WidgetTester tester) =>
      tester.state<_StatefulBodyState>(find.byType(_StatefulBody));

  testWidgets('body State survives pinning and unpinning a span',
      (tester) async {
    _StatefulBody.mounts = 0;

    await tester.pumpWidget(host(
      showSpan: false,
      side: SpanSide.top,
      height: 200,
      onHeightCommitted: (_) {},
      child: const _StatefulBody(),
    ));
    final _StatefulBodyState original = bodyState(tester);
    original.edit();
    await tester.pump();
    expect(find.text('unsaved: 1'), findsOneWidget);
    expect(_StatefulBody.mounts, 1);

    // Pin the span — the shape change that destroyed editor buffers.
    await tester.pumpWidget(host(
      showSpan: true,
      side: SpanSide.top,
      height: 200,
      onHeightCommitted: (_) {},
      child: const _StatefulBody(),
    ));
    await tester.pump();
    expect(find.text('span-content'), findsOneWidget);
    expect(bodyState(tester), same(original), reason: 'pin remounted the body');
    expect(find.text('unsaved: 1'), findsOneWidget);
    expect(_StatefulBody.mounts, 1, reason: 'pin re-ran initState');

    // …and unpin it again.
    await tester.pumpWidget(host(
      showSpan: false,
      side: SpanSide.top,
      height: 200,
      onHeightCommitted: (_) {},
      child: const _StatefulBody(),
    ));
    await tester.pump();
    expect(find.text('span-content'), findsNothing);
    expect(bodyState(tester), same(original),
        reason: 'unpin remounted the body');
    expect(find.text('unsaved: 1'), findsOneWidget);
    expect(_StatefulBody.mounts, 1, reason: 'unpin re-ran initState');

    // Stronger than "the State survived": the element was never uprooted, so
    // there is no reparenting window to get right. A GlobalKey anchor would
    // pass every assertion above and fail this one.
    expect(original.deactivations, 0, reason: 'body was deactivated');
  });

  testWidgets('body State survives moving a pinned span top ↔ bottom',
      (tester) async {
    _StatefulBody.mounts = 0;

    await tester.pumpWidget(host(
      showSpan: true,
      side: SpanSide.top,
      height: 200,
      onHeightCommitted: (_) {},
      child: const _StatefulBody(),
    ));
    await tester.pump();
    final _StatefulBodyState original = bodyState(tester);
    original.edit();
    await tester.pump();
    expect(_StatefulBody.mounts, 1);

    for (final SpanSide side in <SpanSide>[
      SpanSide.bottom,
      SpanSide.top,
      SpanSide.bottom,
    ]) {
      await tester.pumpWidget(host(
        showSpan: true,
        side: side,
        height: 200,
        onHeightCommitted: (_) {},
        child: const _StatefulBody(),
      ));
      await tester.pump();
      expect(bodyState(tester), same(original),
          reason: 'moving the span to $side remounted the body');
      expect(_StatefulBody.mounts, 1,
          reason: 'moving the span to $side re-ran initState');
    }

    // Re-slotted, not reparented: Flutter MOVED the element between Column
    // positions rather than dropping and retaking it.
    expect(original.deactivations, 0, reason: 'body was deactivated');

    // The re-ordered children are still laid out correctly.
    expect(
      tester.getCenter(find.text('span-content')).dy,
      greaterThan(tester.getCenter(find.byType(_StatefulBody)).dy),
    );
    expect(find.text('unsaved: 1'), findsOneWidget);
  });

  testWidgets('a host-supplied GlobalKey on the body still works',
      (tester) async {
    // The app that hit this defect worked around it with a GlobalKey of its
    // own. That workaround is now redundant, but it must not become harmful:
    // the key still identifies the body and the body still survives.
    _StatefulBody.mounts = 0;
    final GlobalKey hostKey = GlobalKey(debugLabel: 'host-workaround');

    Widget tree(bool showSpan) => host(
          showSpan: showSpan,
          side: SpanSide.top,
          height: 200,
          onHeightCommitted: (_) {},
          child: KeyedSubtree(key: hostKey, child: const _StatefulBody()),
        );

    await tester.pumpWidget(tree(false));
    final _StatefulBodyState original = bodyState(tester);
    await tester.pumpWidget(tree(true));
    await tester.pump();
    await tester.pumpWidget(tree(false));
    await tester.pump();

    expect(hostKey.currentContext, isNotNull);
    expect(bodyState(tester), same(original));
    expect(_StatefulBody.mounts, 1);
  });

  testWidgets('body cross-axis constraints are the host\'s, span or no span',
      (tester) async {
    // Two invariants, and the first is the one that keeps existing hosts
    // rendering as they do today: with no span pinned the body must see
    // EXACTLY the constraints SpanHost was handed — the old code returned the
    // child bare, so anything else is a silent reflow of every page that never
    // opens a span. The second is that opening one changes only the main axis.
    //
    // Capture real constraints, not a rendered size: a body that already
    // expands fills either way and hides the difference. Host under a TIGHT
    // box for the same reason — Scaffold's body slot is loose in width.
    late BoxConstraints outer;
    BoxConstraints? seen;
    final Widget body = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        seen = c;
        return const Text('page-body');
      },
    );

    Future<BoxConstraints> pump(bool showSpan, SpanSide side) async {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 600,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                outer = c;
                return SpanHost(
                  showSpan: showSpan,
                  side: side,
                  height: 200,
                  spanTitle: 'Pinned',
                  onHeightCommitted: (_) {},
                  spanBuilder: (_) => const Text('span-content'),
                  child: body,
                );
              },
            ),
          ),
        ),
      ));
      await tester.pump();
      return seen!;
    }

    final BoxConstraints closed = await pump(false, SpanSide.top);
    expect(closed.minWidth, outer.minWidth, reason: 'closed loosened width');
    expect(closed.maxWidth, outer.maxWidth, reason: 'closed changed width');
    expect(closed.maxHeight, outer.maxHeight, reason: 'closed lost height');

    for (final SpanSide side in SpanSide.values) {
      final BoxConstraints open = await pump(true, side);
      expect(open.minWidth, closed.minWidth, reason: '$side loosened width');
      expect(open.maxWidth, closed.maxWidth, reason: '$side changed width');
      expect(open.maxHeight, lessThan(closed.maxHeight),
          reason: '$side must cost the body main-axis extent');
    }
  });
}
