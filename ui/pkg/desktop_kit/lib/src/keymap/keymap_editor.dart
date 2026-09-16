// The keybinding editor widget.
//
// [KeymapEditor] rebinds keystrokes to editor intents per [KeymapMode]. It is
// *controlled* (like the kit's AppearancePane): it renders [value] and reports
// every edit via [onChanged]; it holds no config state and does no
// persistence — the host owns that. Per-mode `Save` (when [onSave] is given)
// hands the host the mode's JSON so it can write it wherever it likes.
//
// Bindings are [KeyChordSequence]s: a single keystroke (`Ctrl+S`) is a length-1
// sequence and behaves exactly as before; a multi-stroke sequence (`C-x C-s`)
// is captured stroke-by-stroke in [_ChordCaptureDialog]. Multi-stroke bindings
// are shown and rebindable here; runtime dispatch of those bindings requires a
// [SequenceMatcher] wired into the host app's key handler (chain step 3) —
// see [KeymapConfig.sequenceBindings] and the [SequenceMatcher] docs. Such
// rows carry a muted "(multi-stroke)" annotation to surface this requirement
// (see [KeymapConfig] / [Keymaps.defaultSequenceBindings]).
//
// Actions come from a [KeymapRegistry]; a host registers its own intents
// (e.g. voicelab' kana intents) into that registry and they appear here
// automatically, so the editor is not limited to the kit's built-ins.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'key_chord.dart';
import 'key_chord_sequence.dart';
import 'keymap_config.dart';
import 'keymap_mode.dart';
import 'keymap_registry.dart';

/// A controlled per-mode keybinding editor.
///
/// {@tool snippet}
/// ```dart
/// KeymapEditor(
///   value: config,
///   registry: registry, // host may register extra intents first
///   onChanged: (next) => setState(() => config = next),
///   onSave: (mode, json) => prefs.setString('keymap.${mode.name}', json),
/// )
/// ```
/// {@end-tool}
class KeymapEditor extends StatefulWidget {
  /// Create a [KeymapEditor].
  const KeymapEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.registry,
    this.metaKey = MetaKey.alt,
    this.onSave,
    this.title,
    this.infoTooltip,
    this.onReset,
    this.startCollapsed = false,
    this.onClose,
  });

  /// The current configuration to render and edit.
  final KeymapConfig value;

  /// Called with the new configuration after every edit. The host should store
  /// it and feed it back in as [value] (controlled).
  final ValueChanged<KeymapConfig> onChanged;

  /// Registry of editable actions. Defaults to [KeymapRegistry.defaults]; pass
  /// a registry with host-contributed intents already registered to expose
  /// them in the editor.
  final KeymapRegistry? registry;

  /// The Meta key used when computing reset-to-defaults chords.
  final MetaKey metaKey;

  /// If non-null, each mode tab shows a `Save` button that calls this with the
  /// mode and its JSON ([KeymapConfig.encodeMode]). If null, no save button is
  /// shown (pure controlled — the host persists on [onChanged]).
  final void Function(KeymapMode mode, String json)? onSave;

  /// Optional title shown at the left of the editor's toolbar (e.g. `'Keymap'`).
  /// When null, the toolbar has no title and just carries the action icons.
  final String? title;

  /// Optional explanatory text surfaced by an ⓘ info button next to [title]
  /// (hover tooltip + tap dialog). Ignored when [title] is null.
  final String? infoTooltip;

  /// If non-null, the toolbar's reset button calls this (host-defined "reset to
  /// defaults") instead of the built-in per-mode reset-to-registry-defaults.
  final VoidCallback? onReset;

  /// Whether the folding-tree groups start collapsed. Defaults to expanded.
  final bool startCollapsed;

  /// If non-null, the toolbar shows a trailing close (✕) button that calls this
  /// — for using the editor as a modal's own single header line.
  final VoidCallback? onClose;

  @override
  State<KeymapEditor> createState() => _KeymapEditorState();
}

