/// Reads licence fields out of a TrueType/OpenType `name` table.
///
/// This exists so a [BundledFont] declaration can be CHECKED against the font
/// it describes instead of trusted. The failure it catches is real and silent:
/// `fontTools` drops name IDs 13 and 14 when subsetting unless asked not to,
/// so a re-subset ships an OFL font stripped of the licence it is required to
/// carry — and an About dialog naming a licence URL the font no longer asserts
/// is a claim the application cannot support.
///
/// Measured in this family, 2026-08-29: `SarasaFixedJ-*.ttf` carries
/// `id14 = https://openfontlicense.org/`, while a `SarasaUiJ-Bold.ttf` copy in
/// a sibling repo has BOTH id13 and id14 absent. Same upstream, same licence,
/// one copy stripped — which is exactly why this is a test and not a comment.
///
/// Deliberately a small hand-rolled parser: reading two fields from one table
/// does not justify a font-parsing dependency in a UI package, and the format
/// is stable (the `name` table has been unchanged since TrueType 1.0).
library;

import 'dart:convert';
import 'dart:typed_data';

/// Name IDs defined by the OpenType spec that matter for licensing.
class FontNameId {
  /// Licence description — the full text, for fonts that carry it inline.
  static const int licenseDescription = 13;

  /// Licence URL — the licence's canonical home.
  static const int licenseUrl = 14;
}

/// Returns the value of [nameId] from [fontBytes], or `null` when the font
/// does not carry that name record.
///
/// A `null` is the interesting answer: it means the field was stripped, which
/// is the compliance failure this function exists to surface.
String? readFontName(Uint8List fontBytes, int nameId) {
  final ByteData d = ByteData.sublistView(fontBytes);
  if (fontBytes.lengthInBytes < 12) return null;

  // Offset table: sfntVersion(4), numTables(2), then 6 bytes we skip.
  final int numTables = d.getUint16(4);
  int nameOffset = -1;
  for (int i = 0; i < numTables; i++) {
    final int rec = 12 + i * 16;
    if (rec + 16 > fontBytes.lengthInBytes) return null;
    final String tag = String.fromCharCodes(fontBytes.sublist(rec, rec + 4));
    if (tag == 'name') {
      nameOffset = d.getUint32(rec + 8);
      break;
    }
  }
  if (nameOffset < 0 || nameOffset + 6 > fontBytes.lengthInBytes) return null;

  // name table header: format(2), count(2), stringOffset(2).
  final int count = d.getUint16(nameOffset + 2);
  final int storage = nameOffset + d.getUint16(nameOffset + 4);

  for (int i = 0; i < count; i++) {
    final int rec = nameOffset + 6 + i * 12;
    if (rec + 12 > fontBytes.lengthInBytes) return null;
    if (d.getUint16(rec + 6) != nameId) continue;

    final int platformId = d.getUint16(rec);
    final int length = d.getUint16(rec + 8);
    final int offset = storage + d.getUint16(rec + 10);
    if (offset + length > fontBytes.lengthInBytes) continue;
    final Uint8List raw = fontBytes.sublist(offset, offset + length);

    // Platform 1 (Macintosh) is single-byte; platform 0 (Unicode) and 3
    // (Windows) are UTF-16BE. Windows records are the ones that survive
    // subsetting most often, so both paths matter.
    if (platformId == 1) return latin1.decode(raw, allowInvalid: true);
    final StringBuffer b = StringBuffer();
    for (int j = 0; j + 1 < raw.length; j += 2) {
      b.writeCharCode((raw[j] << 8) | raw[j + 1]);
    }
    return b.toString();
  }
  return null;
}
