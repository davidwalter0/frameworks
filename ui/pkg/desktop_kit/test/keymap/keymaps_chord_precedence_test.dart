// Chord PRECEDENCE and Emacs-fidelity of the default keymaps.
//
// Two independent defects are pinned here.
//
// 1. `Keymaps.forMode` promised "last-writer-wins on any chord collision" and
//    did not deliver it. The map is keyed on [ShortcutActivator], and
//    [SingleActivator] declares no `operator ==` / `hashCode`, so a user
//    override and a kit default for the SAME physical chord survived as two
//    separate entries. [matchKeymapIntent] is a first-match linear scan, so the
//    DEFAULT won and the override was dead — "rebinding C-s does nothing".
//
// 2. The Emacs default map bound a standalone `C-s` to Save buffer, a CUA
//    convention. GNU Emacs binds `C-s` to isearch-forward and saves on
//    `C-x C-s` only.
//
// Every test here fails against the pre-fix keymaps.dart.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every entry in [keymap] whose activator denotes the ctrl+[key] chord.
List<Intent> _ctrlEntries(
  Map<ShortcutActivator, Intent> keymap,
  LogicalKeyboardKey key,
) =>
    <Intent>[
      for (final e in keymap.entries)
        if (e.key case final SingleActivator a)
          if (a.trigger == key && a.control && !a.shift && !a.alt && !a.meta)
            e.value,
    ];

