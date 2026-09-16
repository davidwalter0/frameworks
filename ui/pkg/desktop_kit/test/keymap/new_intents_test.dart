// Tests for the batch of nine additive editor intents (open-line,
// transpose-chars, kill-whole-line, upcase/downcase/capitalize-word,
// just-one-space, delete-horizontal-space, recenter): registry membership +
// labels, and default Emacs keymap bindings.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns true if [keymap] contains a [SingleActivator] with [logicalKey]
/// and the given modifier flags whose value is of type [T].
bool _has<T extends Intent>(
  Map<ShortcutActivator, Intent> keymap,
  LogicalKeyboardKey logicalKey, {
  bool ctrl = false,
  bool alt = false,
  bool shift = false,
  bool meta = false,
}) {
  for (final entry in keymap.entries) {
    if (entry.value is! T) continue;
    final sa = entry.key;
    if (sa is! SingleActivator) continue;
    if (sa.trigger != logicalKey) continue;
    if (sa.control != ctrl) continue;
    if (sa.alt != alt) continue;
    if (sa.shift != shift) continue;
    if (sa.meta != meta) continue;
    return true;
  }
  return false;
}

void main() {
  group('KeymapRegistry.defaults — new intents', () {
    final reg = KeymapRegistry.defaults();

    test('contains each new id with the right label', () {
      const expected = <String, String>{
        'openLine': 'Open line',
        'transposeChars': 'Transpose characters',
        'killWholeLine': 'Kill whole line',
        'upcaseWord': 'Upcase word',
        'downcaseWord': 'Downcase word',
        'capitalizeWord': 'Capitalize word',
        'justOneSpace': 'Just one space',
        'deleteHorizontalSpace': 'Delete horizontal space',
        'recenter': 'Recenter',
      };
      for (final entry in expected.entries) {
        expect(reg.contains(entry.key), isTrue, reason: entry.key);
        expect(reg.action(entry.key)!.label, entry.value, reason: entry.key);
      }
    });

    test('intentFor builds the right Intent type for each new id', () {
      expect(reg.intentFor('openLine'), isA<OpenLineIntent>());
      expect(reg.intentFor('transposeChars'), isA<TransposeCharsIntent>());
      expect(reg.intentFor('killWholeLine'), isA<KillWholeLineIntent>());
      expect(reg.intentFor('upcaseWord'), isA<UpcaseWordIntent>());
      expect(reg.intentFor('downcaseWord'), isA<DowncaseWordIntent>());
      expect(reg.intentFor('capitalizeWord'), isA<CapitalizeWordIntent>());
      expect(reg.intentFor('justOneSpace'), isA<JustOneSpaceIntent>());
      expect(reg.intentFor('deleteHorizontalSpace'),
          isA<DeleteHorizontalSpaceIntent>());
      expect(reg.intentFor('recenter'), isA<RecenterIntent>());
    });
  });

  group('Keymaps.forMode(emacs) — new default bindings', () {
    late Map<ShortcutActivator, Intent> emacs;

    setUpAll(() {
      emacs = Keymaps.forMode(KeymapMode.emacs);
    });

    test('C-o → OpenLineIntent', () {
      expect(
        _has<OpenLineIntent>(emacs, LogicalKeyboardKey.keyO, ctrl: true),
        isTrue,
      );
    });

    test('C-t → TransposeCharsIntent', () {
      expect(
        _has<TransposeCharsIntent>(emacs, LogicalKeyboardKey.keyT, ctrl: true),
        isTrue,
      );
    });

    test('Ctrl+Shift+Backspace → KillWholeLineIntent', () {
      expect(
        _has<KillWholeLineIntent>(emacs, LogicalKeyboardKey.backspace,
            ctrl: true, shift: true),
        isTrue,
      );
    });

    test('M-u (Alt+U) → UpcaseWordIntent', () {
      expect(
        _has<UpcaseWordIntent>(emacs, LogicalKeyboardKey.keyU, alt: true),
        isTrue,
      );
    });

    test('M-l (Alt+L) → DowncaseWordIntent', () {
      expect(
        _has<DowncaseWordIntent>(emacs, LogicalKeyboardKey.keyL, alt: true),
        isTrue,
      );
    });

    test('M-c (Alt+C) → CapitalizeWordIntent', () {
      expect(
        _has<CapitalizeWordIntent>(emacs, LogicalKeyboardKey.keyC, alt: true),
        isTrue,
      );
    });

    test('M-SPC (Alt+Space) → JustOneSpaceIntent', () {
      expect(
        _has<JustOneSpaceIntent>(emacs, LogicalKeyboardKey.space, alt: true),
        isTrue,
      );
    });

    test('M-\\ (Alt+Backslash) → DeleteHorizontalSpaceIntent', () {
      expect(
        _has<DeleteHorizontalSpaceIntent>(emacs, LogicalKeyboardKey.backslash,
            alt: true),
        isTrue,
      );
    });

    test('C-l → RecenterIntent', () {
      expect(
        _has<RecenterIntent>(emacs, LogicalKeyboardKey.keyL, ctrl: true),
        isTrue,
      );
    });

    test('C-l (RecenterIntent) and M-l (DowncaseWordIntent) coexist', () {
      // Same physical key, different modifiers — both intents must resolve.
      expect(
        _has<RecenterIntent>(emacs, LogicalKeyboardKey.keyL, ctrl: true),
        isTrue,
      );
      expect(
        _has<DowncaseWordIntent>(emacs, LogicalKeyboardKey.keyL, alt: true),
        isTrue,
      );
    });
  });
}
