// Tests for KeymapConfig: defaults inversion, keymap building, JSON round-trip,
// the single-stroke / multi-stroke split, and backward compatibility with
// pre-sequence (bare-chord-token) configs.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final reg = KeymapRegistry.defaults();

  KeyChord ctrl(LogicalKeyboardKey k) =>
      KeyChord(keyId: k.keyId, control: true);
  KeyChord bare(LogicalKeyboardKey k) => KeyChord(keyId: k.keyId);

  // Length-1 sequence for a control chord (the common editor key).
  KeyChordSequence sCtrl(LogicalKeyboardKey k) =>
      KeyChordSequence.single(ctrl(k));

  group('KeymapConfig.fromDefaults', () {
    test('inverts the default emacs keymap to sequence->id', () {
      final config = KeymapConfig.fromDefaults(reg);
      final emacs = config.bindingsFor(KeymapMode.emacs);
      expect(emacs[sCtrl(LogicalKeyboardKey.keyK)], 'killLine');
      expect(emacs[sCtrl(LogicalKeyboardKey.keyA)], 'moveLineStart');
      // Help is bound to both C-h and F1 -> both sequences map to 'help'.
      expect(emacs[sCtrl(LogicalKeyboardKey.keyH)], 'help');
      expect(
        emacs[KeyChordSequence.single(bare(LogicalKeyboardKey.f1))],
        'help',
      );
    });

    test('inverts the default cua keymap', () {
      final config = KeymapConfig.fromDefaults(reg);
      final cua = config.bindingsFor(KeymapMode.cua);
      expect(cua[sCtrl(LogicalKeyboardKey.keyS)], 'save');
      expect(cua[sCtrl(LogicalKeyboardKey.keyO)], 'openFile');
    });

    test('respects the metaKey when inverting M- bindings', () {
      final alt = KeymapConfig.fromDefaults(reg, metaKey: MetaKey.alt);
      final sup = KeymapConfig.fromDefaults(reg, metaKey: MetaKey.superKey);
      // M-f = forward-word. Under alt it is Alt+F; under super it is Meta+F.
      expect(
        alt.bindingsFor(KeymapMode.emacs)[KeyChordSequence.single(
            KeyChord(keyId: LogicalKeyboardKey.keyF.keyId, alt: true))],
        'moveForwardWord',
      );
      expect(
        sup.bindingsFor(KeymapMode.emacs)[KeyChordSequence.single(
            KeyChord(keyId: LogicalKeyboardKey.keyF.keyId, meta: true))],
        'moveForwardWord',
      );
    });

    test('includes the canonical multi-stroke C-x sequences (editor-visible)',
        () {
      final config = KeymapConfig.fromDefaults(reg);
      final seqs = config.sequenceBindings(KeymapMode.emacs);
      final cx = KeyChord(keyId: LogicalKeyboardKey.keyX.keyId, control: true);
      final cxcs = KeyChordSequence(<KeyChord>[
        cx,
        KeyChord(keyId: LogicalKeyboardKey.keyS.keyId, control: true),
      ]);
      final cxb = KeyChordSequence(<KeyChord>[
        cx,
        KeyChord(keyId: LogicalKeyboardKey.keyB.keyId),
      ]);
      expect(seqs[cxcs], 'save');
      expect(seqs[cxb], 'switchBuffer');
      // CUA has no C-x prefix, so no multi-stroke defaults there.
      expect(config.sequenceBindings(KeymapMode.cua), isEmpty);
    });
  });

  group('single-stroke / multi-stroke split', () {
    test('singleStrokeBindings and sequenceBindings partition bindingsFor', () {
      final config = KeymapConfig.fromDefaults(reg);
      final all = config.bindingsFor(KeymapMode.emacs);
      final singles = config.singleStrokeBindings(KeymapMode.emacs);
      final multis = config.sequenceBindings(KeymapMode.emacs);
      expect(singles.length + multis.length, all.length);
      expect(singles.keys.every((s) => s.isSingle), isTrue);
      expect(multis.keys.every((s) => !s.isSingle), isTrue);
    });
  });

  group('KeymapConfig.toKeymap', () {
    test('builds ShortcutActivator->Intent resolving ids via the registry', () {
      final config = KeymapConfig.fromDefaults(reg);
      final map = config.toKeymap(KeymapMode.emacs, reg);
      final entry = map.entries.firstWhere(
        (e) =>
            e.key is SingleActivator &&
            (e.key as SingleActivator).trigger == LogicalKeyboardKey.keyK,
      );
      expect(entry.value, isA<KillLineIntent>());
    });

    test('excludes multi-stroke sequences (not ShortcutActivator-expressible)',
        () {
      // A config with ONLY a multi-stroke binding yields an empty keymap.
      final cxcs = KeyChordSequence(<KeyChord>[
        KeyChord(keyId: LogicalKeyboardKey.keyX.keyId, control: true),
        KeyChord(keyId: LogicalKeyboardKey.keyS.keyId, control: true),
      ]);
      final config = KeymapConfig({
        KeymapMode.emacs: {cxcs: 'save'},
      });
      expect(config.toKeymap(KeymapMode.emacs, reg), isEmpty);
      // But it IS visible via sequenceBindings.
      expect(config.sequenceBindings(KeymapMode.emacs)[cxcs], 'save');
    });

    test('drops bindings whose id is not registered', () {
      final config = KeymapConfig({
        KeymapMode.emacs: {sCtrl(LogicalKeyboardKey.keyK): 'not-a-real-id'},
      });
      expect(config.toKeymap(KeymapMode.emacs, reg), isEmpty);
    });
  });

  group('JSON round-trip', () {
    test('toJson/fromJson preserves bindings', () {
      final config = KeymapConfig.fromDefaults(reg);
      final round = KeymapConfig.fromJson(config.toJson());
      expect(round.toJson(), config.toJson());
    });

    test('encode/decode string round-trip', () {
      final config = KeymapConfig.fromDefaults(reg);
      final round = KeymapConfig.decode(config.encode());
      expect(round.toJson(), config.toJson());
    });

    test('encodeMode emits only that mode', () {
      final config = KeymapConfig.fromDefaults(reg);
      final json = config.encodeMode(KeymapMode.cua);
      expect(json, contains('cua'));
      expect(json, isNot(contains('emacs')));
    });

    test('a multi-stroke token round-trips through JSON', () {
      final cxcs = KeyChordSequence(<KeyChord>[
        KeyChord(keyId: LogicalKeyboardKey.keyX.keyId, control: true),
        KeyChord(keyId: LogicalKeyboardKey.keyS.keyId, control: true),
      ]);
      final config = KeymapConfig({
        KeymapMode.emacs: {cxcs: 'save'},
      });
      final round = KeymapConfig.decode(config.encode());
      expect(round.sequenceBindings(KeymapMode.emacs)[cxcs], 'save');
      // The token carries a space separator (multi-stroke) in the JSON.
      expect(config.encode(), contains('${cxcs.token}'));
      expect(cxcs.token.contains(' '), isTrue);
    });

    test('fromJson defensively skips unknown modes and bad tokens', () {
      final config = KeymapConfig.fromJson(<String, dynamic>{
        'emacs': {'C-${LogicalKeyboardKey.keyK.keyId}': 'killLine'},
        'bogusMode': {'C-1': 'save'},
        'cua': {'not-a-token': 'save', 42: 'x'},
      });
      expect(config.bindingsFor(KeymapMode.emacs).values, contains('killLine'));
      expect(config.bindingsFor(KeymapMode.cua), isEmpty);
    });
  });

  group('backward compatibility with pre-sequence configs', () {
    // A verbatim JSON string exactly as a pre-sequence build would have written
    // it: bare single-chord tokens (no spaces) as object keys. This is frozen —
    // do not "modernise" the tokens; the whole point is that OLD data loads.
    String preSequenceJson() {
      final cS = KeyChord(keyId: LogicalKeyboardKey.keyS.keyId, control: true)
          .token; // e.g. "C-115"
      final cK =
          KeyChord(keyId: LogicalKeyboardKey.keyK.keyId, control: true).token;
      final f1 = KeyChord(keyId: LogicalKeyboardKey.f1.keyId).token; // "-<id>"
      return '{"cua":{"$cS":"save"},'
          '"emacs":{"$cK":"killLine","$f1":"help"}}';
    }

    test('decodes a frozen pre-change JSON fixture verbatim', () {
      final config = KeymapConfig.decode(preSequenceJson());

      // Every bare token became a length-1 sequence, mapped to the same id.
      final cua = config.bindingsFor(KeymapMode.cua);
      expect(cua, hasLength(1));
      expect(
        cua[KeyChordSequence.single(
            KeyChord(keyId: LogicalKeyboardKey.keyS.keyId, control: true))],
        'save',
      );

      final emacs = config.bindingsFor(KeymapMode.emacs);
      expect(emacs, hasLength(2));
      expect(
        emacs[KeyChordSequence.single(
            KeyChord(keyId: LogicalKeyboardKey.keyK.keyId, control: true))],
        'killLine',
      );
      expect(
        emacs[KeyChordSequence.single(
            KeyChord(keyId: LogicalKeyboardKey.f1.keyId))],
        'help',
      );

      // Every loaded key is single-stroke (old data has no multi-stroke keys).
      expect(
        config.bindingsFor(KeymapMode.emacs).keys.every((s) => s.isSingle),
        isTrue,
      );
    });

    test('re-encoding old data is byte-stable (same JSON back out)', () {
      final src = preSequenceJson();
      final reencoded = KeymapConfig.decode(src).encode();
      // jsonEncode over a Map emits keys in insertion order, and decode
      // preserves the source order, so a single-stroke (bare-token) config
      // re-encodes to the exact same bytes. This is the strongest statement of
      // the backward-compat guarantee.
      expect(reencoded, src);
    });

    test('old single-stroke tokens still drive the ShortcutActivator map', () {
      final config = KeymapConfig.decode(preSequenceJson());
      final map = config.toKeymap(KeymapMode.emacs, reg);
      final killLine = map.entries.firstWhere(
        (e) =>
            e.key is SingleActivator &&
            (e.key as SingleActivator).trigger == LogicalKeyboardKey.keyK,
      );
      expect(killLine.value, isA<KillLineIntent>());
    });
  });

  group('mutation + empties', () {
    test('withMode replaces one mode, leaves the other', () {
      final config = KeymapConfig.fromDefaults(reg);
      final next = config.withMode(KeymapMode.cua, {});
      expect(next.bindingsFor(KeymapMode.cua), isEmpty);
      expect(next.bindingsFor(KeymapMode.emacs), isNotEmpty);
    });

    test('empty config isEmpty; defaults are not', () {
      expect(KeymapConfig.empty.isEmpty, isTrue);
      expect(KeymapConfig.fromDefaults(reg).isEmpty, isFalse);
    });
  });
}