KeyChordSequence _single(LogicalKeyboardKey k, {bool control = true}) =>
    KeyChordSequence.single(KeyChord(keyId: k.keyId, control: control));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final reg = KeymapRegistry.defaults();

  group('a user override displaces the default on the same chord', () {
    // The reported symptom, reduced to a pairing that does not depend on which
    // intent the defaults happen to put on C-s: rebind `yank` onto C-k, a chord
    // the defaults already own (kill-line). The id-based filter drops the
    // default C-y, but the default C-k → KillLine survives it — so the override
    // and the default collide on ONE physical chord, which is precisely the
    // case the map could not represent.
    late Map<ShortcutActivator, Intent> map;

    setUpAll(() {
      map = Keymaps.forMode(
        KeymapMode.emacs,
        overrides: KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{
          KeymapMode.emacs: <KeyChordSequence, String>{
            _single(LogicalKeyboardKey.keyK): 'yank',
          },
        }),
        registry: reg,
      );
    });

    test('exactly ONE entry survives for the contested chord', () {
      // Pre-fix: 2 — the dead override sat behind the live default.
      expect(_ctrlEntries(map, LogicalKeyboardKey.keyK), hasLength(1));
    });

    test('the survivor is the OVERRIDE, not the default', () {
      expect(
          _ctrlEntries(map, LogicalKeyboardKey.keyK).single, isA<YankIntent>());
    });

    test('matchKeymapIntent selects the override end-to-end', () async {
      await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
      addTearDown(() => simulateKeyUpEvent(LogicalKeyboardKey.controlLeft));
      const event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyK,
        logicalKey: LogicalKeyboardKey.keyK,
        timeStamp: Duration.zero,
      );
      expect(
        matchKeymapIntent(map, event, HardwareKeyboard.instance),
        isA<YankIntent>(),
      );
    });

    test('the rebound intent loses its own default chord', () {
      expect(_ctrlEntries(map, LogicalKeyboardKey.keyY), isEmpty);
    });

    test('an untouched default is unaffected', () {
      expect(_ctrlEntries(map, LogicalKeyboardKey.keyA).single,
          isA<MoveLineStartIntent>());
    });
  });

  group('the default maps are collision-free', () {
    // The precondition that makes "last-writer-wins" meaningful at all: if the
    // DEFAULTS collide with each other, some default is already dead code.
    for (final mode in KeymapMode.values) {
      for (final metaKey in MetaKey.values) {
        test('${mode.name} / ${metaKey.name}: one entry per chord', () {
          final map = Keymaps.forMode(mode, metaKey: metaKey);
          final chords = <KeyChord>{};
          for (final a in map.keys) {
            if (a is! SingleActivator) continue;
            expect(chords.add(KeyChord.fromActivator(a)), isTrue,
                reason: 'duplicate chord ${KeyChord.fromActivator(a).label}');
          }
        });
      }
    }

    test('MetaKey.ctrl: the CONTROL binding wins every collision', () {
      // Ten M- bindings land on chords a C- binding owns once M- resolves to
      // Control. GNU Emacs defines the C- meaning on those physical chords, so
      // the control layer is emitted first and wins. C-SPC and C-u were the two
      // that previously went the other way, by accident of source order.
      final map = Keymaps.forMode(KeymapMode.emacs, metaKey: MetaKey.ctrl);
      final expected = <LogicalKeyboardKey, Matcher>{
        LogicalKeyboardKey.keyF: isA<MoveForwardCharIntent>(),
        LogicalKeyboardKey.keyB: isA<MoveBackwardCharIntent>(),
        LogicalKeyboardKey.keyW: isA<KillRegionIntent>(),
        LogicalKeyboardKey.keyD: isA<DeleteCharIntent>(),
        LogicalKeyboardKey.keyY: isA<YankIntent>(),
        LogicalKeyboardKey.keyT: isA<TransposeCharsIntent>(),
        LogicalKeyboardKey.space: isA<SetMarkIntent>(),
        LogicalKeyboardKey.keyL: isA<RecenterIntent>(),
        LogicalKeyboardKey.keyU: isA<UniversalArgumentIntent>(),
        LogicalKeyboardKey.keyV: isA<ScrollUpIntent>(),
      };
      expected.forEach((key, matcher) {
        expect(_ctrlEntries(map, key).single, matcher,
            reason: 'C-${key.keyLabel} must keep its control-layer binding');
      });
    });
  });

  group('Emacs defaults match GNU Emacs', () {
    late Map<ShortcutActivator, Intent> emacs;
    setUpAll(() => emacs = Keymaps.forMode(KeymapMode.emacs));

    test('C-s is isearch-forward', () {
      expect(_ctrlEntries(emacs, LogicalKeyboardKey.keyS).single,
          isA<IsearchForwardIntent>());
    });

    test('C-r is isearch-backward', () {
      expect(_ctrlEntries(emacs, LogicalKeyboardKey.keyR).single,
          isA<IsearchBackwardIntent>());
    });

    test('no standalone chord saves the buffer', () {
      expect(emacs.values.whereType<SaveBufferIntent>(), isEmpty);
    });

    test('CUA keeps its standalone Ctrl+S save', () {
      final cua = Keymaps.forMode(KeymapMode.cua);
      expect(_ctrlEntries(cua, LogicalKeyboardKey.keyS).single,
          isA<SaveBufferIntent>());
    });
  });

  group('C-x sequences', () {
    /// Feed [strokes] to a matcher built from the kit defaults and resolve.
    Intent? run(List<KeyChord> strokes) {
      final m = SequenceMatcher(Keymaps.defaultSequenceBindings(
        KeymapMode.emacs,
      ));
      SequenceMatchResult? last;
      for (final s in strokes) {
        last = m.feed(s);
      }
      if (last is! SequenceMatchMatched) return null;
      return resolveIntent(last.intentId, reg);
    }

    KeyChord c(LogicalKeyboardKey k) => KeyChord(keyId: k.keyId, control: true);
    KeyChord bare(LogicalKeyboardKey k) => KeyChord(keyId: k.keyId);
    final cx = c(LogicalKeyboardKey.keyX);

    test('C-x C-s still saves', () {
      expect(run(<KeyChord>[cx, c(LogicalKeyboardKey.keyS)]),
          isA<SaveBufferIntent>());
    });

    test('C-x C-f still opens a file', () {
      expect(run(<KeyChord>[cx, c(LogicalKeyboardKey.keyF)]),
          isA<OpenFileIntent>());
    });

    test('C-x C-c is save-buffers-kill-terminal', () {
      expect(run(<KeyChord>[cx, c(LogicalKeyboardKey.keyC)]),
          isA<SaveBuffersKillTerminalIntent>());
    });

    test('C-x C-x exchanges point and mark (PrefixDispatcher parity)', () {
      expect(run(<KeyChord>[cx, c(LogicalKeyboardKey.keyX)]),
          isA<ExchangePointAndMarkIntent>());
    });

    test('C-x h marks the whole buffer (PrefixDispatcher parity)', () {
      expect(run(<KeyChord>[cx, bare(LogicalKeyboardKey.keyH)]),
          isA<MarkWholeBufferIntent>());
    });

    test('C-x C-p marks the page (PrefixDispatcher parity)', () {
      expect(run(<KeyChord>[cx, c(LogicalKeyboardKey.keyP)]),
          isA<MarkPageIntent>());
    });

    test('C-x C-w writes the file (save as)', () {
      expect(run(<KeyChord>[cx, c(LogicalKeyboardKey.keyW)]),
          isA<WriteFileIntent>());
    });

    test('C-x C-b lists buffers, C-x b switches', () {
      expect(run(<KeyChord>[cx, c(LogicalKeyboardKey.keyB)]),
          isA<ListBuffersIntent>());
      expect(run(<KeyChord>[cx, bare(LogicalKeyboardKey.keyB)]),
          isA<SwitchBufferIntent>());
    });

    test('every default sequence resolves through the default registry', () {
      Keymaps.defaultSequenceBindings(KeymapMode.emacs).forEach((seq, id) {
        expect(reg.contains(id), isTrue, reason: '$id (${seq.label}) unknown');
      });
    });

    test('fromDefaults carries the new sequences into the editor config', () {
      final cfg = KeymapConfig.fromDefaults(reg);
      expect(
        cfg.sequenceBindings(KeymapMode.emacs).values,
        containsAll(<String>[
          'saveBuffersKillTerminal',
          'exchangePointAndMark',
          'markWholeBuffer',
          'markPage',
          'writeFile',
          'listBuffers',
        ]),
      );
    });
  });

  group('saveBuffersKillTerminal registry round-trip', () {
    test('id resolves to the intent', () {
      expect(reg.intentFor('saveBuffersKillTerminal'),
          isA<SaveBuffersKillTerminalIntent>());
    });

    test('the intent resolves back to the id', () {
      expect(reg.idFor(const SaveBuffersKillTerminalIntent()),
          'saveBuffersKillTerminal');
    });
  });
}