class _KeymapEditorState extends State<KeymapEditor>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: KeymapMode.values.length, vsync: this);
  late KeymapRegistry _registry = widget.registry ?? KeymapRegistry.defaults();

  final TextEditingController _searchCtl = TextEditingController();
  bool _searchOpen = false;
  String _search = '';
  bool _tree = true;
  final Set<String> _collapsed = <String>{};

  static const String _kEditorHelp =
      'Rebind an action: click a key chip to change it, tap + to add another, or '
      '✕ to remove. Multi-stroke sequences (e.g. C-x C-s) carry a note. Use the '
      'search box to filter, and the view toggle to switch between a folding '
      'tree (grouped) and a flat table. Reset restores this mode’s defaults.';

  void _toggleGroup(String group) => setState(() {
        if (!_collapsed.remove(group)) _collapsed.add(group);
      });

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Keymap editor'),
        content: const Text(_kEditorHelp),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showInfo() {
    final String? info = widget.infoTooltip;
    if (info == null) return;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(widget.title ?? 'Info'),
        content: Text(info),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  KeymapMode get _activeMode => KeymapMode.values[_tabs.index];

  void _resetActive() {
    final VoidCallback? hostReset = widget.onReset;
    if (hostReset != null) {
      hostReset();
    } else {
      _resetMode(_activeMode);
    }
  }

  void _saveActive() {
    final KeymapMode mode = _activeMode;
    widget.onSave?.call(mode, widget.value.encodeMode(mode));
  }

  @override
  void initState() {
    super.initState();
    if (widget.startCollapsed) {
      _collapsed.addAll(_registry.grouped.keys);
    }
    _tabs.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(KeymapEditor old) {
    super.didUpdateWidget(old);
    if (!identical(old.registry, widget.registry)) {
      _registry = widget.registry ?? KeymapRegistry.defaults();
    }
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _tabs.dispose();
    super.dispose();
  }

  // --- mutation helpers (all controlled: build a new config, call onChanged) --

  void _apply(KeymapMode mode, Map<KeyChordSequence, String> bindings) =>
      widget.onChanged(widget.value.withMode(mode, bindings));

  Future<void> _capture(
    KeymapMode mode,
    KeymapAction action, {
    KeyChordSequence? replacing,
  }) async {
    // Root navigator, explicitly: the editor is usually hosted in a sheet that
    // is itself stacked over the settings sheet, and the capture window has to
    // sit ABOVE that stack or the thing you are typing into is covered by the
    // menu you launched it from. Popping it returns here and the editor stays
    // mounted, so a run of rebinds is one open/close, not one per key.
    final seq = await showDialog<KeyChordSequence>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _ChordCaptureDialog(actionLabel: action.label),
    );
    if (seq == null || !mounted) return;

    final current =
        Map<KeyChordSequence, String>.from(widget.value.bindingsFor(mode));
    if (replacing != null) current.remove(replacing);

    final existingId = current[seq];
    if (existingId != null && existingId != action.id) {
      final other = _registry.action(existingId)?.label ?? existingId;
      final ok = await _confirmReassign(seq, other, action.label);
      if (ok != true || !mounted) return;
      current.remove(seq);
    }
    current[seq] = action.id;
    _apply(mode, current);
  }

  void _removeSequence(KeymapMode mode, KeyChordSequence seq) {
    final current =
        Map<KeyChordSequence, String>.from(widget.value.bindingsFor(mode))
          ..remove(seq);
    _apply(mode, current);
  }

  Future<void> _resetMode(KeymapMode mode) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset to defaults?'),
        content: Text(
          'Discard all custom ${mode.label} bindings and restore the '
          'built-in defaults?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final defaults =
        KeymapConfig.fromDefaults(_registry, metaKey: widget.metaKey);
    _apply(mode, defaults.bindingsFor(mode));
  }

  Future<bool?> _confirmReassign(
    KeyChordSequence seq,
    String fromLabel,
    String toLabel,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Chord already bound'),
        content: Text(
          '${seq.label} is bound to "$fromLabel". '
          'Reassign it to "$toLabel"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reassign'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildToolbar(context),
        TabBar(
          controller: _tabs,
          // This TabBar is fixed (non-scrollable), so it must use a
          // non-scrollable alignment. Set it explicitly so an ambient
          // TabBarThemeData(tabAlignment: TabAlignment.start) from a consumer's
          // app theme — valid only for SCROLLABLE bars — cannot crash the editor
          // ('TabAlignment.start is only valid for scrollable tab bars').
          tabAlignment: TabAlignment.fill,
          tabs: [
            for (final m in KeymapMode.values) Tab(text: '${m.label} bindings'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              for (final mode in KeymapMode.values)
                _ModeTab(
                  mode: mode,
                  config: widget.value,
                  registry: _registry,
                  search: _search,
                  tree: _tree,
                  collapsed: _collapsed,
                  onToggleGroup: _toggleGroup,
                  onCapture: (action, {replacing}) =>
                      _capture(mode, action, replacing: replacing),
                  onRemoveSequence: (seq) => _removeSequence(mode, seq),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// The editor's single toolbar line: `title ⓘ … (search) ? [search] [tree]
  /// [reset] [save]`. Every icon carries a mouse-over tooltip.
  Widget _buildToolbar(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 2),
      child: Row(
        children: <Widget>[
          if (widget.title != null) ...<Widget>[
            Text(widget.title!, style: theme.textTheme.titleLarge),
            if (widget.infoTooltip != null)
              IconButton(
                key: const Key('keymap-info'),
                icon: const Icon(Icons.info_outline, size: 20),
                tooltip: widget.infoTooltip,
                onPressed: _showInfo,
              ),
          ],
          if (_searchOpen)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextField(
                  key: const Key('keymap-search'),
                  controller: _searchCtl,
                  autofocus: true,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Filter actions…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Clear search',
                      onPressed: () => setState(() {
                        _searchCtl.clear();
                        _search = '';
                        _searchOpen = false;
                      }),
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (String v) => setState(() => _search = v),
                ),
              ),
            )
          else
            const Spacer(),
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'How to use the editor',
            onPressed: _showHelp,
          ),
          if (!_searchOpen)
            IconButton(
              key: const Key('keymap-search-open'),
              icon: const Icon(Icons.search),
              tooltip: 'Search / filter actions',
              onPressed: () => setState(() => _searchOpen = true),
            ),
          IconButton(
            key: const Key('keymap-view-toggle'),
            icon: Icon(_tree
                ? Icons.table_rows_outlined
                : Icons.account_tree_outlined),
            tooltip: _tree ? 'Switch to table view' : 'Switch to tree view',
            onPressed: () => setState(() {
              _tree = !_tree;
              if (_tree) {
                // Entering tree view starts folded (all groups collapsed).
                _collapsed
                  ..clear()
                  ..addAll(_registry.grouped.keys);
              }
            }),
          ),
          IconButton(
            key: const Key('keymap-reset'),
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Reset to defaults',
            onPressed: _resetActive,
          ),
          if (widget.onSave != null)
            IconButton(
              key: Key('keymap-save-${_activeMode.name}'),
              icon: const Icon(Icons.save),
              tooltip: 'Save ${_activeMode.label} bindings',
              onPressed: _saveActive,
            ),
          if (widget.onClose != null)
            IconButton(
              key: const Key('keymap-close'),
              icon: const Icon(Icons.close),
              tooltip: 'Close',
              onPressed: widget.onClose,
            ),
        ],
      ),
    );
  }
}

/// A single mode's editable binding list.
class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.mode,
    required this.config,
    required this.registry,
    required this.search,
    required this.tree,
    required this.collapsed,
    required this.onToggleGroup,
    required this.onCapture,
    required this.onRemoveSequence,
  });

  final KeymapMode mode;
  final KeymapConfig config;
  final KeymapRegistry registry;
  final String search;
  final bool tree;
  final Set<String> collapsed;
  final ValueChanged<String> onToggleGroup;
  final void Function(KeymapAction action, {KeyChordSequence? replacing})
      onCapture;
  final ValueChanged<KeyChordSequence> onRemoveSequence;

  /// The key sequences bound to [id] in this mode, in a stable order.
  List<KeyChordSequence> _sequencesFor(String id) {
    final out = <KeyChordSequence>[];
    config.bindingsFor(mode).forEach((seq, boundId) {
      if (boundId == id) out.add(seq);
    });
    out.sort((a, b) => a.token.compareTo(b.token));
    return out;
  }

  bool _matches(
    KeymapAction a,
    String group,
    String q,
    List<KeyChordSequence> seqs,
  ) {
    if (q.isEmpty) return true;
    if (a.label.toLowerCase().contains(q)) return true;
    if (a.id.toLowerCase().contains(q)) return true;
    if (group.toLowerCase().contains(q)) return true;
    for (final KeyChordSequence s in seqs) {
      if (s.label.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  _ActionRow _row(KeymapAction action, Set<KeyChordSequence> shadowed) =>
      _ActionRow(
        action: action,
        sequences: _sequencesFor(action.id),
        shadowed: shadowed,
        onAdd: () => onCapture(action),
        onReplace: (seq) => onCapture(action, replacing: seq),
        onRemove: onRemoveSequence,
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Map<String, List<KeymapAction>> grouped = registry.grouped;
    // Which sequences are involved in a shadow (prefix) conflict.
    final Set<KeyChordSequence> shadowed =
        shadowedSequences(config.bindingsFor(mode).keys);
    final String q = search.trim().toLowerCase();
    final bool searching = q.isNotEmpty;

    // Filter groups by the query (label / id / group / bound-chord label).
    final List<MapEntry<String, List<KeymapAction>>> filtered =
        <MapEntry<String, List<KeymapAction>>>[];
    for (final MapEntry<String, List<KeymapAction>> entry in grouped.entries) {
      final List<KeymapAction> matches = entry.value
          .where((KeymapAction a) =>
              _matches(a, entry.key, q, _sequencesFor(a.id)))
          .toList();
      if (matches.isNotEmpty) {
        filtered.add(MapEntry<String, List<KeymapAction>>(entry.key, matches));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          // SingleChildScrollView (vs ListView) builds every row eagerly — the
          // action list is small (tens of rows) and eager build keeps the whole
          // keymap searchable/scrollable without lazy-viewport surprises.
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No actions match “$search”.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  )
                else
                  for (final MapEntry<String, List<KeymapAction>> entry
                      in filtered)
                    if (tree)
                      _treeGroup(
                          theme, entry.key, entry.value, shadowed, searching)
                    else
                      _tableGroup(theme, entry.key, entry.value, shadowed),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _groupTitle(ThemeData theme, String group) => Text(
        group,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      );

  /// Flat table view: a group header followed by its rows, always expanded.
  Widget _tableGroup(
    ThemeData theme,
    String group,
    List<KeymapAction> actions,
    Set<KeyChordSequence> shadowed,
  ) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: _groupTitle(theme, group),
          ),
          for (final KeymapAction a in actions) _row(a, shadowed),
        ],
      );

  /// Folding tree view: a collapsible header per group (forced open while
  /// searching so matches stay visible), children indented.
  Widget _treeGroup(
    ThemeData theme,
    String group,
    List<KeymapAction> actions,
    Set<KeyChordSequence> shadowed,
    bool searching,
  ) {
    final bool expanded = searching || !collapsed.contains(group);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: searching ? null : () => onToggleGroup(group),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 16, 6),
            child: Row(
              children: <Widget>[
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
                _groupTitle(theme, group),
                const SizedBox(width: 8),
                Text(
                  '${actions.length}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          for (final KeymapAction a in actions)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: _row(a, shadowed),
            ),
      ],
    );
  }
}

