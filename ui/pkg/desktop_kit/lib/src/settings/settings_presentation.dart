// Configurable settings-presentation framework.
//
// Lets a host app declare settings "categories" (id + title + icon + content
// builder) and let the user choose, per category, HOW that category surfaces:
//   • inline      — embedded directly in the host page;
//   • popup       — an AlertDialog;
//   • bottomSheet — a modal bottom sheet ("Sliding sheet");
//   • topSpan     — pinned, resizable strip at the top of the host page;
//   • bottomSpan  — pinned, resizable strip at the bottom of the host page;
//
// The chosen mode per category is a plain enum value; pure encode/decode
// helpers turn the per-category map into JSON-friendly data so the host can
// persist it via the existing SettingsStore.  Nothing here depends on a
// state-management library — the tile is "controlled" (mode + onModeChanged
// passed in), so the host owns the state and persistence.
//
// The span modes are LAYOUT-INTEGRATED, not overlays: the host mounts a
// `SpanHost` (desktop_kit_layout.dart) around its page body and pins the
// category's content there. `openSettingsCategory` therefore treats them like
// inline — a no-op — and `SettingsCategoryTile` exposes an `onActivateSpan`
// callback the host wires to its SpanHost state.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// How a [SettingsCategory]'s content is surfaced to the user.
enum SettingsPresentation {
  /// Embedded directly in the host page (the host renders it inline).
  inline,

  /// Shown in an [AlertDialog] via [showDialog].
  popup,

  /// Shown in a modal bottom sheet via [showModalBottomSheet].
  ///
  /// Labelled "Sliding sheet". The enum member name is retained for
  /// backward-compatibility of persisted `.name` tokens — renaming it would
  /// silently reset every user who had persisted `"bottomSheet"`.
  bottomSheet,

  /// Pinned, resizable strip at the TOP of the host page (layout-integrated;
  /// host embeds via a `SpanHost`).
  topSpan,

  /// Pinned, resizable strip at the BOTTOM of the host page.
  bottomSpan;

  /// A human-readable label for this presentation (for buttons/menus).
  String get label {
    switch (this) {
      case SettingsPresentation.inline:
        return 'Inline';
      case SettingsPresentation.popup:
        return 'Popup';
      case SettingsPresentation.bottomSheet:
        return 'Sliding sheet';
      case SettingsPresentation.topSpan:
        return 'Top span';
      case SettingsPresentation.bottomSpan:
        return 'Bottom span';
    }
  }

  /// An icon for this presentation (for segmented buttons / menus).
  IconData get icon {
    switch (this) {
      case SettingsPresentation.inline:
        return Icons.view_stream_outlined;
      case SettingsPresentation.popup:
        return Icons.open_in_new_outlined;
      case SettingsPresentation.bottomSheet:
        return Icons.swipe_up_alt_outlined;
      case SettingsPresentation.topSpan:
        return Icons.vertical_align_top;
      case SettingsPresentation.bottomSpan:
        return Icons.vertical_align_bottom;
    }
  }

  /// Parses a persisted [name] back into a [SettingsPresentation].
  ///
  /// Unknown / malformed values fall back to [SettingsPresentation.inline] so a
  /// corrupt or forward-incompatible config never throws. Persist with
  /// [Enum.name] (`mode.name`) and round-trip with this.
  ///
  /// The retired `popover` mode migrates to [SettingsPresentation.bottomSheet]
  /// rather than taking the unknown-value path: it was a real, selectable mode,
  /// and plenty of configs persist it (including as the app-wide `"*"`
  /// default). Letting it fall through to [inline] would silently strand those
  /// users on a mode that renders nothing when they ask a category to open.
  static SettingsPresentation fromName(String name) {
    if (name == _retiredPopover) return SettingsPresentation.bottomSheet;
    for (final SettingsPresentation p in SettingsPresentation.values) {
      if (p.name == name) return p;
    }
    return SettingsPresentation.inline;
  }

  /// Persisted token of the removed anchored-popover mode. Retained purely so
  /// [fromName] can migrate old configs; see that method.
  static const String _retiredPopover = 'popover';
}

