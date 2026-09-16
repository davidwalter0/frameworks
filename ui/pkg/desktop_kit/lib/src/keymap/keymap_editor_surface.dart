// Presentation surfaces for [KeymapEditor].
//
// [KeymapEditor] is a controlled widget (value + onChanged). This surface wraps
// it in one of four presentations so a host only has to pick a mode + supply the
// controlled params — the reusable, app-agnostic "how to show the editor" logic
// lives here in the kit rather than being reimplemented per app.
library;

import 'package:flutter/material.dart';

import '../settings/settings_presentation.dart';
import '../widgets/foldable.dart';
import 'keymap_config.dart';
import 'keymap_editor.dart';
import 'keymap_mode.dart';
import 'keymap_registry.dart';

/// How a [KeymapEditorSurface] renders the [KeymapEditor]:
/// - [inline]: directly, in a bounded box;
/// - [foldable]: inside a bordered, collapsible [Foldable] ("folder");
/// - [popup]: a launch button that opens the editor in a centred [Dialog];
/// - [bottomSheet]: a launch button that opens the editor in a modal sheet.
enum KeymapEditorPresentation { inline, foldable, popup, bottomSheet }

/// A ready-made presentation wrapper around the controlled [KeymapEditor].
///
/// The host supplies the controlled params ([value] / [onChanged] plus optional
/// [registry] / [metaKey] / [onSave]) and a [presentation]; the surface does the
/// rest. For [KeymapEditorPresentation.inline] / [foldable] the editor lives in
/// the host's tree (host rebuild feeds the new [value] back). For [popup] /
/// [bottomSheet] the editor opens in a separate route, so the surface keeps a
/// working copy in the modal and mirrors every edit back to [onChanged].
class KeymapEditorSurface extends StatefulWidget {
  /// Create a [KeymapEditorSurface].
  const KeymapEditorSurface({
    super.key,
    required this.presentation,
    required this.value,
    required this.onChanged,
    this.registry,
    this.metaKey = MetaKey.alt,
    this.onSave,
    this.onReset,
    this.title = 'Keybindings',
    this.infoTooltip,
    this.height = 420,
    this.initiallyExpanded = false,
    this.fullHeight = false,
    this.startCollapsed = false,
  });

  /// Which presentation to render.
  final KeymapEditorPresentation presentation;

  /// The current configuration (controlled).
  final KeymapConfig value;

  /// Called with the new configuration after every edit.
  final ValueChanged<KeymapConfig> onChanged;

  /// Registry of editable actions (host-contributed intents included).
  final KeymapRegistry? registry;

  /// The Meta key used for reset-to-defaults.
  final MetaKey metaKey;

  /// Optional per-mode Save callback (shows a Save button when non-null).
  final void Function(KeymapMode mode, String json)? onSave;

  /// Optional reset-to-defaults callback, passed straight through to the
  /// editor. Hosts that persist the config themselves need this to clear their
  /// own store, which the editor cannot do on their behalf.
  final VoidCallback? onReset;

  /// Header / launch-button label. In [popup] / [bottomSheet] it becomes the
  /// editor toolbar's title (single header line), not a separate header row.
  final String title;

  /// Optional ⓘ tooltip shown next to [title] in the modal presentations.
  final String? infoTooltip;

  /// Fixed height for the editor body (it needs bounded height — it has an
  /// internal tab view). Ignored for the modal presentations when [fullHeight].
  final double height;

  /// Whether the [foldable] presentation starts expanded.
  final bool initiallyExpanded;

  /// When true, the [popup] / [bottomSheet] modals fill the window height.
  final bool fullHeight;

  /// Whether the editor's folding-tree groups start collapsed.
  final bool startCollapsed;

  @override
  State<KeymapEditorSurface> createState() => _KeymapEditorSurfaceState();
}

class _KeymapEditorSurfaceState extends State<KeymapEditorSurface> {
  late bool _expanded = widget.initiallyExpanded;

