// An editable probe box for *testing* a keymap live.
//
// The keymap editor lets a user rebind an action; this widget lets them
// immediately verify the rebind FIRES — closing the "edit a binding, see it
// work" loop in one place, without first wiring the editor into a host app's
// real editor. Feed it the SAME [KeymapConfig] the editor edits and every
// keystroke is dispatched exactly as the config says:
//
//   * a bound **single-stroke** chord (e.g. the config's `C-a` → Move to line
//     start) fires its action — known motion/kill actions actually move the
//     caret / edit the buffer so the effect is *visible*; every fired action is
//     also reported in the status line;
//   * a bound **multi-stroke** sequence (e.g. `C-x C-s` → Save buffer) arms a
//     prefix (shown in the status line) and fires on completion, via the same
//     [SequenceMatcher] an app uses;
//   * a plain printable key **types** into the buffer;
//   * anything unbound is reported as such (and left un-consumed, so Tab still
//     traverses focus and Esc still closes an enclosing popup).
//
// Crucially it is built on a raw [Focus.onKeyEvent] over a private text model,
// NOT a Material [TextField]: an [EditableText] swallows exactly the chords a
// user most wants to test (`C-a` select-all, `C-x` cut, `C-v` paste, …) before
// any ancestor sees them. Intercepting at the focus node lets the config own
// every chord — the whole point of a keymap probe.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'key_chord.dart';
import 'keymap_config.dart';
import 'keymap_mode.dart';
import 'keymap_registry.dart';
import 'sequence_matcher.dart';

/// A host-supplied buffer effect for a fired intent [id] the probe doesn't
/// render natively (motions and kills are built in; anything else — e.g. a
/// host's `toggleKana` — is provided here). Given the current [text] and
/// [caret] (a UTF-16 offset), return the new `(text, caret)`, or `null` to
/// leave the buffer unchanged (the fire is still reported). Keeps the widget
/// decoupled from app-specific transforms like the kana engine.
typedef KeymapTestEffect = ({String text, int caret})? Function(
  String text,
  int caret,
);

/// An editable text box that dispatches [config]'s bindings live so a user can
/// confirm a rebind actually fires.
///
/// Controlled: pass the [config] the editor edits and the [registry] that
/// resolves intent ids to labels; the widget owns only its ephemeral buffer
/// text and caret. When [config] or [mode] changes (a rebind elsewhere) the
/// dispatch tables rebuild and any in-flight prefix is cleared.
///
/// A drop-in validation surface for any keymap host: place it beneath a
/// [KeymapEditor] (see the example gallery's Keymap settings) so "rebind →
/// test" happens on one screen.
class KeymapTestField extends StatefulWidget {
  /// Create a [KeymapTestField] over [config] and [registry].
  const KeymapTestField({
    super.key,
    required this.config,
    required this.registry,
    this.mode = KeymapMode.emacs,
    this.height = 132,
    this.initialText = '',
    this.autofocus = false,
    this.effects = const <String, KeymapTestEffect>{},
  });

  /// The keymap whose bindings are dispatched — typically the very config a
  /// sibling [KeymapEditor] edits, so rebinds are testable immediately.
  final KeymapConfig config;

  /// Resolves intent ids to [KeymapAction]s for labelling fired bindings.
  final KeymapRegistry registry;

  /// Which mode's bindings to dispatch. Defaults to [KeymapMode.emacs].
  final KeymapMode mode;

  /// Height of the editable area in logical pixels.
  final double height;

  /// Seed text placed in the buffer on first build.
  final String initialText;

  /// Whether the field grabs focus when first shown.
  final bool autofocus;

  /// Optional buffer effects for fired intent ids the probe doesn't render
  /// natively (motions/kills are built in). Lets a host wire, say, `toggleKana`
  /// to its kana engine (`Kana.toggleKana`) without coupling this widget to it.
  final Map<String, KeymapTestEffect> effects;

  @override
  State<KeymapTestField> createState() => _KeymapTestFieldState();
}

class _KeymapTestFieldState extends State<KeymapTestField> {
  final FocusNode _focus = FocusNode(debugLabel: 'keymap-test-field');

  late String _text = widget.initialText;
  late int _caret = widget.initialText.length;

  late SequenceMatcher _matcher = _buildMatcher();
  late Map<KeyChord, String> _singles = _buildSingles();

  String _status = 'Click to focus — then type, or press a bound chord.';
  String _pending = '';

  SequenceMatcher _buildMatcher() =>
      SequenceMatcher(widget.config.sequenceBindings(widget.mode));

  /// A `chord → intent-id` map of the mode's single-stroke bindings, for O(1)
  /// lookup after the [SequenceMatcher] reports the stroke isn't part of a
  /// multi-stroke sequence.
  Map<KeyChord, String> _buildSingles() {
    final out = <KeyChord, String>{};
    widget.config.singleStrokeBindings(widget.mode).forEach((seq, id) {
      final single = seq.asSingle;
      if (single != null) out[single] = id;
    });
    return out;
  }

