// Emacs key-description → [KeyChordSequence] translation.
//
// Turns an Emacs `kbd`-style key string ("C-x C-s", "M-x", "<f5>", "C-S-a",
// "SPC") into the kit's serialisable [KeyChordSequence] so a harvested binding
// slots straight into [KeymapConfig]. This is the semantic bridge between Emacs
// key notation and Flutter's [LogicalKeyboardKey] world.
//
// Modifier mapping (Emacs → kit):
//   C- → control   S- → shift   M- → alt (Meta≈Alt)   s- → meta (Super)
//   A- → alt       H- → unsupported (hyper has no kit analogue → throws)
//
// Key mapping: printable ASCII maps by code point — Flutter's logical key id for
// a printable key *is* its Unicode code point (keyA == 0x61, digit0 == 0x30,
// minus == 0x2D, space == 0x20), so a single char needs no lookup table. Named
// keys (arrows, function keys, RET/TAB/…) resolve through [LogicalKeyboardKey]
// constants.
//
// Case rule: a bare uppercase letter (`A`) sets shift (`S-a`). Note the known
// nuance that Emacs treats `C-a` and `C-A` as identical (control is
// case-insensitive); this translator applies the uppercase→shift rule uniformly
// and leaves that refinement to a later pass — flagged, not hidden.
//
// Char/backslash tokens: [translateKeyToken] handles a single Emacs char-literal
// or key-string token — stacked modifier escapes (`\C-`, `\M-`, `\S-`, `\s-`,
// possibly combined as `\C-\M-x`), a simple escape (`\s`, `\n`, `\t`, …), or a
// bare printable char — reusing the same printable-ASCII-by-code-point and
// special-key rules. [namedKeyChord] resolves a bare named-key symbol (as in the
// vector form `[f9]` / `[tab]`) to a modifier-free chord. These back the
// harvester's vector, char-literal, and backslash-key-string support.
//
// Out of scope (raises [KbdParseException] so the harvester logs a diagnostic
// rather than emitting a wrong binding): hyper/`H-` (and `\H-`), and any key name
// this table doesn't know.
library;

import 'package:flutter/services.dart';

import '../keymap/key_chord.dart';
import '../keymap/key_chord_sequence.dart';

/// Raised when a key description cannot be translated. [description] is the
/// offending token (a single stroke or the whole string).
class KbdParseException implements Exception {
  /// Create a parse exception with a [message] and the [description] at fault.
  const KbdParseException(this.message, this.description);

  /// What could not be translated.
  final String message;

  /// The offending key text.
  final String description;

  @override
  String toString() => 'KbdParseException($message: "$description")';
}

/// Translate an Emacs key description [desc] (e.g. `"C-x C-s"`) into a
/// [KeyChordSequence]. Strokes are whitespace-separated. Throws
/// [KbdParseException] if any stroke uses an unsupported modifier or key name.
KeyChordSequence parseEmacsKey(String desc) {
  final pieces = desc
      .trim()
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  if (pieces.isEmpty) {
    throw KbdParseException('empty key description', desc);
  }
  return KeyChordSequence(
    <KeyChord>[for (final p in pieces) _parseStroke(p, desc)],
  );
}

/// Translate an Emacs key description [desc], returning `null` instead of
/// throwing on failure — convenient when a diagnostic, not an exception, is
/// wanted.
KeyChordSequence? tryParseEmacsKey(String desc) {
  try {
    return parseEmacsKey(desc);
  } on KbdParseException {
    return null;
  }
}

KeyChord _parseStroke(String stroke, String whole) {
  var rest = stroke;
  var control = false;
  var shift = false;
  var alt = false;
  var meta = false;

  // Peel `X-` modifier prefixes while a key still remains after them.
  while (rest.length > 2 && rest[1] == '-' && _isModChar(rest[0])) {
    switch (rest[0]) {
      case 'C':
        control = true;
      case 'S':
        shift = true;
      case 'M':
        alt = true;
      case 'A':
        alt = true;
      case 's':
        meta = true;
      case 'H':
        throw KbdParseException('hyper (H-) is unsupported', whole);
    }
    rest = rest.substring(2);
  }

  final (keyId, charShift) = _resolveKey(rest, whole);
  return KeyChord(
    keyId: keyId,
    control: control,
    shift: shift || charShift,
    alt: alt,
    meta: meta,
  );
}

bool _isModChar(String c) =>
    c == 'C' || c == 'S' || c == 'M' || c == 's' || c == 'A' || c == 'H';

