// Tests for KeymapRegistry: defaults, id<->intent round-trip, grouping,
// host-contributed intents.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A host-contributed intent (mimics voicelab' kana intents).
class _ConvertKatakanaIntent extends Intent {
  const _ConvertKatakanaIntent();
}

void main() {
  group('KeymapRegistry.defaults', () {
    test('registers all built-in editor intents', () {
      final reg = KeymapRegistry.defaults();
      // Bumped 2026-08-23: + saveBuffersKillTerminal (C-x C-c).
      expect(reg.actions.length, 91);
      expect(reg.contains('killLine'), isTrue);
      expect(reg.contains('help'), isTrue);
      expect(reg.contains('describeKey'), isTrue);
      expect(reg.contains('nonexistent'), isFalse);
    });

    test('intentFor(id) builds the right Intent type', () {
      final reg = KeymapRegistry.defaults();
      expect(reg.intentFor('killLine'), isA<KillLineIntent>());
      expect(reg.intentFor('save'), isA<SaveBufferIntent>());
      expect(reg.intentFor('unknown'), isNull);
    });

    test('idFor(intent) reverses by runtime type', () {
      final reg = KeymapRegistry.defaults();
      expect(reg.idFor(const KillLineIntent()), 'killLine');
      expect(reg.idFor(const HelpIntent()), 'help');
      expect(reg.idFor(const _ConvertKatakanaIntent()), isNull);
    });

    test('grouped preserves group + registration order', () {
      final reg = KeymapRegistry.defaults();
      final groups = reg.grouped;
      expect(groups.keys.first, 'Motions');
      expect(groups['Motions']!.first.id, 'moveLineStart');
      expect(groups.keys, contains('Kill ring'));
      expect(groups.keys, contains('Help'));
    });
  });

  group('host-contributed intents', () {
    test('register adds an action that round-trips', () {
      final reg = KeymapRegistry.defaults()
        ..register(
          const KeymapAction(
            id: 'convertKatakana',
            label: 'Convert to Katakana',
            group: 'Kana',
            factory: _ConvertKatakanaIntent.new,
          ),
        );
      expect(reg.actions.length, 92);
      expect(reg.intentFor('convertKatakana'), isA<_ConvertKatakanaIntent>());
      expect(reg.idFor(const _ConvertKatakanaIntent()), 'convertKatakana');
      expect(reg.grouped['Kana']!.single.id, 'convertKatakana');
    });

    test('re-registering an id replaces without duplicating order', () {
      final reg = KeymapRegistry()
        ..register(const KeymapAction(
            id: 'x', label: 'One', group: 'G', factory: HelpIntent.new))
        ..register(const KeymapAction(
            id: 'x', label: 'Two', group: 'G', factory: HelpIntent.new));
      expect(reg.actions.length, 1);
      expect(reg.action('x')!.label, 'Two');
    });
  });
}
