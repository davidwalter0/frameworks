// Master-detail layout with three user-selectable modes and drag-resizable
// panes — the desktop "list + detail" workhorse.
//
// Promoted from task-board's app-local AdaptiveLayout (itself a 1:1 port of the
// Angular TasksLayoutComponent), refactored to a CONTROLLED widget per the kit
// rule: the host passes the mode + pane fractions and receives onChanged
// callbacks; the kit holds no state and no persistence. A host typically
// wraps this in its own Notifier + SettingsStore glue.
//
// Modes (fraction clamps mirror the Angular prototype):
//  * sideBySide — list (listFraction of width, clamp 0.2–0.8) | handle |
//    detail.
//  * overlay    — detail floats over the list from the right at
//    overlayFraction of width (clamp 0.4–0.9), elevation 8, resizable from
//    its left edge.
//  * fullWidth  — list over detail, detailFraction of height (clamp 0.2–1.0);
//    at ≥ hideListAt (default 0.95) the list is hidden ("fully expanded
//    detail").
//
// Below [mobileBreakpoint] the layout collapses to detail-XOR-list.
//
// All four are ONE tree shape with different numbers — see the AdaptiveLayout
// doc for why that is a correctness requirement and not a refactor.

import 'package:flutter/material.dart';

import 'resize_handle.dart';

/// Elevation of the floating detail pane in [LayoutMode.overlay].
const double _kOverlayElevation = 8;

/// Stable identities for the two [Stack] slots. Unkeyed children are matched
/// by POSITION and both slots are `Positioned`, so reordering them — the
/// obvious way to change paint order — would pair the list against the detail,
/// pass `Widget.canUpdate`, and then dispose both subtrees one level down.
/// With keys the same edit is a re-slot. See the [AdaptiveLayout] doc.
const Key _kListSlot = ValueKey<String>('adaptive-layout-list');
const Key _kDetailSlot = ValueKey<String>('adaptive-layout-detail');

/// The three master-detail layout modes.
enum LayoutMode {
  sideBySide('side-by-side', 'Side-by-Side', Icons.view_column),
  overlay('overlay', 'Overlay', Icons.layers),
  fullWidth('full-width', 'Full Width', Icons.view_stream);

  const LayoutMode(this.value, this.label, this.icon);

  /// Stable persistence token.
  final String value;

  /// Human-readable label (for segmented buttons / menus).
  final String label;

  /// Icon for pickers.
  final IconData icon;

  /// Parses a persisted [value]; unknown/null falls back to [sideBySide].
  static LayoutMode fromValue(String? value) => LayoutMode.values.firstWhere(
        (LayoutMode m) => m.value == value,
        orElse: () => LayoutMode.sideBySide,
      );
}

/// An inclusive (min, max) clamp range for a pane fraction.
typedef FractionClamp = (double, double);

