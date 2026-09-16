// Serialisable single-key chord for the keymap editor.
//
// [SingleActivator] — Flutter's chord type — has no JSON form: its trigger is
// a [LogicalKeyboardKey] (identified by a stable integer [keyId]) and its
// modifiers are named bools. [KeyChord] captures exactly the fields the
// Emacs/CUA keymaps use (trigger + ctrl/shift/alt/meta) in a value type that
// round-trips through JSON and serves as a stable [Map] key, so a saved
// keybinding config can be reconstructed into a live keymap.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A trigger key plus modifier state — the serialisable analogue of the
/// subset of [SingleActivator] the keymaps use.
///
/// Equality and [hashCode] are by value over the five fields, so a [KeyChord]
/// is a well-behaved [Map] key (conflict detection in the editor relies on
/// this). [token] is the canonical string form used as a JSON object key;
/// [label] is a human-readable display string.
class KeyChord {
  /// Create a [KeyChord] from a trigger [keyId] and modifier bits.
  const KeyChord({
    required this.keyId,
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  /// Derive a [KeyChord] from a [SingleActivator] (the only [ShortcutActivator]
  /// the kit keymaps use). Fields beyond the four modifiers (numLock,
  /// includeRepeats) are not part of the editor's model and are dropped.
  factory KeyChord.fromActivator(SingleActivator a) => KeyChord.canonical(
        keyId: a.trigger.keyId,
        control: a.control,
        shift: a.shift,
        alt: a.alt,
        meta: a.meta,
      );

  /// Build a chord in CANONICAL symbol encoding: `shift`+base-symbol becomes
  /// the shifted symbol's own key id with the shift bit dropped (comma+shift →
  /// `<`), and shift is folded away for any punctuation id — because shift is
  /// consumed *producing* the symbol. This makes three worlds agree on one
  /// encoding for e.g. `M-<`: layout-resolving platforms (GTK delivers the
  /// logical key `<` with shift physically held), the test simulator (delivers
  /// comma+shift), and `kbd`-string harvesting (parses `<` directly, no
  /// shift). Emacs has the same semantics — there is no distinct `M-S-<`.
  /// Letters, digits and space keep their shift state untouched.
  factory KeyChord.canonical({
    required int keyId,
    bool control = false,
    bool shift = false,
    bool alt = false,
    bool meta = false,
  }) {
    var id = keyId;
    var sh = shift;
    if (sh) {
      final shifted = kShiftedSymbolForBase[id];
      if (shifted != null) id = shifted;
    }
    if (isShiftFoldedKeyId(id)) sh = false;
    return KeyChord(
        keyId: id, control: control, shift: sh, alt: alt, meta: meta);
  }

  /// Parse a [token] produced by [token]. Format: `"<flags>-<keyId>"` where
  /// flags is any subset of `C`,`S`,`A`,`M` (control/shift/alt/meta, in that
  /// order) and keyId is the decimal [LogicalKeyboardKey.keyId]. Throws
  /// [FormatException] on a malformed token.
  factory KeyChord.parse(String token) {
    final dash = token.lastIndexOf('-');
    if (dash < 0) {
      throw FormatException('KeyChord token missing "-" separator', token);
    }
    final flags = token.substring(0, dash);
    final keyId = int.tryParse(token.substring(dash + 1));
    if (keyId == null) {
      throw FormatException('KeyChord token has non-integer keyId', token);
    }
    return KeyChord(
      keyId: keyId,
      control: flags.contains('C'),
      shift: flags.contains('S'),
      alt: flags.contains('A'),
      meta: flags.contains('M'),
    );
  }

  /// The [LogicalKeyboardKey.keyId] of the trigger — a stable integer that
  /// survives serialisation (unlike the [LogicalKeyboardKey] instance).
  final int keyId;

  /// Whether Control is held.
  final bool control;

  /// Whether Shift is held.
  final bool shift;

  /// Whether Alt is held.
  final bool alt;

  /// Whether Meta (Super / Command) is held.
  final bool meta;

  /// The trigger key, resolved from [keyId]. Falls back to a synthetic
  /// [LogicalKeyboardKey] if the id is not a known key (forward-compatible with
  /// keys this build of Flutter doesn't enumerate).
  LogicalKeyboardKey get trigger =>
      LogicalKeyboardKey.findKeyByKeyId(keyId) ?? LogicalKeyboardKey(keyId);

  /// Rebuild the live [SingleActivator] for binding into a keymap.
  SingleActivator toActivator() => SingleActivator(
        trigger,
        control: control,
        shift: shift,
        alt: alt,
        meta: meta,
      );

  /// Canonical string form used as a JSON object key and for equality-safe
  /// storage: `"<flags>-<keyId>"`, e.g. Ctrl+Shift+Y → `"CS-121"`, F1 →
  /// `"-<keyId>"`. Inverse of [KeyChord.parse].
  String get token {
    final b = StringBuffer();
    if (control) b.write('C');
    if (shift) b.write('S');
    if (alt) b.write('A');
    if (meta) b.write('M');
    b
      ..write('-')
      ..write(keyId);
    return b.toString();
  }

  /// Human-readable label, e.g. `"Ctrl+Shift+Y"`, `"Alt+F"`, `"Ctrl+Space"`,
  /// `"F1"`. Modifier order is Ctrl, Shift, Alt, Meta.
  String get label {
    final parts = <String>[
      if (control) 'Ctrl',
      if (shift) 'Shift',
      if (alt) 'Alt',
      if (meta) 'Meta',
      _keyLabel(trigger),
    ];
    return parts.join('+');
  }

  /// A copy with selected fields replaced.
  KeyChord copyWith({
    int? keyId,
    bool? control,
    bool? shift,
    bool? alt,
    bool? meta,
  }) =>
      KeyChord(
        keyId: keyId ?? this.keyId,
        control: control ?? this.control,
        shift: shift ?? this.shift,
        alt: alt ?? this.alt,
        meta: meta ?? this.meta,
      );

  @override
  bool operator ==(Object other) =>
      other is KeyChord &&
      other.keyId == keyId &&
      other.control == control &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(keyId, control, shift, alt, meta);

  @override
  String toString() => 'KeyChord($label)';
}

/// Whether [key] is a bare modifier key (Ctrl/Shift/Alt/Meta, either side).
/// A chord capture must ignore these — the chord is a modifier *combination*
/// finished by a non-modifier trigger.
bool isModifierKey(LogicalKeyboardKey key) => _modifierKeys.contains(key);

final Set<LogicalKeyboardKey> _modifierKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.control,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.shift,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.alt,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.meta,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
};

/// Printable name for a trigger key. [LogicalKeyboardKey.keyLabel] is empty or
/// unhelpful for many non-letter keys (space → `" "`, backspace → `""`), so
/// the editor's display keys are named explicitly; letters fall back to the
/// uppercased label, and unknown keys to a hex id.
String _keyLabel(LogicalKeyboardKey key) {
  final named = _specialKeyNames[key];
  if (named != null) return named;
  final l = key.keyLabel;
  if (l.trim().isNotEmpty) return l.toUpperCase();
  return 'key 0x${key.keyId.toRadixString(16)}';
}

final Map<LogicalKeyboardKey, String> _specialKeyNames =
    <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.space: 'Space',
  LogicalKeyboardKey.backspace: 'Backspace',
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.escape: 'Esc',
  LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.comma: ',',
  LogicalKeyboardKey.period: '.',
  LogicalKeyboardKey.slash: '/',
  LogicalKeyboardKey.backslash: r'\',
  LogicalKeyboardKey.underscore: '_',
  LogicalKeyboardKey.minus: '-',
  LogicalKeyboardKey.equal: '=',
  LogicalKeyboardKey.semicolon: ';',
  LogicalKeyboardKey.quote: "'",
  LogicalKeyboardKey.bracketLeft: '[',
  LogicalKeyboardKey.bracketRight: ']',
  LogicalKeyboardKey.arrowLeft: '←',
  LogicalKeyboardKey.arrowRight: '→',
  LogicalKeyboardKey.arrowUp: '↑',
  LogicalKeyboardKey.arrowDown: '↓',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.pageUp: 'PageUp',
  LogicalKeyboardKey.pageDown: 'PageDown',
  LogicalKeyboardKey.f1: 'F1',
  LogicalKeyboardKey.f2: 'F2',
  LogicalKeyboardKey.f3: 'F3',
  LogicalKeyboardKey.f4: 'F4',
  LogicalKeyboardKey.f5: 'F5',
  LogicalKeyboardKey.f6: 'F6',
  LogicalKeyboardKey.f7: 'F7',
  LogicalKeyboardKey.f8: 'F8',
  LogicalKeyboardKey.f9: 'F9',
  LogicalKeyboardKey.f10: 'F10',
  LogicalKeyboardKey.f11: 'F11',
  LogicalKeyboardKey.f12: 'F12',
};

