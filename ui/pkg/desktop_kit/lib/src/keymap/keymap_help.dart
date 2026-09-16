// Data-driven keymap help dialog.
//
// Generalised from notekeep's speed_help.dart. Apps pass their own groups
// (title + list of bindings); no app-specific content is baked in here.
library;

import 'package:flutter/material.dart';

/// A single key-binding row in the help dialog.
class KeymapBinding {
  /// Create a [KeymapBinding].
  const KeymapBinding(
    this.keys,
    this.description, {
    this.available = true,
  });

  /// The key chord(s) to display, e.g. `'C-a'` or `'Ctrl+Shift+Y'`.
  final String keys;

  /// Human-readable description of the command.
  final String description;

  /// Whether the binding is currently implemented / available. Unavailable
  /// bindings are listed but greyed out.
  final bool available;
}

/// A titled group of [KeymapBinding]s for display in the help dialog.
class KeymapHelpGroup {
  /// Create a [KeymapHelpGroup].
  const KeymapHelpGroup(this.title, this.bindings);

  /// Section heading (e.g. `'Motions'`, `'Kill ring'`).
  final String title;

  /// Ordered list of bindings in this group.
  final List<KeymapBinding> bindings;
}

/// How the keymap help is presented: a centred [Dialog] popup, or a
/// [showModalBottomSheet] that slides up from the bottom.
enum KeymapHelpPresentation { popup, bottomSheet }

/// Show a scrollable, data-driven keymap help overlay.
///
/// [groups] provides the binding content; apps pass their own list so this
/// widget stays free of app-specific strings. [title] defaults to
/// `'Keyboard shortcuts'`; [intro] is an optional sub-heading paragraph.
/// [presentation] selects a centred popup (default) or a bottom sheet — both
/// are Navigator routes, so Escape dismisses exactly this one overlay.
///
/// Unavailable bindings ([KeymapBinding.available] == false) are listed with
/// a greyed-out "not yet available" trailing label.
Future<void> showKeymapHelp(
  BuildContext context, {
  required List<KeymapHelpGroup> groups,
  String? title,
  String? intro,
  KeymapHelpPresentation presentation = KeymapHelpPresentation.popup,
}) {
  final resolvedTitle = title ?? 'Keyboard shortcuts';
  final body = _KeymapHelpBody(
    groups: groups,
    title: resolvedTitle,
    intro: intro,
  );
  switch (presentation) {
    case KeymapHelpPresentation.popup:
      return showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
            child: body,
          ),
        ),
      );
    case KeymapHelpPresentation.bottomSheet:
      return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          child: body,
        ),
      );
  }
}

/// The shared help content (header + intro + scrollable grouped bindings),
/// hosted by both the popup [Dialog] and the bottom sheet.
class _KeymapHelpBody extends StatelessWidget {
  const _KeymapHelpBody({
    required this.groups,
    required this.title,
    this.intro,
  });

  final List<KeymapHelpGroup> groups;
  final String title;
  final String? intro;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        if (intro != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Text(intro!),
          ),
        const Divider(height: 1),
        Flexible(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final group in groups) ..._groupTiles(theme, group),
            ],
          ),
        ),
      ],
    );
  }
}

List<Widget> _groupTiles(ThemeData theme, KeymapHelpGroup group) {
  return [
    Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        group.title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    ),
    for (final b in group.bindings)
      ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: SizedBox(
          width: 120,
          child: Text(
            b.keys,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        title: Text(
          b.description,
          style: b.available ? null : TextStyle(color: theme.disabledColor),
        ),
        trailing: b.available
            ? null
            : Text(
                'not yet available',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.disabledColor,
                  fontStyle: FontStyle.italic,
                ),
              ),
      ),
  ];
}