/// Controlled master-detail layout. See library doc for mode semantics.
///
/// ## Both panes keep their Element identity — the host needs no keys
///
/// Switching [mode], crossing [mobileBreakpoint] by resizing the window,
/// crossing [hideListAt], and gaining or losing a [detail] all preserve the
/// Element of [list] and of [detail], and with them every State object,
/// scroll offset, selection, focus and unsaved edit those panes hold. That is
/// a guarantee of this widget, not a requirement on the host: **a host does
/// not have to wrap its panes in `GlobalKey`s to survive a layout change.**
///
/// It is a guarantee that has to be BUILT, not assumed, and getting it wrong
/// is invisible. Flutter reconciles a slot by `(runtimeType, key)`, so the
/// obvious build — a `Row` for side-by-side, a `Stack` for overlay, a `Column`
/// for full-width, and a bare pane on a handset — put four structurally
/// different widgets in one slot. Every mode switch, and every drag of a
/// window edge past the breakpoint, therefore disposed both pane subtrees and
/// inflated fresh ones. Nothing looks broken afterwards, because the layout
/// rebuilt itself from scratch; only the state it silently dropped is gone.
/// The same shortcut cost a consuming app every open editor buffer, unsaved
/// edits included, when a settings panel was opened (`SpanHost`, 2026-08-09).
///
/// ### One shape, four sets of numbers
///
/// The spine below is built for every mode, every width and with or without a
/// detail:
///
/// ```
/// LayoutBuilder > Stack > Positioned > Offstage > list
///                       > Positioned > Offstage > Material > Flex >
///                             Offstage > ResizeHandle
///                             Expanded > detail
/// ```
///
/// What varies is only parameters:
///
///  * **the two slot rects** — side-by-side splits the width, full-width
///    splits the height, overlay gives the list the whole area and floats the
///    detail band over its right edge, and the collapsed cases give one pane
///    everything;
///  * **the [Flex]'s `direction`** — `Row` and `Column` are two SUBCLASSES of
///    [Flex], so they are two runtimeTypes and swapping them remounts; [Flex]
///    itself with a varying `direction` is one. That single substitution is
///    what turns side-by-side ↔ full-width from a shape change into a
///    parameter change, and it is why this widget needs neither a `GlobalKey`
///    nor any state of its own;
///  * **the [Material]'s `elevation`** — 8 while the detail floats, 0 (over a
///    transparent colour, so it paints nothing) otherwise;
///  * **`Offstage`** for a pane the mode does not show. A hidden pane keeps
///    its slot and its State; it is simply not painted, hit-tested, or exposed
///    to semantics. That is the same trade `IndexedStack` makes.
///
/// A `GlobalKey` anchor is the other way to survive this, and needs the widget
/// to become stateful to own stable keys. It is strictly weaker: it REPAIRS
/// the damage rather than preventing it — every State in the subtree still
/// gets `deactivate()`/`activate()` and the render subtree is detached and
/// re-attached — and it only works while the old and new locations are built
/// in the SAME frame. A host may still pass one; it is harmless, and inert.
///
/// ### What a host must know
///
/// * **Every transition this widget makes is state-preserving**, including the
///   ones that remove a pane from view (`hideListAt`, the handset collapse).
///   A pane may hold unsaved work safely.
/// * **The one thing this cannot preserve is a pane the host stops supplying.**
///   Passing `detail: null` destroys the detail's Element, because there is no
///   longer a widget to keep alive; so does swapping a pane for a widget of a
///   different type. Both are the host's own decision, and a host that must
///   survive them keeps the state above this widget rather than inside the
///   pane.
/// * **Hidden panes stay mounted and are still laid out** — only paint, hit
///   testing and semantics are skipped. A pane that must stop work when it is
///   not visible needs to be told; this widget cannot tell it.
/// * **The box handed to an AdaptiveLayout must be bounded in both axes.**
///   Three of the four modes already required it (they multiply
///   `constraints.maxWidth` / `maxHeight` by a fraction); the constant shape
///   extends that to the collapsed cases, which used to return a bare pane.
/// * **Each pane is given its slot's constraints, tight in both axes**, in
///   every mode. The `Row`/`Column` build left the cross axis loose, so a
///   pane that shrink-wraps was centred in it; a pane that fills — the normal
///   case, and every pane in the collapsed cases — is laid out identically.
class AdaptiveLayout extends StatelessWidget {
  const AdaptiveLayout({
    super.key,
    required this.list,
    this.detail,
    required this.mode,
    required this.listFraction,
    required this.detailFraction,
    required this.overlayFraction,
    required this.onListFraction,
    required this.onDetailFraction,
    required this.onOverlayFraction,
    this.listClamp = const (0.2, 0.8),
    this.detailClamp = const (0.2, 1.0),
    this.overlayClamp = const (0.4, 0.9),
    this.mobileBreakpoint = 600,
    this.hideListAt = 0.95,
  });

  /// The list (master) pane.
  final Widget list;

  /// The detail pane; when null the list fills the layout.
  final Widget? detail;

  /// Active layout mode (host-owned).
  final LayoutMode mode;

  /// Pane fractions (host-owned, persisted by the host).
  final double listFraction;
  final double detailFraction;
  final double overlayFraction;

  /// Change callbacks — the host clamps (using the same clamps passed here),
  /// stores, and rebuilds. Values reported are already clamped.
  final ValueChanged<double> onListFraction;
  final ValueChanged<double> onDetailFraction;
  final ValueChanged<double> onOverlayFraction;

  /// Clamp ranges applied to drag updates before reporting.
  final FractionClamp listClamp;
  final FractionClamp detailClamp;
  final FractionClamp overlayClamp;

  /// Below this width the layout is detail-XOR-list.
  final double mobileBreakpoint;

  /// In [LayoutMode.fullWidth], a detailFraction at or above this hides the
  /// list entirely.
  final double hideListAt;

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    final bool isHandset = size.width < mobileBreakpoint;
    final Widget? d = detail;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final _Panes panes = _resolve(
          constraints,
          isHandset: isHandset,
          hasDetail: d != null,
        );