/// One action row: its label plus its bound key sequences as editable chips and
/// an "add binding" button. Multi-stroke sequences carry a muted "(dispatch:
/// step 2)" note; sequences in a shadow conflict carry a warning icon.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.action,
    required this.sequences,
    required this.shadowed,
    required this.onAdd,
    required this.onReplace,
    required this.onRemove,
  });

  final KeymapAction action;
  final List<KeyChordSequence> sequences;
  final Set<KeyChordSequence> shadowed;
  final VoidCallback onAdd;
  final ValueChanged<KeyChordSequence> onReplace;
  final ValueChanged<KeyChordSequence> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(action.label, style: theme.textTheme.bodyLarge),
            ),
          ),
          Expanded(
            flex: 3,
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final seq in sequences)
                  _SequenceChip(
                    key: Key('keymap-chip-${action.id}-${seq.token}'),
                    sequence: seq,
                    isShadowed: shadowed.contains(seq),
                    onPressed: () => onReplace(seq),
                    onDeleted: () => onRemove(seq),
                  ),
                IconButton(
                  key: Key('keymap-add-${action.id}'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add),
                  tooltip:
                      sequences.isEmpty ? 'Bind a key' : 'Add another binding',
                  onPressed: onAdd,
                ),
                if (sequences.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'unbound',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.disabledColor,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A chip for one bound [sequence]. Renders the sequence label; for a
/// multi-stroke sequence it adds a muted "(multi-stroke)" note indicating that
/// runtime dispatch requires wiring a [SequenceMatcher] in the host app (chain
/// step 3), and if the sequence is in a shadow conflict it prefixes a warning
/// icon whose tooltip explains the shadow.
class _SequenceChip extends StatelessWidget {
  const _SequenceChip({
    super.key,
    required this.sequence,
    required this.isShadowed,
    required this.onPressed,
    required this.onDeleted,
  });

  final KeyChordSequence sequence;
  final bool isShadowed;
  final VoidCallback onPressed;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final multi = !sequence.isSingle;
    // mainAxisSize.min keeps the chip tight to its content; the annotation is
    // Flexible + ellipsis so a wide sequence label never overflows the chip's
    // bounded width (chips live in a Wrap that can hand out a finite max width).
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isShadowed) ...[
          Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(sequence.label, overflow: TextOverflow.ellipsis),
        ),
        if (multi) ...[
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '(multi-stroke)',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.disabledColor,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ],
    );
    final tooltip = isShadowed
        ? 'Shadow conflict: this binding shares a prefix with another in this '
            'mode, so one intercepts the other. Tap to rebind, ✕ to remove.'
        : multi
            ? 'Multi-stroke sequence — wire a SequenceMatcher in your app to '
                'dispatch these at runtime (see desktop_kit_keymap.dart). '
                'Tap to rebind, ✕ to remove.'
            : 'Tap to rebind, ✕ to remove';
    return InputChip(
      label: label,
      onPressed: onPressed,
      onDeleted: onDeleted,
      tooltip: tooltip,
    );
  }
}

