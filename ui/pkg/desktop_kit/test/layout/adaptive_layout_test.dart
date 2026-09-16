// Tests for the controlled AdaptiveLayout: mode composition, fraction clamps,
// hide-list threshold, mobile collapse, resize callbacks — and PANE IDENTITY:
// switching mode, crossing the mobile breakpoint, crossing the hide-list
// threshold, or gaining/losing a detail must never dispose a pane's Element,
// because that silently destroys every piece of unsaved state the pane holds.

import 'package:desktop_kit/desktop_kit_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pane that OWNS state, so a remount is observable rather than invisible,
/// and that FILLS whatever slot it is given, so one finder measures the SLOT
/// in every mode (a shrink-wrapping child would report its own size and hide
/// the difference between a loose and a tight slot).
///
/// Deliberately carries no key: the point of the identity tests is that a host
/// needs no `GlobalKey` of its own to keep a pane alive.
class _Pane extends StatefulWidget {
  const _Pane(this.label);

  final String label;

  /// Fresh-State count per label; reset by each identity test. A remount
  /// increments it.
  static final Map<String, int> mounts = <String, int>{};

  static int mountsOf(String label) => mounts[label] ?? 0;

  @override
  State<_Pane> createState() => _PaneState();
}

class _PaneState extends State<_Pane> {
  /// Stands in for unsaved work — an open editor buffer, a dirty form, a
  /// scroll offset, a selection.
  int unsaved = 0;

  /// Counts deactivate/activate cycles. A `GlobalKey` anchor keeps the State
  /// but still moves the element THROUGH the inactive list, so this separates
  /// "survived a reparent" from "was never uprooted".
  int deactivations = 0;

  /// Taps that actually reached this pane — a hidden pane must collect none.
  int taps = 0;

  @override
  void initState() {
    super.initState();
    _Pane.mounts.update(widget.label, (int v) => v + 1, ifAbsent: () => 1);
  }

  @override
  void deactivate() {
    deactivations += 1;
    super.deactivate();
  }

  void edit() => setState(() => unsaved += 1);

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => taps += 1,
        child: const SizedBox.expand(),
      );
}