/// Size overrides for the non-inline presentations of a [SettingsCategory].
///
/// The defaults reproduce the framework's historical fixed sizes, so a category
/// that omits [SettingsCategory.size] renders exactly as before. Override it per
/// category (a keymap editor wants a roomier popup than an About blurb) or pass
/// one to [openSettingsCategory] to override at the call site.
@immutable
class SettingsPanelSize {
  /// Create a size spec. Every field defaults to the framework's prior constant.
  const SettingsPanelSize({
    this.popupWidth = 480,
    this.popupMaxHeight,
    this.popupMaxHeightFraction,
    this.sheetInitialSize = 0.55,
    this.sheetMinSize = 0.3,
    this.sheetMaxSize = 0.9,
  });

  /// Width (logical px) of the [SettingsPresentation.popup] dialog body.
  final double popupWidth;

  /// Optional max height (logical px) of the popup body; content scrolls within
  /// it. `null` = content-driven up to the dialog's own max (the prior default).
  final double? popupMaxHeight;

  /// Optional max popup-body height as a fraction (0–1) of the window height —
  /// e.g. `1.0` for a full-window-height popup. When set it overrides
  /// [popupMaxHeight] and the dialog uses a tighter inset so it can fill.
  final double? popupMaxHeightFraction;

  /// [SettingsPresentation.bottomSheet] initial height as a fraction (0–1) of
  /// the available height.
  final double sheetInitialSize;

  /// Minimum draggable sheet height fraction.
  final double sheetMinSize;

  /// Maximum draggable sheet height fraction.
  final double sheetMaxSize;

  /// The framework defaults (the historical fixed sizes).
  static const SettingsPanelSize defaults = SettingsPanelSize();
}

/// Resolves the effective presentation from an [explicit] (nullable) user
/// choice, falling back to a per-form-factor default: [isHandheld] devices
/// get [SettingsPresentation.bottomSheet] (a sheet is the natural handheld
/// surface), desktop gets [SettingsPresentation.popup].
///
/// Desktop used to default to the anchored popover. That mode is gone: a
/// category's content may open dialogs of its own (the keymap editor's chord
/// capture is the case that broke), and a popover was a hand-inserted
/// [OverlayEntry], which outranks any route pushed afterwards — so the child
/// dialog rendered *underneath* the card that opened it. Both survivors here
/// are routes, so pushing stacks predictably.
///
/// Mirrors word-bank's `resolveLookupStyle` — store the user's choice as
/// nullable ("no explicit choice") and layer it over this responsive default.
SettingsPresentation resolvePresentation(
  SettingsPresentation? explicit, {
  required bool isHandheld,
}) {
  return explicit ??
      (isHandheld
          ? SettingsPresentation.bottomSheet
          : SettingsPresentation.popup);
}

/// A single settings "category": a titled, icon'd section whose body is built
/// on demand by [content], with a [defaultPresentation] used until the user
/// (and the persisted config) say otherwise.
///
/// Categories are pure data + a [WidgetBuilder]; they hold no state.
class SettingsCategory {
  /// Creates a settings category.
  ///
  /// [id] is the stable key used for persistence (it must be unique within an
  /// app and survive renames of [title]).
  const SettingsCategory({
    required this.id,
    required this.title,
    required this.icon,
    required this.content,
    this.defaultPresentation = SettingsPresentation.inline,
    this.size = const SettingsPanelSize(),
    this.showTitle = true,
    this.allowedModes,
  });

  /// Stable persistence key (e.g. `'appearance'`).
  final String id;

  /// Human-readable heading (e.g. `'Appearance'`).
  final String title;

  /// Leading icon for the category row.
  final IconData icon;

  /// Builds the category's body on demand.
  final WidgetBuilder content;

  /// Presentation used when the user has not chosen one (and nothing is
  /// persisted for this category).
  final SettingsPresentation defaultPresentation;

  /// Size overrides for the popup / bottom-sheet presentations. Defaults to the
  /// framework's historical fixed sizes ([SettingsPanelSize.defaults]).
  final SettingsPanelSize size;

  /// Whether the popup / bottom-sheet draws the framework title bar. Set false
  /// when the category's [content] renders its own header (e.g. a keymap editor
  /// with a consolidated title row), to avoid a doubled title.
  final bool showTitle;

  /// The presentations this category may use; `null` means all of
  /// [SettingsPresentation.values]. A category can e.g. exclude the span
  /// modes when its content doesn't suit a pinned strip.
  final List<SettingsPresentation>? allowedModes;

  /// Effective allowed modes (never empty; falls back to all values).
  List<SettingsPresentation> get effectiveModes {
    final List<SettingsPresentation>? m = allowedModes;
    if (m == null || m.isEmpty) return SettingsPresentation.values;
    return m;
  }
}

