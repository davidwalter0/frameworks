// Tests for Emacs key-description → KeyChordSequence translation.
import 'package:desktop_kit/desktop_kit_config.dart';
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('single stroke', () {
    test('plain letter maps by code point, no modifiers', () {
      final seq = parseEmacsKey('a');
      expect(seq.length, 1);
      final c = seq.strokes.single;
      expect(c.keyId, LogicalKeyboardKey.keyA.keyId);
      expect(c.control || c.shift || c.alt || c.meta, isFalse);
    });

    test('C- sets control, M- sets alt (Meta≈Alt)', () {
      expect(parseEmacsKey('C-x').strokes.single.control, isTrue);
      expect(parseEmacsKey('M-x').strokes.single.alt, isTrue);
    });

    test('s- sets meta (Super)', () {
      expect(parseEmacsKey('s-x').strokes.single.meta, isTrue);
    });

    test('uppercase letter implies shift', () {
      final c = parseEmacsKey('A').strokes.single;
      expect(c.keyId, LogicalKeyboardKey.keyA.keyId);
      expect(c.shift, isTrue);
    });

    test('explicit S- combines with C-', () {
      final c = parseEmacsKey('C-S-a').strokes.single;
      expect(c.control, isTrue);
      expect(c.shift, isTrue);
    });

    test('named and special keys', () {
      expect(parseEmacsKey('<f5>').strokes.single.keyId,
          LogicalKeyboardKey.f5.keyId);
      expect(parseEmacsKey('SPC').strokes.single.keyId,
          LogicalKeyboardKey.space.keyId);
      expect(parseEmacsKey('TAB').strokes.single.keyId,
          LogicalKeyboardKey.tab.keyId);
      expect(parseEmacsKey('RET').strokes.single.keyId,
          LogicalKeyboardKey.enter.keyId);
      expect(parseEmacsKey('<return>').strokes.single.keyId,
          LogicalKeyboardKey.enter.keyId);
    });

    test('control-minus keeps "-" as the key', () {
      final c = parseEmacsKey('C--').strokes.single;
      expect(c.control, isTrue);
      expect(c.keyId, LogicalKeyboardKey.minus.keyId);
    });
  });

  group('multi stroke', () {
    test('C-x C-s → two control strokes, kit token + label', () {
      final seq = parseEmacsKey('C-x C-s');
      expect(seq.length, 2);
      expect(seq.strokes[0].keyId, LogicalKeyboardKey.keyX.keyId);
      expect(seq.strokes[1].keyId, LogicalKeyboardKey.keyS.keyId);
      expect(seq.strokes.every((c) => c.control), isTrue);
      expect(seq.label, 'Ctrl+X Ctrl+S');
      // Round-trips through the kit's serialisable sequence form.
      expect(KeyChordSequence.parse(seq.token), seq);
    });

    test('C-c a → prefix chord then a plain letter', () {
      final seq = parseEmacsKey('C-c a');
      expect(seq.length, 2);
      expect(seq.strokes[0].control, isTrue);
      expect(seq.strokes[1].control, isFalse);
    });
  });

  group('char / backslash token translation', () {
    test(r'\C-x sets control on the base char x', () {
      final c = translateKeyToken(r'\C-x', r'\C-x');
      expect(c.control, isTrue);
      expect(c.keyId, LogicalKeyboardKey.keyX.keyId);
    });

    test(r'stacked \C-\M-x sets control + alt', () {
      final c = translateKeyToken(r'\C-\M-x', r'\C-\M-x');
      expect(c.control, isTrue);
      expect(c.alt, isTrue);
      expect(c.keyId, LogicalKeyboardKey.keyX.keyId);
    });

    test(r'\s escape resolves to space; \s- is the super modifier', () {
      expect(translateKeyToken(r'\s', r'\s').keyId,
          LogicalKeyboardKey.space.keyId);
      final sup = translateKeyToken(r'\s-x', r'\s-x');
      expect(sup.meta, isTrue);
      expect(sup.keyId, LogicalKeyboardKey.keyX.keyId);
    });

    test('a bare printable char has no modifiers', () {
      final c = translateKeyToken('a', 'a');
      expect(c.keyId, LogicalKeyboardKey.keyA.keyId);
      expect(c.control || c.shift || c.alt || c.meta, isFalse);
    });

    test(r'hyper \H- token is rejected', () {
      expect(() => translateKeyToken(r'\H-x', r'\H-x'),
          throwsA(isA<KbdParseException>()));
    });

    test(r'\C-x\C-s string splits into two control strokes', () {
      final chords = translateBackslashKeyString(r'\C-x\C-s', r'\C-x\C-s');
      expect(chords, hasLength(2));
      expect(chords[0].control && chords[1].control, isTrue);
      expect(chords[0].keyId, LogicalKeyboardKey.keyX.keyId);
      expect(chords[1].keyId, LogicalKeyboardKey.keyS.keyId);
    });

    test('namedKeyChord resolves table names, else null', () {
      expect(namedKeyChord('f9')!.keyId, LogicalKeyboardKey.f9.keyId);
      expect(namedKeyChord('tab')!.keyId, LogicalKeyboardKey.tab.keyId);
      expect(namedKeyChord('nope'), isNull);
    });
  });

  group('unsupported', () {
    test('hyper throws; tryParse yields null', () {
      expect(() => parseEmacsKey('H-x'), throwsA(isA<KbdParseException>()));
      expect(tryParseEmacsKey('H-x'), isNull);
    });

    test('unknown named key throws', () {
      expect(() => parseEmacsKey('<nope>'), throwsA(isA<KbdParseException>()));
    });

    test('empty description throws', () {
      expect(() => parseEmacsKey('   '), throwsA(isA<KbdParseException>()));
    });
  });
}
