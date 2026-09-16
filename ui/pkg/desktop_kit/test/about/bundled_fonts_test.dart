import 'dart:typed_data';

import 'package:desktop_kit/desktop_kit_about.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal but real sfnt: an offset table, one `name` table, and two name
/// records (IDs 13 and 14) as a Windows/UTF-16BE platform-3 entry.
///
/// Built rather than checked in as a fixture so the test carries no font
/// binary of its own — a package that ships fonts to test font licensing would
/// be its own small licence problem.
Uint8List _sfntWithNames(Map<int, String> names) {
  final List<int> ids = names.keys.toList()..sort();

  final BytesBuilder storage = BytesBuilder();
  final List<({int id, int off, int len})> recs =
      <({int id, int off, int len})>[];
  for (final int id in ids) {
    final String v = names[id]!;
    final int off = storage.length;
    for (final int c in v.codeUnits) {
      storage.addByte((c >> 8) & 0xff);
      storage.addByte(c & 0xff);
    }
    recs.add((id: id, off: off, len: v.codeUnits.length * 2));
  }
  final Uint8List strings = storage.toBytes();

  final int nameLen = 6 + recs.length * 12 + strings.length;
  final Uint8List name = Uint8List(nameLen);
  final ByteData nd = ByteData.sublistView(name);
  nd.setUint16(0, 0); // format
  nd.setUint16(2, recs.length); // count
  nd.setUint16(4, 6 + recs.length * 12); // stringOffset
  for (int i = 0; i < recs.length; i++) {
    final int p = 6 + i * 12;
    nd.setUint16(p, 3); // platformID: Windows
    nd.setUint16(p + 2, 1); // encodingID: UCS-2
    nd.setUint16(p + 4, 0x0409); // languageID: en-US
    nd.setUint16(p + 6, recs[i].id);
    nd.setUint16(p + 8, recs[i].len);
    nd.setUint16(p + 10, recs[i].off);
  }
  name.setRange(6 + recs.length * 12, nameLen, strings);

  const int nameOffset = 12 + 16; // offset table + one table record
  final Uint8List font = Uint8List(nameOffset + nameLen);
  final ByteData fd = ByteData.sublistView(font);
  fd.setUint32(0, 0x00010000); // sfntVersion
  fd.setUint16(4, 1); // numTables
  font.setRange(12, 16, 'name'.codeUnits);
  fd.setUint32(12 + 8, nameOffset);
  fd.setUint32(12 + 12, nameLen);
  font.setRange(nameOffset, nameOffset + nameLen, name);
  return font;
}

void main() {
  group('readFontName', () {
    test('reads the licence URL and description', () {
      final Uint8List f = _sfntWithNames(<int, String>{
        FontNameId.licenseDescription:
            'This Font Software is licensed under the SIL OFL.',
        FontNameId.licenseUrl: 'https://openfontlicense.org/',
      });
      expect(readFontName(f, FontNameId.licenseUrl),
          'https://openfontlicense.org/');
      expect(readFontName(f, FontNameId.licenseDescription),
          startsWith('This Font Software'));
    });

    // The compliance failure this whole file exists for: fontTools drops name
    // IDs 13/14 on subset by default, so a re-subset ships an OFL font with no
    // licence in it. The reader must report that as absent, not as empty
    // string or a crash — a caller cannot act on what it cannot distinguish.
    test('returns null for a stripped licence field', () {
      final Uint8List f = _sfntWithNames(<int, String>{1: 'Some Family'});
      expect(readFontName(f, FontNameId.licenseUrl), isNull);
      expect(readFontName(f, FontNameId.licenseDescription), isNull);
    });

    test('survives truncated and empty input rather than throwing', () {
      expect(readFontName(Uint8List(0), FontNameId.licenseUrl), isNull);
      expect(readFontName(Uint8List(8), FontNameId.licenseUrl), isNull);
      final Uint8List f = _sfntWithNames(<int, String>{
        FontNameId.licenseUrl: 'https://scripts.sil.org/OFL',
      });
      expect(readFontName(f.sublist(0, f.length ~/ 2), FontNameId.licenseUrl),
          isNull);
    });
  });

  group('bundledFontsSection', () {
    const BundledFont klee = BundledFont(
      family: 'Klee One',
      licence: 'SIL Open Font License 1.1',
      licenceUrl: 'https://scripts.sil.org/OFL',
      assets: <String>['assets/fonts/KleeOne-OFL.txt'],
      copyright: 'Copyright 2020 The Klee Project Authors',
    );
    const BundledFont sarasa = BundledFont(
      family: 'Sarasa Gothic',
      licence: 'SIL Open Font License 1.1',
      licenceUrl: 'https://openfontlicense.org/',
      assets: <String>['assets/fonts/SarasaFixedJ-OFL.txt'],
    );

    test('is null with no fonts, so a caller need not branch', () {
      expect(bundledFontsSection(const <BundledFont>[]), isNull);
    });

    test('names family, licence and copyright, and links the shared URL', () {
      final AboutSection s = bundledFontsSection(const <BundledFont>[klee])!;
      expect(s.body, contains('Klee One — SIL Open Font License 1.1'));
      expect(s.body, contains('Copyright 2020'));
      expect(s.linkUrl, 'https://scripts.sil.org/OFL');
    });

    // Two OFL fonts, two canonical homes — real, not hypothetical: Sarasa's
    // name table points at openfontlicense.org and Klee One's at
    // scripts.sil.org. Promoting either to stand for both would make the
    // dialog assert something the other font does not say.
    test('when URLs differ, each is written inline and none is promoted', () {
      final AboutSection s =
          bundledFontsSection(const <BundledFont>[klee, sarasa])!;
      expect(s.linkUrl, isNull);
      expect(s.body, contains('https://scripts.sil.org/OFL'));
      expect(s.body, contains('https://openfontlicense.org/'));
    });

    test('points the reader at the full text', () {
      final AboutSection s = bundledFontsSection(const <BundledFont>[klee])!;
      expect(s.body, contains('Open source licenses'));
    });
  });
}