/// Opens [category] using the given presentation [mode].
///
/// - [SettingsPresentation.popup] → a scrollable [AlertDialog] titled with
///   [SettingsCategory.title], body = `category.content(context)`, plus a
///   "Close" action.
/// - [SettingsPresentation.bottomSheet] → a scrollable [showModalBottomSheet]
///   with a drag handle and the title.
/// - [SettingsPresentation.inline] → a no-op: inline content is embedded by the
///   host (e.g. via [SettingsCategoryTile]); there is nothing to "open".
///
/// Returns when the dialog/sheet is dismissed (immediately for inline).
///
/// ### Sheet stacking & Escape-to-pop (desktop)
///
/// The `bottomSheet` sheet is a normal [showModalBottomSheet] route, so calling
/// [openSettingsCategory] again (with `bottomSheet`) from *inside* a sheet's
/// content pushes another sheet onto the [Navigator] — the sheets **stack**,
/// each drawn over the last. This is the "stack of sheets" model: a category can
/// open a sub-category on top of itself.
///
/// To make the stack keyboard-navigable on desktop, the sheet content is wrapped
/// in a focused [FocusScope] + [CallbackShortcuts] binding
/// [LogicalKeyboardKey.escape] to [NavigatorState.maybePop]. Pressing **Escape**
/// pops the **top** sheet and reveals the one beneath it (or the host page when
/// the stack empties). `maybePop` is used so the Escape handler cooperates with
/// any `WillPopScope`/`PopScope` a category installs. On touch platforms the
/// drag handle / scrim tap remain the primary dismissal; Escape is the desktop
/// affordance layered on top.
///
/// [size] overrides [SettingsCategory.size] for this call (e.g. a host that
/// wants the same category larger in one place). When omitted, the category's
/// own [SettingsCategory.size] is used.
Future<void> openSettingsCategory(
  BuildContext context,
  SettingsCategory category,
  SettingsPresentation mode, {
  SettingsPanelSize? size,
}) async {
  final SettingsPanelSize s = size ?? category.size;
  switch (mode) {
    case SettingsPresentation.inline:
      // Inline is embedded by the host, not opened.
      return;
    case SettingsPresentation.topSpan:
    case SettingsPresentation.bottomSpan:
      // Span modes are layout-integrated: the host mounts a SpanHost around
      // its body and pins the category there (see SettingsCategoryTile's
      // onActivateSpan). Nothing to "open" as a route/overlay.
      return;
    case SettingsPresentation.popup:
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) {
          final double? frac = s.popupMaxHeightFraction;
          if (frac != null) {
            // Deterministic full-size popup: an explicit width × (fraction of
            // the window height) Dialog whose body scrolls. Unlike an
            // AlertDialog it does NOT shrink to its content, so the size is
            // exactly what was asked for. When [showTitle] is false the content
            // owns its own header/close (e.g. a keymap editor toolbar).
            return Dialog(
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: s.popupWidth,
                height: MediaQuery.of(ctx).size.height * frac,
                child: category.showTitle
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    category.title,
                                    style: Theme.of(ctx).textTheme.titleLarge,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close),
                                  tooltip: 'Close',
                                  onPressed: () => Navigator.of(ctx).pop(),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: SingleChildScrollView(
                              child: category.content(ctx),
                            ),
                          ),
                        ],
                      )
                    : SingleChildScrollView(child: category.content(ctx)),
              ),
            );
          }
          return AlertDialog(
            title: category.showTitle ? Text(category.title) : null,
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: s.popupMaxHeight ?? double.infinity,
              ),
              child: SingleChildScrollView(
                child: SizedBox(
                  width: s.popupWidth,
                  child: category.content(ctx),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
      return;
    case SettingsPresentation.bottomSheet:
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        // Wrap the sheet body so Escape pops THIS sheet (revealing the one
        // beneath, when sheets are stacked). See the doc comment above.
        builder: (BuildContext ctx) => EscapeToPop(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: s.sheetInitialSize,
            minChildSize: s.sheetMinSize,
            maxChildSize: s.sheetMaxSize,
            builder: (BuildContext ctx2, ScrollController sc) => ListView(
              controller: sc,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                if (category.showTitle)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      category.title,
                      style: Theme.of(ctx2).textTheme.titleLarge,
                    ),
                  ),
                category.content(ctx2),
              ],
            ),
          ),
        ),
      );
      return;
  }
}