  KeymapEditor _editor(
    KeymapConfig value,
    ValueChanged<KeymapConfig> onChanged, {
    String? title,
    VoidCallback? onClose,
  }) =>
      KeymapEditor(
        value: value,
        onChanged: onChanged,
        registry: widget.registry,
        metaKey: widget.metaKey,
        onSave: widget.onSave,
        onReset: widget.onReset,
        startCollapsed: widget.startCollapsed,
        title: title,
        infoTooltip: title != null ? widget.infoTooltip : null,
        onClose: onClose,
      );

  @override
  Widget build(BuildContext context) {
    switch (widget.presentation) {
      case KeymapEditorPresentation.inline:
        return SizedBox(
          height: widget.height,
          child: _editor(widget.value, widget.onChanged),
        );
      case KeymapEditorPresentation.foldable:
        return Container(
          decoration: BoxDecoration(
            // Semantic boundary: the box delineating the whole foldable editor
            // control, so it reads the guarded [ColorScheme.outline] (dual-floor
            // vs the page under a background override), not the decorative
            // hairline [ColorScheme.outlineVariant].
            border: Border.all(
              color: Theme.of(context).colorScheme.outline,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Foldable(
            expanded: _expanded,
            onToggle: () => setState(() => _expanded = !_expanded),
            header: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            child: SizedBox(
              height: widget.height,
              child: _editor(widget.value, widget.onChanged),
            ),
          ),
        );
      case KeymapEditorPresentation.popup:
      case KeymapEditorPresentation.bottomSheet:
        return Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('keymap-editor-launch'),
            icon: const Icon(Icons.keyboard),
            label: Text('Edit ${widget.title.toLowerCase()}…'),
            onPressed: () => _openModal(context),
          ),
        );
    }
  }

  /// Open the editor in a modal (popup or bottom sheet). The modal is a separate
  /// route, so it owns a working copy [w] initialised from [widget.value] and
  /// mirrors every edit back to the host via [onChanged].
  void _openModal(BuildContext context) {
    KeymapConfig w = widget.value;
    // The editor's own toolbar is the modal's single header line (title ⓘ …
    // icons … ✕) — no separate header row, no wasted line.
    Widget hosted(BuildContext ctx) => StatefulBuilder(
          builder: (BuildContext c, void Function(void Function()) setModal) =>
              _editor(
            w,
            (KeymapConfig next) {
              setModal(() => w = next);
              widget.onChanged(next);
            },
            title: widget.title,
            onClose: () => Navigator.of(ctx).pop(),
          ),
        );

    if (widget.presentation == KeymapEditorPresentation.bottomSheet) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        // Deliberately NOT useRootNavigator: the sheet pushes onto the same
        // navigator that hosts whatever opened it, so opening the editor from
        // the settings sheet slides it up OVER settings rather than replacing
        // it. Each surface is one item in the stack.
        useRootNavigator: false,
        builder: (BuildContext ctx) {
          final double maxH = MediaQuery.of(ctx).size.height * 0.95;
          final double h = widget.fullHeight
              ? maxH
              : (widget.height + 104 < maxH ? widget.height + 104 : maxH);
          // Escape pops THIS sheet only, revealing the settings sheet beneath
          // it — one item off the stack, not a teardown of the whole stack.
          return EscapeToPop(child: SizedBox(height: h, child: hosted(ctx)));
        },
      );
    } else {
      showDialog<void>(
        context: context,
        builder: (BuildContext ctx) {
          final double h = widget.fullHeight
              ? MediaQuery.of(ctx).size.height * 0.9
              : widget.height + 104;
          return Dialog(
            insetPadding: widget.fullHeight
                ? const EdgeInsets.symmetric(horizontal: 24, vertical: 16)
                : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(width: 660, height: h, child: hosted(ctx)),
          );
        },
      );
    }
  }
}
