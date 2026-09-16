// Tests for KeyChord: serialisation, activator conversion, labels, equality.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KeyChord token round-trip', () {
    test('Ctrl+Shift+Y encodes flags then keyId and parses back', () {
      final chord = KeyChord(
        keyId: LogicalKeyboardKey.keyY.keyId,
        control: true,
        shift: true,
      );
      expect(chord.token, 'CS-${LogicalKeyboardKey.keyY.keyId}');
      expect(KeyChord.parse(chord.token), chord);
    });

    test('no-modifier chord (F1) has a leading dash', () {
      final chord = KeyChord(keyId: LogicalKeyboardKey.f1.keyId);
      expect(chord.token, '-${LogicalKeyboardKey.f1.keyId}');
      expect(KeyChord.parse(chord.token), chord);
    });

    test('all four modifiers in canonical CSAM order', () {
      final chord = KeyChord(
        keyId: LogicalKeyboardKey.keyF.keyId,
        control: true,
        shift: true,
        alt: true,
        meta: true,
      );
      expect(chord.token, 'CSAM-${LogicalKeyboardKey.keyF.keyId}');
      final back = KeyChord.parse(chord.token);
      expect(back.control && back.shift && back.alt && back.meta, isTrue);
    });

    test('parse rejects malformed tokens', () {
      expect(() => KeyChord.parse('no-separator-but-not-int'),
          throwsFormatException);
      expect(() => KeyChord.parse('CS'), throwsFormatException);
    });
  });

  group('KeyChord <-> SingleActivator', () {
    test('fromActivator then toActivator preserves trigger + modifiers', () {
      const activator = SingleActivator(
        LogicalKeyboardKey.keyK,
        control: true,
      );
      final chord = KeyChord.fromActivator(activator);
      expect(chord.keyId, LogicalKeyboardKey.keyK.keyId);
      expect(chord.control, isTrue);
      final round = chord.toActivator();
      expect(round.trigger, LogicalKeyboardKey.keyK);
      expect(round.control, isTrue);
      expect(round.shift, isFalse);
    });

    test('trigger resolves keyId back to the LogicalKeyboardKey', () {
      final chord = KeyChord(keyId: LogicalKeyboardKey.space.keyId);
      expect(chord.trigger, LogicalKeyboardKey.space);
    });
  });

  group('KeyChord label', () {
    test('modifier names join with the key label in Ctrl/Shift/Alt/Meta order',
        () {
      final chord = KeyChord(
        keyId: LogicalKeyboardKey.keyY.keyId,
        control: true,
        shift: true,
      );
      expect(chord.label, 'Ctrl+Shift+Y');
    });

    test('special keys use friendly names', () {
      expect(
        KeyChord(keyId: LogicalKeyboardKey.space.keyId, control: true).label,
        'Ctrl+Space',
      );
      expect(KeyChord(keyId: LogicalKeyboardKey.f1.keyId).label, 'F1');
      // Modifier order is canonical Ctrl, Shift, Alt, Meta.
      expect(
        KeyChord(keyId: LogicalKeyboardKey.comma.keyId, alt: true, shift: true)
            .label,
        'Shift+Alt+,',
      );
    });
  });

  group('KeyChord equality', () {
    test('value equality + hashCode over the five fields', () {
      const a = KeyChord(keyId: 1, control: true);
      const b = KeyChord(keyId: 1, control: true);
      const c = KeyChord(keyId: 1, shift: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('usable as a Map key', () {
      // Not a const map: KeyChord overrides ==, so it cannot be a const-map key.
      final map = <KeyChord, String>{
        const KeyChord(keyId: 1, control: true): 'x',
      };
      expect(map[const KeyChord(keyId: 1, control: true)], 'x');
    });
  });

  group('isModifierKey', () {
    test('true for bare modifier keys, false for triggers', () {
      expect(isModifierKey(LogicalKeyboardKey.controlLeft), isTrue);
      expect(isModifierKey(LogicalKeyboardKey.shift), isTrue);
      expect(isModifierKey(LogicalKeyboardKey.metaRight), isTrue);
      expect(isModifierKey(LogicalKeyboardKey.keyA), isFalse);
      expect(isModifierKey(LogicalKeyboardKey.f1), isFalse);
    });
  });
}