/// Wraps sheet content so **Escape** pops the top sheet on desktop.
///
/// Public so hosts that open their OWN sheet — rather than going through
/// [openSettingsCategory] — get identical Escape behaviour instead of a sheet
/// that silently ignores the key. A root sheet lacking this wrapper is
/// indistinguishable from broken: every category stacked on top of it closes
/// on Escape, and only the last one refuses.
///
/// Installs a focused [FocusScope] (so the shortcut receives key events without
/// the user first clicking inside) and a [CallbackShortcuts] binding
/// [LogicalKeyboardKey.escape] → [NavigatorState.maybePop]. Because each
/// [showModalBottomSheet] is its own route, popping via the [BuildContext]
/// captured here dismisses exactly this sheet; a sheet opened from within it
/// sits higher on the [Navigator] and is popped first — so repeated Escape
/// unwinds a stack of sheets one at a time.
///
/// [maybePop] (not [pop]) is used so any `PopScope`/`WillPopScope` a category
/// installs can still veto or intercept the dismissal.
class EscapeToPop extends StatelessWidget {
  const EscapeToPop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: FocusScope(
        autofocus: true,
        child: child,
      ),
    );
  }
}

/// A controlled row for one [SettingsCategory].
///
/// Shows the category's icon + title and a [SegmentedButton] for choosing the
/// presentation [mode]. When [mode] is [SettingsPresentation.inline] it renders
/// `category.content(context)` embedded (in an [ExpansionTile]); otherwise it
/// shows an "Open …" button that calls [openSettingsCategory].
///
/// This widget is *controlled*: it holds no state of its own. The host passes
/// the current [mode] and an [onModeChanged] callback, so the host owns both
/// the state and any persistence (e.g. via a SettingsStore). That keeps the
/// framework state-management agnostic.
class SettingsCategoryTile extends StatelessWidget {
  /// Creates a controlled settings-category row.
  const SettingsCategoryTile({
    super.key,
    required this.category,
    required this.mode,
    required this.onModeChanged,
    this.initiallyExpanded = true,
    this.onActivateSpan,
    this.spanActive = false,
  });

  /// The category this row represents.
  final SettingsCategory category;

  /// The currently selected presentation for [category].
  final SettingsPresentation mode;

  /// Called when the user picks a different presentation.
  final ValueChanged<SettingsPresentation> onModeChanged;

  /// Whether the inline [ExpansionTile] starts expanded (inline mode only).
  final bool initiallyExpanded;

  /// Host hook for the span modes: called when the user asks to pin this
  /// category as a top/bottom span. The host wires this to its page-level
  /// `SpanHost` state (which category is pinned + on which side). Required
  /// for [SettingsPresentation.topSpan]/[SettingsPresentation.bottomSpan] to
  /// do anything; when null the span "Open" button is disabled.
  final void Function(SettingsCategory category, SettingsPresentation side)?
      onActivateSpan;

  /// Whether this category is currently pinned in the host's span (drives the
  /// button label "Pinned"/"Pin here").
  final bool spanActive;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget selector = _PresentationSelector(
      mode: mode,
      onModeChanged: onModeChanged,
      options: category.effectiveModes,
    );