void main() {
  Widget host({
    required LayoutMode mode,
    Widget list = const Text('list'),
    Widget? detail = const Text('detail'),
    double listFraction = 0.5,
    double detailFraction = 0.5,
    double overlayFraction = 0.4,
    ValueChanged<double>? onListFraction,
    ValueChanged<double>? onDetailFraction,
    ValueChanged<double>? onOverlayFraction,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: AdaptiveLayout(
          list: list,
          detail: detail,
          mode: mode,
          listFraction: listFraction,
          detailFraction: detailFraction,
          overlayFraction: overlayFraction,
          onListFraction: onListFraction ?? (_) {},
          onDetailFraction: onDetailFraction ?? (_) {},
          onOverlayFraction: onOverlayFraction ?? (_) {},
        ),
      ),
    );
  }

  test('LayoutMode round-trips persistence tokens', () {
    for (final LayoutMode m in LayoutMode.values) {
      expect(LayoutMode.fromValue(m.value), m);
    }
    expect(LayoutMode.fromValue('nonsense'), LayoutMode.sideBySide);
    expect(LayoutMode.fromValue(null), LayoutMode.sideBySide);
  });

  testWidgets('no detail → list fills layout', (tester) async {
    await tester.pumpWidget(host(mode: LayoutMode.sideBySide, detail: null));
    expect(find.text('list'), findsOneWidget);
    expect(find.byType(ResizeHandle), findsNothing);
  });

  testWidgets('sideBySide: list width = fraction × total; drag reports clamped',
      (tester) async {
    double? reported;
    await tester.pumpWidget(host(
      mode: LayoutMode.sideBySide,
      listFraction: 0.5,
      onListFraction: (f) => reported = f,
    ));
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    // The divider's left edge IS the list/detail boundary, so its position is
    // the fraction, measured on the thing the user drags. (This used to size
    // the SizedBox wrapping the list — an implementation detail of the Row
    // composition, and one the constant-shape build no longer has.)
    final Rect handle = tester.getRect(find.byType(ResizeHandle));
    expect(handle.left, closeTo(screen.width * 0.5, 0.01));

    // Drag the divider hard left: report clamps at 0.2.
    await tester.drag(find.byType(ResizeHandle), Offset(-screen.width, 0));
    expect(reported, isNotNull);
    expect(reported!, greaterThanOrEqualTo(0.2));
  });

  testWidgets('fullWidth: ≥ hideListAt hides the list', (tester) async {
    await tester.pumpWidget(host(
      mode: LayoutMode.fullWidth,
      detailFraction: 0.96,
    ));
    expect(find.text('list'), findsNothing);
    expect(find.text('detail'), findsOneWidget);

    await tester.pumpWidget(host(
      mode: LayoutMode.fullWidth,
      detailFraction: 0.5,
    ));
    expect(find.text('list'), findsOneWidget);
  });

  testWidgets('overlay: detail floats over full-bleed list', (tester) async {
    await tester.pumpWidget(host(mode: LayoutMode.overlay));
    expect(find.text('list'), findsOneWidget);
    expect(find.text('detail'), findsOneWidget);
    // The overlay panel is an elevated Material.
    final Iterable<Material> materials =
        tester.widgetList<Material>(find.byType(Material));
    expect(materials.map((m) => m.elevation), contains(8));
  });

  testWidgets('fullWidth and overlay report clamped drags', (tester) async {
    // Only sideBySide's callback was covered; these two are the ones whose
    // sign is easy to get backwards, and both are wired through the divider
    // rather than through the pane, so a composition change can silently swap
    // them. `tester.drag` splits a drag into slop + remainder, and the host
    // here never feeds a new fraction back, so the value reported is derived
    // from the LAST increment — enough to pin direction and clamping, not
    // arithmetic.
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    double? detailReported;
    await tester.pumpWidget(host(
      mode: LayoutMode.fullWidth,
      detailFraction: 0.5,
      onDetailFraction: (double f) => detailReported = f,
    ));
    await tester.drag(find.byType(ResizeHandle), const Offset(0, 80));
    expect(detailReported, isNotNull);
    expect(detailReported!, lessThan(0.5),
        reason: 'dragging the divider down must shrink the detail below it');
    await tester.drag(find.byType(ResizeHandle), const Offset(0, 5000));
    expect(detailReported!, closeTo(0.2, 1e-9), reason: 'detailClamp floor');

    double? overlayReported;
    await tester.pumpWidget(host(
      mode: LayoutMode.overlay,
      overlayFraction: 0.6,
      onOverlayFraction: (double f) => overlayReported = f,
    ));
    await tester.drag(find.byType(ResizeHandle), const Offset(100, 0));
    expect(overlayReported, isNotNull);
    expect(overlayReported!, lessThan(0.6),
        reason: 'dragging the floating pane\'s left edge right must narrow it');
    await tester.drag(find.byType(ResizeHandle), const Offset(-5000, 0));
    expect(overlayReported!, closeTo(0.9, 1e-9),
        reason: 'overlayClamp ceiling');
  });

  testWidgets('below mobileBreakpoint shows detail XOR list', (tester) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(mode: LayoutMode.sideBySide));
    expect(find.text('detail'), findsOneWidget);
    expect(find.text('list'), findsNothing);

    await tester.pumpWidget(host(mode: LayoutMode.sideBySide, detail: null));
    expect(find.text('list'), findsOneWidget);
  });

  // ── Pane identity ─────────────────────────────────────────────────────────
  //
  // Flutter reconciles a slot by (runtimeType, key). AdaptiveLayout used to
  // return a Row, a Stack, a Column, or a bare pane out of the same slot
  // depending on mode / detail-ness / window width, so ANY of those changes
  // put two structurally different widgets in one slot: Flutter disposed the
  // whole pane subtree and inflated a fresh one. Every State object in it —
  // scroll offsets, selections, unsaved edits — went with it, silently, since
  // the layout looks identical afterwards because it rebuilt from scratch.
  // Same defect class as SpanHost and applyUiScale.
  //
  // These tests assert Element identity directly (same State instance, one
  // initState, zero deactivations) rather than "the pane is still on screen",
  // which a remount satisfies just as well.

  /// The pane labelled [label]. `skipOffstage: false` so a HIDDEN pane is
  /// still reachable — proving it kept its State while it was not painted is
  /// the whole point of several of these tests.
  Finder pane(String label, {bool skipOffstage = false}) =>
      find.byWidgetPredicate(
        (Widget w) => w is _Pane && w.label == label,
        description: 'pane "$label"',
        skipOffstage: skipOffstage,
      );

  /// Only when painted. Whether a hidden pane is absent from the tree or
  /// merely offstage, this finds nothing — so it states "the user cannot see
  /// it" without pinning either implementation.
  Finder shownPane(String label) => pane(label, skipOffstage: true);

  _PaneState paneState(WidgetTester tester, String label) =>
      tester.state<_PaneState>(pane(label));

  Widget probeHost({
    required LayoutMode mode,
    bool withDetail = true,
    double detailFraction = 0.5,
  }) =>
      host(
        mode: mode,
        list: const _Pane('list'),
        detail: withDetail ? const _Pane('detail') : null,
        detailFraction: detailFraction,
      );

  testWidgets('both panes survive every mode transition', (tester) async {
    _Pane.mounts.clear();
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(probeHost(mode: LayoutMode.sideBySide));
    final _PaneState list = paneState(tester, 'list');
    final _PaneState detail = paneState(tester, 'detail');
    list.edit();
    detail.edit();
    await tester.pump();

    // Every ordered pair of modes, so no transition direction is untested.
    for (final LayoutMode mode in <LayoutMode>[
      LayoutMode.overlay,
      LayoutMode.sideBySide,
      LayoutMode.fullWidth,
      LayoutMode.overlay,
      LayoutMode.fullWidth,
      LayoutMode.sideBySide,
    ]) {
      await tester.pumpWidget(probeHost(mode: mode));
      await tester.pump();
      expect(paneState(tester, 'list'), same(list),
          reason: 'switching to $mode remounted the list');
      expect(paneState(tester, 'detail'), same(detail),
          reason: 'switching to $mode remounted the detail');
    }

    expect(_Pane.mountsOf('list'), 1, reason: 'the list re-ran initState');
    expect(_Pane.mountsOf('detail'), 1, reason: 'the detail re-ran initState');
    expect(list.unsaved, 1);
    expect(detail.unsaved, 1);

    // Stronger than "the State survived": neither element was ever uprooted,
    // so there is no same-frame reparenting window to get right. A GlobalKey
    // anchor would pass every assertion above and fail this one.
    expect(list.deactivations, 0, reason: 'the list was deactivated');
    expect(detail.deactivations, 0, reason: 'the detail was deactivated');
  });

  testWidgets('both panes survive crossing mobileBreakpoint', (tester) async {
    // Resizing a desktop window past the breakpoint is an ordinary gesture,
    // not a device change — and it used to swap the whole layout for a bare
    // pane.
    _Pane.mounts.clear();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(probeHost(mode: LayoutMode.sideBySide));
    final _PaneState list = paneState(tester, 'list');
    final _PaneState detail = paneState(tester, 'detail');
    list.edit();
    detail.edit();
    await tester.pump();

    for (final Size size in <Size>[
      const Size(500, 800), // handset: detail only
      const Size(1000, 800), // back to desktop
      const Size(400, 800),
      const Size(1200, 800),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(probeHost(mode: LayoutMode.sideBySide));
      await tester.pump();
      expect(paneState(tester, 'list'), same(list),
          reason: 'resizing to $size remounted the list');
      expect(paneState(tester, 'detail'), same(detail),
          reason: 'resizing to $size remounted the detail');
    }

    expect(_Pane.mountsOf('list'), 1);
    expect(_Pane.mountsOf('detail'), 1);
    expect(list.unsaved, 1);
    expect(detail.unsaved, 1);
    expect(list.deactivations, 0, reason: 'the list was deactivated');
    expect(detail.deactivations, 0, reason: 'the detail was deactivated');
  });

  testWidgets('the list survives being hidden by hideListAt', (tester) async {
    // fullWidth ≥ hideListAt drops the list from view. The detail already
    // survived that (Flutter matches the trailing children bottom-up), but the
    // list itself was disposed — so dragging the divider to the top and back
    // discarded its scroll position and selection.
    _Pane.mounts.clear();
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester
        .pumpWidget(probeHost(mode: LayoutMode.fullWidth, detailFraction: 0.5));
    final _PaneState list = paneState(tester, 'list');
    final _PaneState detail = paneState(tester, 'detail');
    list.edit();
    await tester.pump();
    expect(shownPane('list'), findsOneWidget);

    await tester.pumpWidget(
        probeHost(mode: LayoutMode.fullWidth, detailFraction: 0.96));
    await tester.pump();
    expect(shownPane('list'), findsNothing, reason: 'the list is still shown');
    expect(paneState(tester, 'list'), same(list),
        reason: 'hiding the list disposed it');
    expect(paneState(tester, 'detail'), same(detail));

    await tester
        .pumpWidget(probeHost(mode: LayoutMode.fullWidth, detailFraction: 0.5));
    await tester.pump();
    expect(shownPane('list'), findsOneWidget);
    expect(paneState(tester, 'list'), same(list));
    expect(list.unsaved, 1, reason: 'the list lost its unsaved work');
    expect(_Pane.mountsOf('list'), 1);
    expect(list.deactivations, 0, reason: 'the list was deactivated');
    expect(detail.deactivations, 0, reason: 'the detail was deactivated');
  });

  testWidgets('the list survives a detail arriving and leaving',
      (tester) async {
    // Selecting the first item — the single most common thing a user does in a
    // master-detail layout — used to swap a bare `list` for a Row and take the
    // list's scroll position and selection with it.
    _Pane.mounts.clear();
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester
        .pumpWidget(probeHost(mode: LayoutMode.sideBySide, withDetail: false));
    final _PaneState list = paneState(tester, 'list');
    list.edit();
    await tester.pump();
    expect(find.byType(ResizeHandle), findsNothing);

    for (final bool withDetail in <bool>[true, false, true]) {
      await tester.pumpWidget(
          probeHost(mode: LayoutMode.sideBySide, withDetail: withDetail));
      await tester.pump();
      expect(paneState(tester, 'list'), same(list),
          reason: 'withDetail=$withDetail remounted the list');
      expect(shownPane('detail'), withDetail ? findsOneWidget : findsNothing);
      expect(find.byType(ResizeHandle),
          withDetail ? findsOneWidget : findsNothing);
    }

    expect(_Pane.mountsOf('list'), 1);
    expect(list.unsaved, 1);
    expect(list.deactivations, 0, reason: 'the list was deactivated');
  });

  testWidgets('a hidden pane takes no input', (tester) async {
    // Keeping a hidden pane mounted is only acceptable if it is genuinely out
    // of the way. This matters in BOTH directions, and the first is a hazard
    // the constant shape introduces: with no detail, the detail's slot still
    // covers the whole area and sits ON TOP of the list in the Stack, so
    // without the `Offstage` its Material would absorb every tap meant for the
    // list. Removing that `Offstage` fails this test.
    _Pane.mounts.clear();
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester
        .pumpWidget(probeHost(mode: LayoutMode.sideBySide, withDetail: false));
    await tester.tapAt(tester.getCenter(find.byType(AdaptiveLayout)));
    await tester.pump();
    expect(paneState(tester, 'list').taps, 1,
        reason: 'the empty detail slot swallowed a tap meant for the list');

    // …and on a handset the hidden list must not take input either. Its count
    // is carried forward rather than reset: the same State survives the
    // collapse, which is the whole point, so "took no further tap" is the
    // assertion, not "has never been tapped".
    final int listTaps = paneState(tester, 'list').taps;
    tester.view.physicalSize = const Size(500, 800);
    await tester.pumpWidget(probeHost(mode: LayoutMode.sideBySide));
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.byType(AdaptiveLayout)));
    await tester.pump();
    expect(paneState(tester, 'detail').taps, 1, reason: 'the tap missed');
    expect(paneState(tester, 'list').taps, listTaps,
        reason: 'the hidden list took a tap');
  });

  // ── Geometry ──────────────────────────────────────────────────────────────
  //
  // A constant tree shape is only worth having if it renders identically. Every
  // rect below was measured against the pre-fix build (Row / Stack / Column /
  // bare pane) and is asserted unchanged, so a regression in composition shows
  // up here rather than in a consuming app.

  testWidgets('every mode lays its panes out where it always did',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const double kHandle = 6; // ResizeHandle.thickness default

    void expectRect(Rect actual, Rect expected, String what) {
      expect(actual.left, closeTo(expected.left, 0.01), reason: '$what left');
      expect(actual.top, closeTo(expected.top, 0.01), reason: '$what top');
      expect(actual.right, closeTo(expected.right, 0.01),
          reason: '$what right');
      expect(actual.bottom, closeTo(expected.bottom, 0.01),
          reason: '$what bottom');
    }

    Future<Rect> pump(Widget widget) async {
      await tester.pumpWidget(widget);
      await tester.pump();
      return tester.getRect(find.byType(AdaptiveLayout));
    }

    Rect box = await pump(probeHost(mode: LayoutMode.sideBySide));
    double split = box.left + box.width * 0.5;
    expectRect(tester.getRect(shownPane('list')),
        Rect.fromLTRB(box.left, box.top, split, box.bottom), 'sideBySide list');
    expectRect(
        tester.getRect(find.byType(ResizeHandle)),
        Rect.fromLTRB(split, box.top, split + kHandle, box.bottom),
        'sideBySide handle');
    expectRect(
        tester.getRect(shownPane('detail')),
        Rect.fromLTRB(split + kHandle, box.top, box.right, box.bottom),
        'sideBySide detail');

    box = await pump(probeHost(mode: LayoutMode.fullWidth));
    split = box.top + box.height * 0.5;
    expectRect(tester.getRect(shownPane('list')),
        Rect.fromLTRB(box.left, box.top, box.right, split), 'fullWidth list');
    expectRect(
        tester.getRect(find.byType(ResizeHandle)),
        Rect.fromLTRB(box.left, split, box.right, split + kHandle),
        'fullWidth handle');
    expectRect(
        tester.getRect(shownPane('detail')),
        Rect.fromLTRB(box.left, split + kHandle, box.right, box.bottom),
        'fullWidth detail');

    box =
        await pump(probeHost(mode: LayoutMode.fullWidth, detailFraction: 1.0));
    expect(shownPane('list'), findsNothing);
    expectRect(
        tester.getRect(find.byType(ResizeHandle)),
        Rect.fromLTRB(box.left, box.top, box.right, box.top + kHandle),
        'fullWidth (list hidden) handle');
    expectRect(
        tester.getRect(shownPane('detail')),
        Rect.fromLTRB(box.left, box.top + kHandle, box.right, box.bottom),
        'fullWidth (list hidden) detail');

    box = await pump(probeHost(mode: LayoutMode.overlay));
    split = box.right - box.width * 0.4; // overlayFraction default in probeHost
    expectRect(tester.getRect(shownPane('list')), box, 'overlay list');
    expectRect(
        tester.getRect(find.byType(ResizeHandle)),
        Rect.fromLTRB(split, box.top, split + kHandle, box.bottom),
        'overlay handle');
    expectRect(
        tester.getRect(shownPane('detail')),
        Rect.fromLTRB(split + kHandle, box.top, box.right, box.bottom),
        'overlay detail');

    box = await pump(probeHost(mode: LayoutMode.sideBySide, withDetail: false));
    expect(find.byType(ResizeHandle), findsNothing);
    expectRect(tester.getRect(shownPane('list')), box, 'no-detail list');

    tester.view.physicalSize = const Size(500, 800);
    box = await pump(probeHost(mode: LayoutMode.sideBySide));
    expect(shownPane('list'), findsNothing);
    expect(find.byType(ResizeHandle), findsNothing);
    expectRect(tester.getRect(shownPane('detail')), box, 'handset detail');

    box = await pump(probeHost(mode: LayoutMode.sideBySide, withDetail: false));
    expect(find.byType(ResizeHandle), findsNothing);
    expectRect(tester.getRect(shownPane('list')), box, 'handset list');
  });
}