/// Modal that captures a key *sequence* — one or more strokes.
///
/// Each non-modifier keydown appends a stroke; bare modifier presses
/// (Ctrl/Alt/Shift/Meta alone) are ignored because they belong to the *next*
/// stroke. The live display shows the accumulated strokes Emacs-style with a
/// trailing "–" while armed (e.g. `Ctrl+X –`, then `Ctrl+X Ctrl+S –`). Commit
/// with Enter or the confirm button; cancel with Esc or C-g; a *bare* Backspace
/// (no modifiers) removes the last stroke. A single stroke + confirm behaves
/// exactly like the old single-chord capture.
///
/// Note: bare Enter (commit) and bare Backspace (edit) are reserved by the
/// dialog, so neither can itself be captured as a bare-modifier-free stroke
/// (both are exotic bindings); a modifier-carrying variant — C-Enter,
/// C-Backspace, M-Backspace — falls through and is captured normally.
class _ChordCaptureDialog extends StatefulWidget {
  const _ChordCaptureDialog({this.actionLabel});

  final String? actionLabel;

  @override
  State<_ChordCaptureDialog> createState() => _ChordCaptureDialogState();
}

class _ChordCaptureDialogState extends State<_ChordCaptureDialog> {
  final FocusNode _focus = FocusNode(debugLabel: 'chord-capture');