        // One shape for every mode. Returning a Row / Stack / Column / bare
        // pane from here — which reads as the natural way to write this — puts
        // structurally different widgets in the same slot, and Flutter answers
        // by disposing both panes. See the class doc for the incident.
        return Stack(
          children: <Widget>[
            Positioned.fromRect(
              key: _kListSlot,
              rect: panes.listRect,
              child: Offstage(offstage: !panes.showList, child: list),
            ),
            Positioned.fromRect(
              key: _kDetailSlot,
              rect: panes.detailRect,
              child: Offstage(
                offstage: !panes.showDetail,
                child: Material(
                  // Present in every mode so the detail's ancestors never
                  // change; inert unless the detail floats. `Duration.zero`
                  // keeps a mode switch instantaneous — the implicit default
                  // would cross-fade the surface colour over 200ms and show
                  // the list through a half-built overlay.
                  animationDuration: Duration.zero,
                  elevation: panes.elevated ? _kOverlayElevation : 0,
                  color: panes.elevated ? null : Colors.transparent,
                  child: Flex(
                    // horizontal = list beside detail, vertical = list above
                    // it. Written as Row/Column these are two runtimeTypes and
                    // the switch remounts the detail; as one Flex the axis is
                    // an argument.
                    direction: panes.axis,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Offstage(
                        offstage: !panes.showHandle,
                        child: ResizeHandle(
                          axis: panes.axis,
                          onResize: panes.onResize,
                        ),
                      ),
                      // `detail` is null only while the detail slot is hidden,
                      // so the placeholder is never seen.
                      Expanded(child: d ?? const SizedBox.shrink()),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  double _clamp(double v, FractionClamp c) => v.clamp(c.$1, c.$2);

  /// Where the panes go for the current inputs. This is the whole of the
  /// mode-dependent behaviour: everything the modes used to disagree about is
  /// a value returned from here.
  _Panes _resolve(
    BoxConstraints constraints, {
    required bool isHandset,
    required bool hasDetail,
  }) {
    final double w = constraints.maxWidth;
    final double h = constraints.maxHeight;
    final Rect whole = Rect.fromLTWH(0, 0, w, h);

    // Detail-XOR-list. A handset shows the detail when there is one; with no
    // detail every mode shows the list alone. The pane that is not shown keeps
    // its slot rather than being dropped, which is what lets a window resize
    // across the breakpoint — an ordinary gesture on a desktop — stop
    // discarding the list.
    if (isHandset || !hasDetail) {
      final bool detailOnly = isHandset && hasDetail;
      return _Panes(
        listRect: whole,
        showList: !detailOnly,
        detailRect: whole,
        showDetail: detailOnly,
        axis: Axis.horizontal,
        showHandle: false,
        elevated: false,
      );
    }

    switch (mode) {
      case LayoutMode.sideBySide:
        final double listWidth = w * _clamp(listFraction, listClamp);
        return _Panes(
          listRect: Rect.fromLTRB(0, 0, listWidth, h),
          showList: true,
          detailRect: Rect.fromLTRB(listWidth, 0, w, h),
          showDetail: true,
          axis: Axis.horizontal,
          showHandle: true,
          elevated: false,
          onResize: (double delta) => onListFraction(
            _clamp(listFraction + delta / w, listClamp),
          ),
        );

      case LayoutMode.overlay:
        final double overlayWidth = w * _clamp(overlayFraction, overlayClamp);
        return _Panes(
          listRect: whole,
          showList: true,
          detailRect: Rect.fromLTRB(w - overlayWidth, 0, w, h),
          showDetail: true,
          axis: Axis.horizontal,
          showHandle: true,
          elevated: true,
          onResize: (double delta) => onOverlayFraction(
            _clamp(overlayFraction - delta / w, overlayClamp),
          ),
        );

      case LayoutMode.fullWidth:
        final double frac = _clamp(detailFraction, detailClamp);
        // At/above the hide threshold the detail takes the whole area.
        final bool showList = frac < hideListAt;
        final double listHeight = h * (1 - frac);
        return _Panes(
          // A hidden pane is laid out at the layout's full extent rather than
          // at the sliver it would have had, so nothing downstream has to cope
          // with a degenerate box it will never be seen in.
          listRect: showList ? Rect.fromLTRB(0, 0, w, listHeight) : whole,
          showList: showList,
          detailRect: Rect.fromLTRB(0, showList ? listHeight : 0, w, h),
          showDetail: true,
          axis: Axis.vertical,
          showHandle: true,
          elevated: false,
          onResize: (double delta) => onDetailFraction(
            _clamp(frac - delta / h, detailClamp),
          ),
        );
    }
  }
}

/// The resolved presentation for one build: where each pane sits, whether it
/// is painted, which way the divider runs, and what a drag on it reports.
///
/// Every [LayoutMode] — plus the handset collapse and the no-detail case — is
/// a different instance of this, not a different widget tree. Keeping the
/// mode-dependent part a value rather than a build method is what makes the
/// constant shape checkable by reading one function.
class _Panes {
  const _Panes({
    required this.listRect,
    required this.showList,
    required this.detailRect,
    required this.showDetail,
    required this.axis,
    required this.showHandle,
    required this.elevated,
    this.onResize = _ignore,
  });

  /// Slot rects, in the layout's own coordinates.
  final Rect listRect;
  final Rect detailRect;

  /// Whether each pane is painted. A pane that is not shown keeps its slot,
  /// its Element and its State.
  final bool showList;
  final bool showDetail;

  /// Direction of the divider-plus-detail flex, and the [ResizeHandle]'s axis.
  final Axis axis;

  /// False in the collapsed cases, which have nothing to resize.
  final bool showHandle;

  /// Only [LayoutMode.overlay] floats the detail above the list.
  final bool elevated;

  /// Reports a drag on the divider, already clamped. Never called while
  /// [showHandle] is false: an offstage handle fails hit-testing.
  final void Function(double delta) onResize;

  static void _ignore(double _) {}
}