    if (mode == SettingsPresentation.inline) {
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: ExpansionTile(
          // A ValueKey, NOT a PageStorageKey. A PageStorageKey here makes the
          // ExpansionTile persist its expanded *bool* into the PageStorage
          // bucket that inner scrollables (e.g. a multi-line TextField in a
          // category's content) then read back as a scroll-offset *double* —
          // throwing "type 'bool' is not a subtype of type 'double?'" the moment
          // the section is expanded. A ValueKey keeps stable list identity
          // without sharing a PageStorage bucket with descendant scrollables.
          key: ValueKey<String>('settings_category_${category.id}'),
          initiallyExpanded: initiallyExpanded,
          leading: Icon(category.icon),
          title: Text(category.title, style: theme.textTheme.titleMedium),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: selector,
            ),
            const SizedBox(height: 12),
            category.content(context),
          ],
        ),
      );
    }

    // Span modes: header + selector + a "Pin here" affordance the host wires
    // to its page-level SpanHost. The content itself renders inside the span,
    // not in this tile.
    final bool isSpan = mode == SettingsPresentation.topSpan ||
        mode == SettingsPresentation.bottomSpan;

    // Non-inline: header row + selector + an "Open …" / "Pin …" button.
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(category.icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    category.title,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            selector,
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: isSpan
                  ? FilledButton.tonalIcon(
                      icon: Icon(mode.icon, size: 18),
                      onPressed: onActivateSpan == null
                          ? null
                          : () => onActivateSpan!(category, mode),
                      label: Text(
                        spanActive
                            ? 'Pinned as ${mode.label.toLowerCase()}'
                            : 'Pin as ${mode.label.toLowerCase()}',
                      ),
                    )
                  : _AnchoredOpenButton(category: category, mode: mode),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "Open …" button for the popup / sliding-sheet modes.
///
/// Formerly wrapped in a [GestureDetector] that recorded the press position, so
/// the anchored popover could open at the button. That mode is gone and with it
/// the only consumer of a tap anchor.
class _AnchoredOpenButton extends StatelessWidget {
  const _AnchoredOpenButton({required this.category, required this.mode});

  final SettingsCategory category;
  final SettingsPresentation mode;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(
      onPressed: () => openSettingsCategory(context, category, mode),
      child: Text('Open ${category.title}'),
    );
  }
}

/// The shared presentation picker.
///
/// Renders a [SegmentedButton] while there are ≤ [kSelectorSegmentLimit]
/// options; beyond that a [DropdownButton] — segments don't scale past ~4
/// (word-bank hit the same wall and switched to a dropdown at 5 styles).
class _PresentationSelector extends StatelessWidget {
  const _PresentationSelector({
    required this.mode,
    required this.onModeChanged,
    this.options = SettingsPresentation.values,
  });

  final SettingsPresentation mode;
  final ValueChanged<SettingsPresentation> onModeChanged;
  final List<SettingsPresentation> options;

  /// Above this many options the selector switches to a dropdown.
  static const int kSelectorSegmentLimit = 4;

  @override
  Widget build(BuildContext context) {
    // The current mode must always be selectable, even if a category's
    // allowedModes shrank after the pref was persisted.
    final List<SettingsPresentation> opts = options.contains(mode)
        ? options
        : <SettingsPresentation>[...options, mode];

    if (opts.length <= kSelectorSegmentLimit) {
      return SegmentedButton<SettingsPresentation>(
        segments: [
          for (final SettingsPresentation p in opts)
            ButtonSegment<SettingsPresentation>(
              value: p,
              label: Text(p.label),
              icon: Icon(p.icon),
            ),
        ],
        selected: {mode},
        onSelectionChanged: (Set<SettingsPresentation> selected) {
          if (selected.isNotEmpty) onModeChanged(selected.first);
        },
      );
    }

    return DropdownButton<SettingsPresentation>(
      value: mode,
      onChanged: (SettingsPresentation? p) {
        if (p != null) onModeChanged(p);
      },
      items: [
        for (final SettingsPresentation p in opts)
          DropdownMenuItem<SettingsPresentation>(
            value: p,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(p.icon, size: 18),
                const SizedBox(width: 8),
                Text(p.label),
              ],
            ),
          ),
      ],
    );
  }
}

// ── Pure persistence helpers ─────────────────────────────────────────────────

/// Encodes a per-category presentation map into a JSON-friendly map.
///
/// Keys are category ids; values are [SettingsPresentation.name] strings — so
/// the result can be handed straight to a SettingsStore. Pure: no I/O.
Map<String, dynamic> encodePresentationPrefs(
  Map<String, SettingsPresentation> prefs,
) {
  return <String, dynamic>{
    for (final MapEntry<String, SettingsPresentation> e in prefs.entries)
      e.key: e.value.name,
  };
}

/// Decodes a persisted object back into a per-category presentation map.
///
/// Defensive by design — anything that is not a `Map` with string keys and
/// string values is skipped, and unknown presentation names fall back to
/// [SettingsPresentation.inline] (via [SettingsPresentation.fromName]). Bad or
/// absent input yields an empty map; never throws. Pure: no I/O.
Map<String, SettingsPresentation> decodePresentationPrefs(Object? raw) {
  final Map<String, SettingsPresentation> out =
      <String, SettingsPresentation>{};
  if (raw is! Map) return out;
  raw.forEach((Object? key, Object? value) {
    if (key is String && value is String) {
      out[key] = SettingsPresentation.fromName(value);
    }
  });
  return out;
}
