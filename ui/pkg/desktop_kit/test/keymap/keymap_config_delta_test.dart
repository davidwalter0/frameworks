// Delta persistence: persist only what differs from the shipped defaults,
// load as defaults ⊕ delta.
//
// The defect this replaces: a host writes the WHOLE config on the first rebind
// (`persist(next.toJson())`), so the file jumps straight from nothing to a
// frozen copy of every binding — it never passes through "a delta" — and load
// decodes it wholesale. One rebind and that user owns a private fork of the
// shipped defaults forever, immune to every later correction.
//
// The snapshot fixtures are VERBATIM excerpts of two real configs found on the
// author's machine (2026-08-23), because the whole judgement rests on telling
// them apart:
//
//   word-bank  ~/.local/share/com.davidwalter0.word_bank_ui/
//               word-bank-ui/settings.json  → keymapConfig
//               emacs "C-115": "save"   — a frozen copy of the RETIRED default
//               cua   "C-115": "save"   — still a CUA default
//   textloom       ~/.config/textloom/keymap.json  → keymap
//               emacs "C-115": "swiper" — a DELIBERATE rebind
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Excerpt of the real word-bank settings.json `keymapConfig` block. No
/// schemaVersion — that is what makes it snapshot-era.
const String _wordBankSnapshot = '''
{
  "cua": {
    "C-115": "save",
    "C-111": "openFile"
  },
  "emacs": {
    "C-97": "moveLineStart",
    "C-115": "save",
    "C-120": "prefixCtrlX",
    "C-120 C-115": "save",
    "C-120 C-102": "openFile",
    "C-92": "toggleRomajiKana"
  }
}
''';

/// Excerpt of the real textloom keymap.json `keymap` block. Also snapshot-era.
const String _textloomSnapshot = '''
{
  "emacs": {
    "C-97": "moveLineStart",
    "C-114": "isearchBackward",
    "C-115": "swiper",
    "C-120 C-115": "save"
  }
}
''';

KeyChordSequence _seq(LogicalKeyboardKey k, {bool control = true}) =>
    KeyChordSequence.single(KeyChord(keyId: k.keyId, control: control));

/// The intent bound to ctrl+[key] in a live keymap, or null.
Intent? _ctrl(Map<ShortcutActivator, Intent> map, LogicalKeyboardKey key) {
  for (final e in map.entries) {
    final a = e.key;
    if (a is SingleActivator &&
        a.trigger == key &&
        a.control &&
        !a.shift &&
        !a.alt &&
        !a.meta) {
      return e.value;
    }
  }
  return null;
}

