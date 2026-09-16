// Tests for Keymaps.forMode(overrides:) — layering a user KeymapConfig over
// the kit defaults, including host-contributed intents.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _KanaIntent extends Intent {
  const _KanaIntent();
}

/// The intent bound to [key]+ctrl in [keymap], or null.
Intent? _ctrlIntent(
  Map<ShortcutActivator, Intent> keymap,
  LogicalKeyboardKey key,
) {
  for (final e in keymap.entries) {
    final k = e.key;
    if (k is SingleActivator &&
        k.trigger == key &&
        k.control &&
        !k.shift &&
        !k.alt &&
        !k.meta) {
      return e.value;
    }
  }
  return null;
}

void main() {
  final reg = KeymapRegistry.defaults();

  test('no overrides returns the defaults unchanged', () {
    final base = Keymaps.forMode(KeymapMode.emacs);
    final same = Keymaps.forMode(KeymapMode.emacs, overrides: null);
    expect(same.length, base.length);
  });

  test('empty override config falls through to defaults', () {
    final base = Keymaps.forMode(KeymapMode.emacs);
    final same =
        Keymaps.forMode(KeymapMode.emacs, overrides: KeymapConfig.empty);
    expect(same.length, base.length);
  });

  group('rebinding an intent moves its chord', () {
    test('killLine C-k -> C-z drops the default chord, adds the new one', () {
      // C-z carries no default binding in the Emacs map, so it is safe to use
      // as the rebind target here.
      final override = KeymapConfig({
        KeymapMode.emacs: {
          KeyChordSequence.single(KeyChord(
              keyId: LogicalKeyboardKey.keyZ.keyId, control: true)): 'killLine',
        },
      });
      final map = Keymaps.forMode(
        KeymapMode.emacs,
        overrides: override,
        registry: reg,
      );
      // New chord bound:
      expect(_ctrlIntent(map, LogicalKeyboardKey.keyZ), isA<KillLineIntent>());
      // Old default chord for killLine removed (C-k no longer kills):
      expect(_ctrlIntent(map, LogicalKeyboardKey.keyK),
          isNot(isA<KillLineIntent>()));
      // An untouched intent keeps its default (C-a still move-line-start):
      expect(
        _ctrlIntent(map, LogicalKeyboardKey.keyA),
        isA<MoveLineStartIntent>(),
      );
    });
  });

  group('host-contributed intents', () {
    test('a host registry resolves an app intent id in the override', () {
      final hostReg = KeymapRegistry.defaults()
        ..register(const KeymapAction(
          id: 'kana',
          label: 'Toggle kana',
          group: 'Kana',
          factory: _KanaIntent.new,
        ));
      final override = KeymapConfig({
        KeymapMode.emacs: {
          KeyChordSequence.single(KeyChord(
              keyId: LogicalKeyboardKey.keyQ.keyId, control: true)): 'kana',
        },
      });
      final map = Keymaps.forMode(
        KeymapMode.emacs,
        overrides: override,
        registry: hostReg,
      );
      expect(_ctrlIntent(map, LogicalKeyboardKey.keyQ), isA<_KanaIntent>());
    });

    test('without the host registry the unknown id is dropped', () {
      final override = KeymapConfig({
        KeymapMode.emacs: {
          KeyChordSequence.single(KeyChord(
              keyId: LogicalKeyboardKey.keyQ.keyId, control: true)): 'kana',
        },
      });
      final map = Keymaps.forMode(KeymapMode.emacs, overrides: override);
      expect(_ctrlIntent(map, LogicalKeyboardKey.keyQ), isNull);
    });
  });
}