/// US-layout base-symbol → shifted-symbol key-id pairs (printable ASCII code
/// points ARE logical key ids). Used by [KeyChord.canonical] to translate a
/// physically-shifted base key (comma+shift) into the symbol it produces
/// (`<`) on platforms whose logical keys are not layout-resolved — on GTK the
/// logical key already arrives as the shifted symbol and this table never
/// fires.
const Map<int, int> kShiftedSymbolForBase = <int, int>{
  0x60: 0x7E, // `  ~
  0x31: 0x21, // 1  !
  0x32: 0x40, // 2  @
  0x33: 0x23, // 3  #
  0x34: 0x24, // 4  $
  0x35: 0x25, // 5  %
  0x36: 0x5E, // 6  ^
  0x37: 0x26, // 7  &
  0x38: 0x2A, // 8  *
  0x39: 0x28, // 9  (
  0x30: 0x29, // 0  )
  0x2D: 0x5F, // -  _
  0x3D: 0x2B, // =  +
  0x5B: 0x7B, // [  {
  0x5D: 0x7D, // ]  }
  0x5C: 0x7C, // \  |
  0x3B: 0x3A, // ;  :
  0x27: 0x22, // '  "
  0x2C: 0x3C, // ,  <
  0x2E: 0x3E, // .  >
  0x2F: 0x3F, // /  ?
};

/// Whether [keyId] is printable PUNCTUATION — a key whose shift modifier is
/// consumed producing the symbol itself, so canonical chords carry no shift
/// bit for it. Letters (both cases excluded), digits and space keep their
/// shift state: `C-S-a` and `S-SPC` remain expressible.
bool isShiftFoldedKeyId(int keyId) =>
    (keyId >= 0x21 && keyId <= 0x2F) ||
    (keyId >= 0x3A && keyId <= 0x40) ||
    (keyId >= 0x5B && keyId <= 0x60) ||
    (keyId >= 0x7B && keyId <= 0x7E);
