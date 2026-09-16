import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart' show FontWeight;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseFcList', () {
    test('keeps the primary name, drops localized aliases, dedups + sorts', () {
      const raw = 'Sarasa UI J,更紗ゴシック UI J\nDejaVu Sans\nDejaVu Sans\n';
      expect(parseFcList(raw), ['DejaVu Sans', 'Sarasa UI J']);
    });
    test('unescapes a backslash-escaped comma in the family name', () {
      expect(parseFcList(r'Foo\, Bar'), ['Foo, Bar']);
    });
    test('empty input → empty', () => expect(parseFcList(''), isEmpty));
  });

  group('filterFonts', () {
    const fams = ['Arial', 'Sarasa UI J', 'DejaVu Sans', 'Noto Sans'];
    test('case-insensitive substring', () {
      expect(filterFonts(fams, 'sans'), ['DejaVu Sans', 'Noto Sans']);
    });
    test('empty query returns all (up to limit)', () {
      expect(filterFonts(fams, ''), fams);
    });
    test('limit caps the result count', () {
      expect(filterFonts(fams, '', limit: 2).length, 2);
    });
  });

  group('splitFamilyWeight', () {
    test('trailing weight word is split off a multi-word family', () {
      expect(
        splitFamilyWeight('Sarasa UI J Light'),
        ('Sarasa UI J', FontWeight.w300),
      );
    });
    test('single-token compound weight (ExtraBold) is recognised', () {
      expect(
        splitFamilyWeight('JetBrains Mono ExtraBold'),
        ('JetBrains Mono', FontWeight.w800),
      );
    });
    test('a recognised final word wins even after another weighty word', () {
      // "Light" is itself a weight word, so only it is stripped (w300) — the
      // family keeps "Extra".
      expect(
        splitFamilyWeight('Foo Extra Light'),
        ('Foo Extra', FontWeight.w300),
      );
    });
    test('no recognised weight → null weight, family unchanged', () {
      expect(splitFamilyWeight('Cantarell'), ('Cantarell', null));
    });
    test('empty → ("", null)', () {
      expect(splitFamilyWeight(''), ('', null));
    });
  });

  group('currentFontOs', () {
    test('returns one of the known platform tags', () {
      expect(
        currentFontOs(),
        anyOf('macos', 'windows', 'linux', 'other'),
      );
    });
  });
}