  /// The strokes captured so far. A sequence needs >= 1 stroke, so this stays
  /// null until the first stroke and becomes null again if Backspace empties it.
  KeyChordSequence? _pending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final p = _pending;
    if (p != null) Navigator.of(context).pop(p);
  }

  void _cancel() => Navigator.of(context).pop();

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    final kb = HardwareKeyboard.instance;

    // Esc — cancel.
    if (key == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    // C-g — cancel (Emacs keyboard-quit), only as the Ctrl+G combination.
    if (key == LogicalKeyboardKey.keyG && kb.isControlPressed) {
      _cancel();
      return KeyEventResult.handled;
    }
    // Enter — commit the pending sequence (if any). (Bare Enter; Ctrl/Alt/Meta
    // +Enter falls through to be captured as a normal stroke.)
    if (key == LogicalKeyboardKey.enter &&
        !kb.isControlPressed &&
        !kb.isAltPressed &&
        !kb.isMetaPressed) {
      _commit();
      return KeyEventResult.handled;
    }
    // Bare Backspace — drop the last stroke (sequence editing). Backspace WITH a
    // modifier (C-/M-Backspace) is a real binding and is captured normally.
    if (key == LogicalKeyboardKey.backspace &&
        !kb.isControlPressed &&
        !kb.isAltPressed &&
        !kb.isMetaPressed &&
        !kb.isShiftPressed) {
      setState(() => _pending = _pending?.dropLast());
      return KeyEventResult.handled;
    }
    // A bare modifier isn't a stroke yet — it belongs to the next chord.
    if (isModifierKey(key)) return KeyEventResult.handled;

    // Append this stroke.
    final stroke = KeyChord(
      keyId: key.keyId,
      control: kb.isControlPressed,
      shift: kb.isShiftPressed,
      alt: kb.isAltPressed,
      meta: kb.isMetaPressed,
    );
    setState(() {
      _pending = _pending == null
          ? KeyChordSequence.single(stroke)
          : _pending!.append(stroke);
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = widget.actionLabel;
    final pending = _pending;
    // Armed display: accumulated strokes plus a trailing "–" cue that another
    // stroke may follow or the sequence may be committed.
    final display =
        pending == null ? 'Waiting for input…' : '${pending.label} –';
    return AlertDialog(
      title: const Text('Press a key combination'),
      content: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (label != null)
              Text('Binding for: $label', style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                display,
                key: const Key('keymap-capture-preview'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'monospace',
                  color: pending == null ? theme.disabledColor : null,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter to confirm · Backspace removes the last stroke · '
              'Esc / C-g cancels. For a multi-stroke sequence (e.g. C-x C-s), '
              'press each stroke, then Enter.',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.disabledColor),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _cancel,
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('keymap-capture-set'),
          onPressed: pending == null ? null : _commit,
          child: const Text('Set'),
        ),
      ],
    );
  }
}