  @override
  void didUpdateWidget(KeymapTestField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.config, oldWidget.config) ||
        widget.mode != oldWidget.mode) {
      _matcher = _buildMatcher();
      _singles = _buildSingles();
      _pending = '';
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  // ── Key handling ───────────────────────────────────────────────────────────

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    if (isModifierKey(key)) return KeyEventResult.ignored;
    // Leave focus traversal to the framework.
    if (key == LogicalKeyboardKey.tab) return KeyEventResult.ignored;

    final chord = KeyChord(
      keyId: key.keyId,
      control: HardwareKeyboard.instance.isControlPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      meta: HardwareKeyboard.instance.isMetaPressed,
    );

    // 1) Multi-stroke sequences (and any armed prefix) first.
    final SequenceMatchResult result = _matcher.feed(chord);
    switch (result) {
      case SequenceMatchPending(:final pendingLabel):
        setState(() {
          _pending = pendingLabel;
          _status = 'Prefix armed: $pendingLabel – waiting for next stroke…';
        });
        return KeyEventResult.handled;
      case SequenceMatchMatched(:final intentId, :final sequence):
        _fire(intentId, sequence.label);
        return KeyEventResult.handled;
      case SequenceMatchCancelled(:final swallowedStroke):
        setState(() {
          _pending = '';
          _status = swallowedStroke != null
              ? '${swallowedStroke.label} is undefined in this prefix — cancelled.'
              : 'Prefix cancelled.';
        });
        return KeyEventResult.handled;
      case SequenceMatchIdle():
        break; // fall through to single-stroke / typing
    }

    // 2) Single-stroke binding.
    final String? id = _singles[chord];
    if (id != null) {
      _fire(id, chord.label);
      return KeyEventResult.handled;
    }

    // 3) Plain editing / typing (no Ctrl/Alt/Meta held).
    if (!chord.control && !chord.alt && !chord.meta) {
      if (key == LogicalKeyboardKey.backspace) {
        setState(_doBackspace);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.delete) {
        setState(() {
          _doDeleteForward();
          _status = 'Delete';
        });
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        setState(() => _doInsert('\n'));
        return KeyEventResult.handled;
      }
      final String? ch = event.character;
      if (ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 0x20) {
        setState(() => _doInsert(ch));
        return KeyEventResult.handled;
      }
    }

    // 4) Unbound — report but do not consume, so Esc/arrows/etc. still work.
    setState(() {
      _pending = '';
      _status = 'Unbound: ${chord.label}';
    });
    return KeyEventResult.ignored;
  }

  /// Fire the action for [id]: apply its visible buffer effect if it is a known
  /// motion/kill, and report it in the status line either way.
  void _fire(String id, String keysLabel) {
    setState(() {
      _pending = '';
      final bool hadEffect = _applyEffect(id);
      final String label = widget.registry.action(id)?.label ?? id;
      _status = hadEffect
          ? 'Fired: $label  ($keysLabel)'
          : 'Fired: $label  ($keysLabel) — reported (no buffer effect in probe)';
    });
  }

  // ── Buffer mutators (pure; callers wrap in setState) ───────────────────────

  void _doInsert(String s) {
    _text = _text.substring(0, _caret) + s + _text.substring(_caret);
    _caret += s.length;
    _status = s == '\n' ? 'Inserted newline' : 'Typed "$s"';
  }

  void _doBackspace() {
    if (_caret == 0) {
      _status = 'Backspace at start — nothing to delete';
      return;
    }
    _text = _text.substring(0, _caret - 1) + _text.substring(_caret);
    _caret -= 1;
    _status = 'Backspace';
  }

  void _doDeleteForward() {
    if (_caret < _text.length) {
      _text = _text.substring(0, _caret) + _text.substring(_caret + 1);
    }
  }

  void _doDeleteRange(int start, int end) {
    final int a = start.clamp(0, _text.length);
    final int b = end.clamp(0, _text.length);
    if (a >= b) return;
    _text = _text.substring(0, a) + _text.substring(b);
    _caret = a;
  }

  /// Apply the buffer effect of a known motion/kill action; return whether [id]
  /// was one this probe renders (report-only actions return false).
  bool _applyEffect(String id) {
    switch (id) {
      case 'moveLineStart':
        _caret = _lineStart(_caret);
      case 'moveLineEnd':
        _caret = _lineEnd(_caret);
      case 'moveForwardChar':
        _caret = math.min(_text.length, _caret + 1);
      case 'moveBackwardChar':
        _caret = math.max(0, _caret - 1);
      case 'moveNextLine':
        _caret = _nextLine(_caret);
      case 'movePreviousLine':
        _caret = _prevLine(_caret);
      case 'moveForwardWord':
        _caret = _forwardWord(_caret);
      case 'moveBackwardWord':
        _caret = _backwardWord(_caret);
      case 'moveBufferStart':
        _caret = 0;
      case 'moveBufferEnd':
        _caret = _text.length;
      case 'killLine':
        _doKillLine();
      case 'deleteChar':
        _doDeleteForward();
      case 'deleteWordForward':
        _doDeleteRange(_caret, _forwardWord(_caret));
      case 'deleteWordBackward':
        _doDeleteRange(_backwardWord(_caret), _caret);
      default:
        // Host-supplied effect for its own registered intents (e.g. toggleKana).
        final KeymapTestEffect? effect = widget.effects[id];
        if (effect != null) {
          final ({String text, int caret})? next = effect(_text, _caret);
          if (next != null) {
            _text = next.text;
            _caret = next.caret.clamp(0, _text.length);
            return true;
          }
        }
        return false;
    }
    return true;
  }

  void _doKillLine() {
    final int end = _lineEnd(_caret);
    if (_caret < end) {
      _doDeleteRange(_caret, end); // kill to end of line
    } else if (end < _text.length) {
      _doDeleteRange(_caret, _caret + 1); // at EOL: kill the newline
    }
  }

  // ── Text geometry helpers ──────────────────────────────────────────────────

  int _lineStart(int c) {
    if (c <= 0) return 0; // lastIndexOf throws on a negative start
    final int nl = _text.lastIndexOf('\n', c - 1);
    return nl < 0 ? 0 : nl + 1;
  }

  int _lineEnd(int c) {
    final int from = c.clamp(0, _text.length);
    final int nl = _text.indexOf('\n', from);
    return nl < 0 ? _text.length : nl;
  }

  int _nextLine(int c) {
    final int col = c - _lineStart(c);
    final int end = _lineEnd(c);
    if (end >= _text.length) return _text.length; // already on the last line
    final int start = end + 1;
    return math.min(start + col, _lineEnd(start));
  }

  int _prevLine(int c) {
    final int start = _lineStart(c);
    if (start == 0) return 0; // already on the first line
    final int col = c - start;
    final int prevStart = _lineStart(start - 1);
    return math.min(prevStart + col, start - 1);
  }

  static bool _isWordChar(int u) =>
      (u >= 0x30 && u <= 0x39) || // 0-9
      (u >= 0x41 && u <= 0x5a) || // A-Z
      (u >= 0x61 && u <= 0x7a) || // a-z
      u == 0x5f || // _
      u > 0x7f; // treat non-ASCII (kana/kanji/accents) as word chars

  int _forwardWord(int c) {
    int i = c;
    while (i < _text.length && !_isWordChar(_text.codeUnitAt(i))) {
      i++;
    }
    while (i < _text.length && _isWordChar(_text.codeUnitAt(i))) {
      i++;
    }
    return i;
  }

  int _backwardWord(int c) {
    int i = c;
    while (i > 0 && !_isWordChar(_text.codeUnitAt(i - 1))) {
      i--;
    }
    while (i > 0 && _isWordChar(_text.codeUnitAt(i - 1))) {
      i--;
    }
    return i;
  }

  // ── Render ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        GestureDetector(
          onTap: _focus.requestFocus,
          child: Focus(
            focusNode: _focus,
            autofocus: widget.autofocus,
            onKeyEvent: (_, KeyEvent event) => _handleKey(event),
            child: AnimatedBuilder(
              animation: _focus,
              builder: (BuildContext context, _) {
                final bool focused = _focus.hasFocus;
                final Color border = _pending.isNotEmpty
                    ? cs.tertiary
                    : focused
                        ? cs.primary
                        : cs.outlineVariant;
                return Container(
                  height: widget.height,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: border,
                      width: focused || _pending.isNotEmpty ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    color: focused
                        ? cs.primaryContainer.withValues(alpha: 0.10)
                        : null,
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: _buildBuffer(theme, focused),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _status,
          style: theme.textTheme.bodySmall?.copyWith(
            color: _pending.isNotEmpty ? cs.tertiary : cs.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _buildBuffer(ThemeData theme, bool focused) {
    final ColorScheme cs = theme.colorScheme;
    final TextStyle base = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(fontFamily: 'monospace', height: 1.4, color: cs.onSurface);

    if (_text.isEmpty && !focused) {
      return Text(
        'Click to focus, then type — or press a bound chord to test it.',
        style: base.copyWith(
          color: cs.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    final String before = _text.substring(0, _caret.clamp(0, _text.length));
    final String after = _text.substring(_caret.clamp(0, _text.length));
    return Text.rich(
      TextSpan(
        style: base,
        children: <InlineSpan>[
          TextSpan(text: before),
          if (focused)
            TextSpan(
              text: '│',
              style: base.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          TextSpan(text: after),
        ],
      ),
    );
  }
}
