// Tests for KeymapMode's persistence codec (jsonValue / fromJson).
//
// KeymapMode.fromJson has a wildcard fallback to KeymapMode.emacs, which the
// compiler cannot enforce — a forgotten arm there would silently strand a
// user who chose CUA back on Emacs. This test is the guard for that trap,
// mirroring the same shape used for NavStyle in the eedit app.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('KeymapMode.jsonValue matches the enum name for every value', () {
    for (final KeymapMode mode in KeymapMode.values) {
      expect(mode.jsonValue, mode.name);
    }
  });

  test('KeymapMode.cua has the expected JSON value', () {
    expect(KeymapMode.cua.jsonValue, 'cua');
  });

  test('KeymapMode.fromJson round-trips every value', () {
    for (final KeymapMode mode in KeymapMode.values) {
      expect(KeymapMode.fromJson(mode.jsonValue), mode);
    }
  });

  test('KeymapMode.fromJson falls back to emacs for unknown or null input', () {
    expect(KeymapMode.fromJson('nonsense'), KeymapMode.emacs);
    expect(KeymapMode.fromJson(null), KeymapMode.emacs);
    expect(KeymapMode.fromJson(''), KeymapMode.emacs);
  });
}