/// Resolve the key portion of a stroke to `(keyId, impliedShift)`.
(int, bool) _resolveKey(String key, String whole) {
  if (key.isEmpty) {
    throw KbdParseException('missing key after modifiers', whole);
  }

  // `<name>` bracketed key.
  if (key.length >= 3 && key.startsWith('<') && key.endsWith('>')) {
    final name = key.substring(1, key.length - 1).toLowerCase();
    final k = _namedKeys[name];
    if (k == null) {
      throw KbdParseException('unknown named key <$name>', whole);
    }
    return (k.keyId, false);
  }

  // Bare special tokens (Emacs spells these upper-case): SPC TAB RET ESC DEL.
  final special = _specialTokens[key.toUpperCase()];
  if (special != null) {
    return (special.keyId, false);
  }

  // Single character: map by code point (printable ASCII == logical key id).
  if (key.length == 1) {
    final resolved = _resolveCodeUnit(key.codeUnitAt(0));
    if (resolved == null) {
      throw KbdParseException('non-ASCII key "$key"', whole);
    }
    return resolved;
  }

  // Multi-char name without brackets (e.g. "f5", "return").
  final k = _namedKeys[key.toLowerCase()];
  if (k != null) {
    return (k.keyId, false);
  }
  throw KbdParseException('unrecognised key "$key"', whole);
}

/// Resolve a single character *code unit* to `(keyId, impliedShift)`, reusing
/// the printable-ASCII-by-code-point rule (uppercase letter ⇒ shift) and the
/// control-character/special-key table. Returns `null` for a code unit that is
/// neither printable ASCII nor a known control key.
(int, bool)? _resolveCodeUnit(int cu) {
  final special = _controlCharKeys[cu];
  if (special != null) {
    return (special.keyId, false);
  }
  // Letter: normalise to lowercase key id; uppercase implies shift.
  if (_isUpperAlpha(cu)) {
    return (cu + 0x20, true); // 'A'(0x41) → 'a'(0x61)
  }
  if (cu >= 0x20 && cu <= 0x7E) {
    return (cu, false); // lowercase letters, digits, punctuation, space
  }
  return null;
}

/// Translate ONE Emacs char-literal / key-string token into a [KeyChord].
///
/// Accepts stacked modifier escapes `\C-` / `\M-` / `\S-` / `\s-` / `\A-`
/// (e.g. `\C-\M-x`) followed by a single key that is either a simple escape
/// (`\s` space, `\n`, `\t`, `\r`, `\e`, `\d`, `\\`) or a bare printable char.
/// [whole] is the enclosing form used only for diagnostics. Throws
/// [KbdParseException] on hyper (`\H-`) or any token it cannot translate — the
/// caller turns that into a harvester diagnostic rather than a wrong binding.
KeyChord translateKeyToken(String token, String whole) {
  var control = false;
  var shift = false;
  var alt = false;
  var meta = false;

  // Peel leading `\X-` modifier escapes while a key still remains after them.
  var i = 0;
  while (i + 2 < token.length &&
      token.codeUnitAt(i) == 0x5C && // backslash
      token[i + 2] == '-' &&
      _isModChar(token[i + 1])) {
    switch (token[i + 1]) {
      case 'C':
        control = true;
      case 'S':
        shift = true;
      case 'M':
        alt = true;
      case 'A':
        alt = true;
      case 's':
        meta = true;
      case 'H':
        throw KbdParseException(r'hyper (\H-) is unsupported', whole);
    }
    i += 3;
  }

  final rest = token.substring(i);
  if (rest.isEmpty) {
    throw KbdParseException('missing key after modifiers', whole);
  }

  final int cu;
  if (rest.length >= 2 && rest.codeUnitAt(0) == 0x5C) {
    // A simple escape like `\s` / `\n`.
    final esc = _escapeCodeUnit(rest.substring(1));
    if (esc == null) {
      throw KbdParseException('unknown escape "$rest"', whole);
    }
    cu = esc;
  } else if (rest.length == 1) {
    cu = rest.codeUnitAt(0);
  } else {
    throw KbdParseException('unrecognised key token "$rest"', whole);
  }

  final resolved = _resolveCodeUnit(cu);
  if (resolved == null) {
    throw KbdParseException('non-ASCII key token "$rest"', whole);
  }
  final (keyId, charShift) = resolved;
  return KeyChord(
    keyId: keyId,
    control: control,
    shift: shift || charShift,
    alt: alt,
    meta: meta,
  );
}

/// Split a plain backslash key *string* (an [SString] value whose decoded text
/// carries backslash escapes, e.g. `\C-x\C-s`) into its successive tokens — a
/// run of `\X-` modifier escapes then one char/escape — and translate each into
/// a [KeyChord]. [whole] is used only for diagnostics. Throws
/// [KbdParseException] on the first token it cannot translate.
List<KeyChord> translateBackslashKeyString(String s, String whole) {
  final chords = <KeyChord>[];
  var i = 0;
  while (i < s.length) {
    final start = i;
    // Consume leading `\X-` modifier escapes.
    while (i + 2 < s.length &&
        s.codeUnitAt(i) == 0x5C &&
        s[i + 2] == '-' &&
        _isModChar(s[i + 1])) {
      i += 3;
    }
    // Consume the final key: an escape `\x` (backslash + one char) or one char.
    if (i < s.length && s.codeUnitAt(i) == 0x5C) {
      if (i + 1 >= s.length) {
        throw KbdParseException(r'dangling backslash', whole);
      }
      i += 2;
    } else if (i < s.length) {
      i += 1;
    }
    final token = s.substring(start, i);
    if (token.isEmpty) {
      throw KbdParseException('empty key token', whole);
    }
    chords.add(translateKeyToken(token, whole));
  }
  if (chords.isEmpty) {
    throw KbdParseException('empty key string', whole);
  }
  return chords;
}

