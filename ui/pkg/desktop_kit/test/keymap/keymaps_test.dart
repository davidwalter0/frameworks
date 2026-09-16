// Tests for Keymaps.forMode and matchKeymapIntent.
//
// Strategy: we use matchKeymapIntent with a synthesised KeyDownEvent and a
// stub that fakes the HardwareKeyboard's modifier state. Because
// HardwareKeyboard is a concrete class with a private singleton constructor
// we cannot subclass it; instead we drive SingleActivator.accepts directly
// by building a minimal fake via an extension-method on the activator.
//
// The simplest cross-platform approach: instead of calling
// matchKeymapIntent (which calls HardwareKeyboard.instance), we iterate
// the map ourselves and call SingleActivator.accepts with a
// TestWidgetsFlutterBinding-initialised HardwareKeyboard that we arm with
// real key-down/up events via ServicesBinding.instance.keyboard.
//
// For the modal tests (modifier-key chords) we instead verify map membership
// by scanning the Map<ShortcutActivator, Intent> entries directly and
// checking that the activator value fields (via equality on SingleActivator
// record-like values) match what we expect. SingleActivator does not
// override ==, so we read the relevant fields by comparing the activator's
// toString() representation or by using isA checks on the found intent.
//
// Simpler still: iterate entries, check `entry.value is T`, and verify the
// activator is a SingleActivator with the matching key/modifiers by
// casting + field access (SingleActivator exposes trigger, control, alt,
// shift, meta as public getters).
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns true if [keymap] contains a [SingleActivator] with [logicalKey]
/// and the given modifier flags whose value is of type [T].
bool _has<T extends Intent>(
  Map<ShortcutActivator, Intent> keymap,
  LogicalKeyboardKey logicalKey, {
  bool ctrl = false,
  bool alt = false,
  bool shift = false,
  bool meta = false,
}) {
  for (final entry in keymap.entries) {
    if (entry.value is! T) continue;
    final sa = entry.key;
    if (sa is! SingleActivator) continue;
    if (sa.trigger != logicalKey) continue;
    if (sa.control != ctrl) continue;
    if (sa.alt != alt) continue;
    if (sa.shift != shift) continue;
    if (sa.meta != meta) continue;
    return true;
  }
  return false;
}