void main() {
  final reg = KeymapRegistry.defaults();
  final shipped = KeymapConfig.fromDefaults(reg);

  group('delta — only genuine differences are persisted', () {
    test('an untouched config produces an EMPTY delta', () {
      final d = shipped.delta(against: shipped);
      expect(d.isEmpty, isTrue);
      expect(d.schemaVersion, KeymapConfig.currentSchemaVersion);
    });

    test('one rebind produces a ONE-entry delta, not a snapshot', () {
      // This is the whole point: the first edit used to write the entire map.
      final edited = shipped.withMode(
        KeymapMode.emacs,
        Map<KeyChordSequence, String>.from(
            shipped.bindingsFor(KeymapMode.emacs))
          ..[_seq(LogicalKeyboardKey.keyS)] = 'swiper',
      );
      final d = edited.delta(against: shipped);
      expect(d.bindingsFor(KeymapMode.emacs), hasLength(1));
      expect(d.bindingsFor(KeymapMode.emacs)[_seq(LogicalKeyboardKey.keyS)],
          'swiper');
      expect(d.bindingsFor(KeymapMode.cua), isEmpty);
    });

    test('a binding the defaults do not have is a delta', () {
      final edited = shipped.withMode(
        KeymapMode.emacs,
        Map<KeyChordSequence, String>.from(
            shipped.bindingsFor(KeymapMode.emacs))
          ..[_seq(LogicalKeyboardKey.keyQ)] = 'occur',
      );
      final d = edited.delta(against: shipped);
      expect(d.bindingsFor(KeymapMode.emacs)[_seq(LogicalKeyboardKey.keyQ)],
          'occur');
    });

    test('a REMOVED default becomes a tombstone', () {
      // The editor's ✕ (_removeSequence) deletes the entry outright. Without a
      // tombstone the next merge would put it straight back.
      final edited = shipped.withMode(
        KeymapMode.emacs,
        Map<KeyChordSequence, String>.from(
            shipped.bindingsFor(KeymapMode.emacs))
          ..remove(_seq(LogicalKeyboardKey.keyK)),
      );
      final d = edited.delta(against: shipped);
      expect(d.bindingsFor(KeymapMode.emacs)[_seq(LogicalKeyboardKey.keyK)],
          KeymapConfig.unboundId);
    });

    test('a mode absent entirely is NOT tombstoned wholesale', () {
      // "this file does not configure CUA" is not "the user unbound every CUA
      // key" — the difference between an empty delta and a demolished mode.
      final emacsOnly =
          KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{
        KeymapMode.emacs: shipped.bindingsFor(KeymapMode.emacs),
      });
      final d = emacsOnly.delta(against: shipped);
      expect(d.bindingsFor(KeymapMode.cua), isEmpty);
      expect(d.mergedOnto(shipped).bindingsFor(KeymapMode.cua),
          shipped.bindingsFor(KeymapMode.cua));
    });
  });

  group('merge — defaults ⊕ delta', () {
    test('round-trips: merge(delta(x)) == x', () {
      final edited = shipped.withMode(
        KeymapMode.emacs,
        Map<KeyChordSequence, String>.from(
            shipped.bindingsFor(KeymapMode.emacs))
          ..[_seq(LogicalKeyboardKey.keyS)] = 'swiper'
          ..remove(_seq(LogicalKeyboardKey.keyK)),
      );
      final back = edited.delta(against: shipped).mergedOnto(shipped);
      expect(back.bindingsFor(KeymapMode.emacs),
          edited.bindingsFor(KeymapMode.emacs));
      expect(
          back.bindingsFor(KeymapMode.cua), edited.bindingsFor(KeymapMode.cua));
    });

    test('a tombstone deletes, and the merged config carries none', () {
      final d = KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{
        KeymapMode.emacs: <KeyChordSequence, String>{
          _seq(LogicalKeyboardKey.keyK): KeymapConfig.unboundId,
        },
      }, schemaVersion: KeymapConfig.currentSchemaVersion);
      final merged = d.mergedOnto(shipped);
      expect(merged.bindingsFor(KeymapMode.emacs),
          isNot(contains(_seq(LogicalKeyboardKey.keyK))));
      expect(merged.bindingsFor(KeymapMode.emacs).values,
          isNot(contains(KeymapConfig.unboundId)));
    });

    test('a CORRECTED shipped default reaches a user who never touched it', () {
      // The property the whole design exists for. Simulate the kit changing a
      // default: the user's stored delta says nothing about that chord, so the
      // new default simply arrives.
      final stored = KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{
        KeymapMode.emacs: <KeyChordSequence, String>{
          _seq(LogicalKeyboardKey.keyQ): 'occur',
        },
      }, schemaVersion: KeymapConfig.currentSchemaVersion);
      final nextShipped = shipped.withMode(
        KeymapMode.emacs,
        Map<KeyChordSequence, String>.from(
            shipped.bindingsFor(KeymapMode.emacs))
          ..[_seq(LogicalKeyboardKey.keyL)] = 'gotoLine',
      );
      final effective = stored.mergedOnto(nextShipped);
      expect(
          effective
              .bindingsFor(KeymapMode.emacs)[_seq(LogicalKeyboardKey.keyL)],
          'gotoLine');
      expect(
          effective
              .bindingsFor(KeymapMode.emacs)[_seq(LogicalKeyboardKey.keyQ)],
          'occur');
    });

    test('Keymaps.forMode honours a tombstone in a raw delta', () {
      // Defence in depth: a host that skips mergedOnto and passes the delta
      // straight to forMode still gets the removal.
      final d = KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{
        KeymapMode.emacs: <KeyChordSequence, String>{
          _seq(LogicalKeyboardKey.keyK): KeymapConfig.unboundId,
        },
      }, schemaVersion: KeymapConfig.currentSchemaVersion);
      final map =
          Keymaps.forMode(KeymapMode.emacs, overrides: d, registry: reg);
      expect(_ctrl(map, LogicalKeyboardKey.keyK), isNull);
      // and nothing else was disturbed
      expect(_ctrl(map, LogicalKeyboardKey.keyA), isA<MoveLineStartIntent>());
    });
  });

  group('schema marker', () {
    test('absent on a snapshot-era file; re-encode stays byte-identical', () {
      final c = KeymapConfig.decode(_textloomSnapshot);
      expect(c.schemaVersion, isNull);
      expect(c.isDelta, isFalse);
      expect(c.encode(), isNot(contains('schemaVersion')));
    });

    test('present on a delta, and survives a JSON round-trip', () {
      final d = shipped.delta(against: shipped);
      final back = KeymapConfig.decode(d.encode());
      expect(back.schemaVersion, KeymapConfig.currentSchemaVersion);
      expect(back.isDelta, isTrue);
    });

    test('encodeMode stamps it too (the per-mode Save path)', () {
      final d = KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{
        KeymapMode.emacs: <KeyChordSequence, String>{
          _seq(LogicalKeyboardKey.keyQ): 'occur',
        },
      }, schemaVersion: KeymapConfig.currentSchemaVersion);
      final back = KeymapConfig.decode(d.encodeMode(KeymapMode.emacs));
      expect(back.isDelta, isTrue);
    });

    test('an unknown top-level key is still ignored by fromJson', () {
      final c = KeymapConfig.decode('{"schemaVersion":2,"emacs":{"C-97":"x"}}');
      expect(c.modes.keys, <KeymapMode>[KeymapMode.emacs]);
    });
  });

  group('upgraded — the bounded snapshot-era transition', () {
    test('word-bank: the frozen C-s → save is gone, defaults win', () {
      final up =
          KeymapConfig.decode(_wordBankSnapshot).upgraded(defaults: shipped);
      expect(up.changed, isTrue);
      expect(up.dropped, hasLength(1));
      expect(up.dropped.single.intentId, 'save');
      expect(up.dropped.single.mode, KeymapMode.emacs);

      final effective = up.config.mergedOnto(shipped);
      final map = Keymaps.forMode(
        KeymapMode.emacs,
        overrides: effective,
        registry: reg,
      );
      expect(_ctrl(map, LogicalKeyboardKey.keyS), isA<IsearchForwardIntent>());
    });

    test('textloom: the deliberate C-s → swiper survives and still wins', () {
      final up =
          KeymapConfig.decode(_textloomSnapshot).upgraded(defaults: shipped);
      expect(up.dropped, isEmpty);
      expect(
          up.config
              .bindingsFor(KeymapMode.emacs)[_seq(LogicalKeyboardKey.keyS)],
          'swiper');

      final map = Keymaps.forMode(
        KeymapMode.emacs,
        overrides: up.config.mergedOnto(shipped),
        registry: reg,
      );
      expect(_ctrl(map, LogicalKeyboardKey.keyS), isA<SwiperIntent>());
    });

    test('the upgrade emits NO tombstones — an old snapshot lacks new keys',
        () {
      // The word-bank snapshot predates most of the current defaults. Reading
      // that absence as "the user unbound it" would strip most of the keymap;
      // the transition errs toward the shipped defaults instead.
      final up =
          KeymapConfig.decode(_wordBankSnapshot).upgraded(defaults: shipped);
      expect(
        up.config.modes.values.expand((m) => m.values),
        isNot(contains(KeymapConfig.unboundId)),
      );
      // C-k was absent from that snapshot and comes back from the defaults.
      final effective = up.config.mergedOnto(shipped);
      expect(
          effective
              .bindingsFor(KeymapMode.emacs)[_seq(LogicalKeyboardKey.keyK)],
          'killLine');
    });

    test('what survives is only what genuinely differs', () {
      final up =
          KeymapConfig.decode(_wordBankSnapshot).upgraded(defaults: shipped);
      // toggleRomajiKana is a host intent the kit does not ship — a real delta.
      expect(up.config.bindingsFor(KeymapMode.emacs).values,
          contains('toggleRomajiKana'));
      // moveLineStart / prefixCtrlX / C-x C-s restate live defaults: dropped.
      expect(up.config.bindingsFor(KeymapMode.emacs).values,
          isNot(contains('moveLineStart')));
      expect(up.config.bindingsFor(KeymapMode.emacs).values,
          isNot(contains('prefixCtrlX')));
      // CUA C-s → save still equals the CUA default, so it is not a delta.
      expect(up.config.bindingsFor(KeymapMode.cua), isEmpty);
    });

    test('it stamps the marker, and is a no-op the second time', () {
      final once =
          KeymapConfig.decode(_wordBankSnapshot).upgraded(defaults: shipped);
      expect(once.config.isDelta, isTrue);
      final twice = once.config.upgraded(defaults: shipped);
      expect(twice.changed, isFalse);
      expect(twice.dropped, isEmpty);
      expect(identical(twice.config, once.config), isTrue);
    });

    test('a schema-2 delta never reaches the retirement sweep', () {
      // The bound on the transition: a stored delta legitimately containing
      // emacs C-s → save must NOT be stripped.
      final d = KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{
        KeymapMode.emacs: <KeyChordSequence, String>{
          _seq(LogicalKeyboardKey.keyS): 'save',
        },
      }, schemaVersion: KeymapConfig.currentSchemaVersion);
      final up = d.upgraded(defaults: shipped);
      expect(up.changed, isFalse);
      expect(
          up.config
              .bindingsFor(KeymapMode.emacs)[_seq(LogicalKeyboardKey.keyS)],
          'save');
    });

    test('the retirement list is closed, minimal, and documented', () {
      expect(kSnapshotEraRetirements, hasLength(1));
      for (final r in kSnapshotEraRetirements) {
        expect(r.reason, isNotEmpty);
        expect(r.retiredIn, isNotEmpty);
      }
    });
  });
}