/// Resolve a bare Emacs named-key *symbol* — the form used inside a vector key
/// like `[f9]` or `[tab]` — to a modifier-free [KeyChord], or `null` when the
/// name is not in the named-key table. Case-insensitive.
KeyChord? namedKeyChord(String name) {
  final k = _namedKeys[name.toLowerCase()];
  if (k == null) return null;
  return KeyChord(keyId: k.keyId);
}

/// Code unit → key for the Emacs simple escapes `\n \t \r \e \s \d \\`.
int? _escapeCodeUnit(String c) {
  switch (c) {
    case 'n':
      return 0x0A;
    case 't':
      return 0x09;
    case 'r':
      return 0x0D;
    case 'e':
      return 0x1B;
    case 's':
      return 0x20; // space
    case 'd':
      return 0x7F; // delete
    case r'\':
      return 0x5C;
    default:
      return null;
  }
}

bool _isUpperAlpha(int cu) => cu >= 0x41 && cu <= 0x5A;

/// Control-character / non-printable code units that map to a named key rather
/// than to a printable-ASCII code point. Space (0x20) is intentionally absent:
/// it is printable and its code point already equals its logical key id.
final Map<int, LogicalKeyboardKey> _controlCharKeys = <int, LogicalKeyboardKey>{
  0x08: LogicalKeyboardKey.backspace,
  0x09: LogicalKeyboardKey.tab,
  0x0A: LogicalKeyboardKey.enter,
  0x0D: LogicalKeyboardKey.enter,
  0x1B: LogicalKeyboardKey.escape,
  0x7F: LogicalKeyboardKey.backspace, // Emacs DEL
};

/// Bare Emacs key tokens that are not printable characters.
final Map<String, LogicalKeyboardKey> _specialTokens =
    <String, LogicalKeyboardKey>{
  'SPC': LogicalKeyboardKey.space,
  'TAB': LogicalKeyboardKey.tab,
  'RET': LogicalKeyboardKey.enter,
  'ESC': LogicalKeyboardKey.escape,
  'DEL': LogicalKeyboardKey.backspace, // Emacs DEL is Backspace
};

/// `<name>` keys and their unbracketed spellings.
final Map<String, LogicalKeyboardKey> _namedKeys = <String, LogicalKeyboardKey>{
  'return': LogicalKeyboardKey.enter,
  'ret': LogicalKeyboardKey.enter,
  'enter': LogicalKeyboardKey.enter,
  'tab': LogicalKeyboardKey.tab,
  'space': LogicalKeyboardKey.space,
  'spc': LogicalKeyboardKey.space,
  'escape': LogicalKeyboardKey.escape,
  'esc': LogicalKeyboardKey.escape,
  'backspace': LogicalKeyboardKey.backspace,
  'del': LogicalKeyboardKey.backspace,
  'delete': LogicalKeyboardKey.delete,
  'deletechar': LogicalKeyboardKey.delete,
  'insert': LogicalKeyboardKey.insert,
  'up': LogicalKeyboardKey.arrowUp,
  'down': LogicalKeyboardKey.arrowDown,
  'left': LogicalKeyboardKey.arrowLeft,
  'right': LogicalKeyboardKey.arrowRight,
  'home': LogicalKeyboardKey.home,
  'end': LogicalKeyboardKey.end,
  'prior': LogicalKeyboardKey.pageUp,
  'pageup': LogicalKeyboardKey.pageUp,
  'next': LogicalKeyboardKey.pageDown,
  'pagedown': LogicalKeyboardKey.pageDown,
  'f1': LogicalKeyboardKey.f1,
  'f2': LogicalKeyboardKey.f2,
  'f3': LogicalKeyboardKey.f3,
  'f4': LogicalKeyboardKey.f4,
  'f5': LogicalKeyboardKey.f5,
  'f6': LogicalKeyboardKey.f6,
  'f7': LogicalKeyboardKey.f7,
  'f8': LogicalKeyboardKey.f8,
  'f9': LogicalKeyboardKey.f9,
  'f10': LogicalKeyboardKey.f10,
  'f11': LogicalKeyboardKey.f11,
  'f12': LogicalKeyboardKey.f12,
};