void main() {
  // Initialise the binding so HardwareKeyboard.instance and ServicesBinding
  // are available for the matchKeymapIntent tests.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Keymaps — Emacs mode (MetaKey.alt)', () {
    late Map<ShortcutActivator, Intent> emacs;

    setUpAll(() {
      emacs = Keymaps.forMode(KeymapMode.emacs);
    });

    test('C-a → MoveLineStartIntent', () {
      expect(
        _has<MoveLineStartIntent>(emacs, LogicalKeyboardKey.keyA, ctrl: true),
        isTrue,
      );
    });

    test('C-e → MoveLineEndIntent', () {
      expect(
        _has<MoveLineEndIntent>(emacs, LogicalKeyboardKey.keyE, ctrl: true),
        isTrue,
      );
    });

    test('C-k → KillLineIntent', () {
      expect(
        _has<KillLineIntent>(emacs, LogicalKeyboardKey.keyK, ctrl: true),
        isTrue,
      );
    });

    test('C-y → YankIntent', () {
      expect(
        _has<YankIntent>(emacs, LogicalKeyboardKey.keyY, ctrl: true),
        isTrue,
      );
    });

    test('C-SPC → SetMarkIntent', () {
      expect(
        _has<SetMarkIntent>(emacs, LogicalKeyboardKey.space, ctrl: true),
        isTrue,
      );
    });

    test('C-g → KeyboardQuitIntent', () {
      expect(
        _has<KeyboardQuitIntent>(emacs, LogicalKeyboardKey.keyG, ctrl: true),
        isTrue,
      );
    });

    test('M-f (Alt+F) → MoveForwardWordIntent', () {
      expect(
        _has<MoveForwardWordIntent>(emacs, LogicalKeyboardKey.keyF, alt: true),
        isTrue,
      );
    });

    test('C-/ → EditorUndoIntent', () {
      expect(
        _has<EditorUndoIntent>(emacs, LogicalKeyboardKey.slash, ctrl: true),
        isTrue,
      );
    });

    test('C-x → PrefixCtrlXIntent', () {
      expect(
        _has<PrefixCtrlXIntent>(emacs, LogicalKeyboardKey.keyX, ctrl: true),
        isTrue,
      );
    });

    test('F1 → HelpIntent (matchKeymapIntent, no modifier)', () {
      // F1 has no modifier so HardwareKeyboard.instance (no pressed keys) works.
      const event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.f1,
        logicalKey: LogicalKeyboardKey.f1,
        timeStamp: Duration.zero,
      );
      final result = matchKeymapIntent(
        emacs,
        event,
        HardwareKeyboard.instance,
      );
      expect(result, isA<HelpIntent>());
    });

    test('non-matching key → null (matchKeymapIntent, no modifier)', () {
      const event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyQ,
        logicalKey: LogicalKeyboardKey.keyQ,
        timeStamp: Duration.zero,
      );
      expect(
        matchKeymapIntent(emacs, event, HardwareKeyboard.instance),
        isNull,
      );
    });
  });

  group('Keymaps — Emacs mode MetaKey.superKey', () {
    late Map<ShortcutActivator, Intent> emacsSuper;

    setUpAll(() {
      emacsSuper = Keymaps.forMode(KeymapMode.emacs, metaKey: MetaKey.superKey);
    });

    test('Super+F → MoveForwardWordIntent', () {
      expect(
        _has<MoveForwardWordIntent>(emacsSuper, LogicalKeyboardKey.keyF,
            meta: true),
        isTrue,
      );
    });

    test('Alt+F does NOT appear as MoveForwardWordIntent in superKey mode', () {
      expect(
        _has<MoveForwardWordIntent>(emacsSuper, LogicalKeyboardKey.keyF,
            alt: true),
        isFalse,
      );
    });
  });

  group('Keymaps — Emacs mode MetaKey.ctrl', () {
    // M- resolves onto Control. Probe it on a chord the control layer does NOT
    // already own, so the assertion is about the meta resolution alone.
    test('M-z lands on Ctrl+Z (M- → ctrl)', () {
      final emacsCtrl = Keymaps.forMode(
        KeymapMode.emacs,
        metaKey: MetaKey.ctrl,
      );
      expect(
        _has<ZapToCharIntent>(emacsCtrl, LogicalKeyboardKey.keyZ, ctrl: true),
        isTrue,
      );
    });

    // CHANGED 2026-08-23. This group used to assert that Ctrl+F "appears as"
    // MoveForwardWordIntent under MetaKey.ctrl. It did appear — as a SECOND map
    // entry behind the control layer's MoveForwardCharIntent, which
    // matchKeymapIntent (a first-match scan) selected instead. The test was
    // pinning a dead entry, so it passed while the binding never fired. Ten M-
    // bindings collide this way; the control binding now wins all ten and the
    // loser is dropped rather than left in the map.
    test('a colliding M- binding loses to the C- binding it lands on', () {
      final emacsCtrl = Keymaps.forMode(
        KeymapMode.emacs,
        metaKey: MetaKey.ctrl,
      );
      expect(
        _has<MoveForwardCharIntent>(emacsCtrl, LogicalKeyboardKey.keyF,
            ctrl: true),
        isTrue,
      );
      expect(
        _has<MoveForwardWordIntent>(emacsCtrl, LogicalKeyboardKey.keyF,
            ctrl: true),
        isFalse,
      );
    });
  });

  group('Keymaps — Emacs mode MetaKey.esc (resolves to alt)', () {
    test('esc meta maps M-f to Alt+F', () {
      final emacsEsc = Keymaps.forMode(
        KeymapMode.emacs,
        metaKey: MetaKey.esc,
      );
      expect(
        _has<MoveForwardWordIntent>(emacsEsc, LogicalKeyboardKey.keyF,
            alt: true),
        isTrue,
      );
    });
  });

  group('Keymaps — CUA mode', () {
    late Map<ShortcutActivator, Intent> cua;

    setUpAll(() {
      cua = Keymaps.forMode(KeymapMode.cua);
    });

    test('Ctrl+S → SaveBufferIntent', () {
      expect(
        _has<SaveBufferIntent>(cua, LogicalKeyboardKey.keyS, ctrl: true),
        isTrue,
      );
    });

    test('Ctrl+O → OpenFileIntent', () {
      expect(
        _has<OpenFileIntent>(cua, LogicalKeyboardKey.keyO, ctrl: true),
        isTrue,
      );
    });

    test('F1 → HelpIntent (matchKeymapIntent)', () {
      const event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.f1,
        logicalKey: LogicalKeyboardKey.f1,
        timeStamp: Duration.zero,
      );
      expect(
        matchKeymapIntent(cua, event, HardwareKeyboard.instance),
        isA<HelpIntent>(),
      );
    });

    test('C-a is NOT in the CUA map', () {
      expect(
        _has<MoveLineStartIntent>(cua, LogicalKeyboardKey.keyA, ctrl: true),
        isFalse,
      );
    });
  });

  group('matchKeymapIntent — ignores non-KeyDownEvent', () {
    test('KeyUpEvent returns null', () {
      final emacs = Keymaps.forMode(KeymapMode.emacs);
      const upEvent = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      );
      expect(
        matchKeymapIntent(emacs, upEvent, HardwareKeyboard.instance),
        isNull,
      );
    });
  });

  group('KeymapMode labels', () {
    test('cua label', () => expect(KeymapMode.cua.label, 'CUA'));
    test('emacs label', () => expect(KeymapMode.emacs.label, 'Emacs'));
  });

  group('MetaKey.fromString', () {
    test('alt', () => expect(MetaKey.fromString('alt'), MetaKey.alt));
    test('ctrl', () => expect(MetaKey.fromString('ctrl'), MetaKey.ctrl));
    test('super', () => expect(MetaKey.fromString('super'), MetaKey.superKey));
    test('esc', () => expect(MetaKey.fromString('esc'), MetaKey.esc));
    test('unknown falls back to alt', () {
      expect(MetaKey.fromString('garbage'), MetaKey.alt);
    });
  });
}
