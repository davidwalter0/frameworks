// Widget tests for KeymapEditor: rendering, chord capture (single + multi-
// stroke), conflict reassign, chip removal, reset, per-mode save, and the
// shadowing-conflict warning. Tests operate on the default (CUA) tab unless a
// test needs the Emacs tab (where the C-x sequences live); every registered
// action appears in every mode tab.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Controlled harness: holds the config and feeds it back on change, mirroring
/// how a host embeds the editor.
class _Harness extends StatefulWidget {
  const _Harness({required this.initial, this.onSave, this.theme});
  final KeymapConfig initial;
  final void Function(KeymapMode, String)? onSave;
  final ThemeData? theme;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late KeymapConfig config = widget.initial;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: widget.theme,
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: KeymapEditor(
            value: config,
            onChanged: (next) => setState(() => config = next),
            onSave: widget.onSave,
          ),
        ),
      ),
    );
  }
}

KeyChord _ctrl(LogicalKeyboardKey k) => KeyChord(keyId: k.keyId, control: true);

/// Length-1 sequence for a control chord (the common binding).
KeyChordSequence _seq(LogicalKeyboardKey k) =>
    KeyChordSequence.single(_ctrl(k));

Future<void> _pressChord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool ctrl = false,
}) async {
  if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  final reg = KeymapRegistry.defaults();

  testWidgets('renders both mode tabs and the default cua chips',
      (tester) async {
    await tester.pumpWidget(_Harness(initial: KeymapConfig.fromDefaults(reg)));
    await tester.pumpAndSettle();

    expect(find.text('CUA bindings'), findsOneWidget);
    expect(find.text('Emacs bindings'), findsOneWidget);
    // Save buffer is bound to Ctrl+S in cua -> a chip shows it.
    expect(find.text('Save buffer'), findsWidgets);
    expect(find.text('Ctrl+S'), findsWidgets);
  });

  testWidgets(
      'survives an ambient TabAlignment.start theme (fixed TabBar must '
      'not crash on a consumer app-wide start alignment)', (tester) async {
    // Regression for the voicelab crash: a consumer sets
    // TabBarThemeData(tabAlignment: TabAlignment.start) app-wide (valid for its
    // scrollable buffer tabs), which leaks onto the editor's FIXED TabBar —
    // "TabAlignment.start is only valid for scrollable tab bars". The editor
    // must pin its own non-scrollable alignment.
    await tester.pumpWidget(
      _Harness(
        initial: KeymapConfig.fromDefaults(reg),
        theme: ThemeData(
          tabBarTheme: const TabBarThemeData(
            tabAlignment: TabAlignment.start,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('CUA bindings'), findsOneWidget);
  });

  testWidgets('capture adds a new binding for an action', (tester) async {
    await tester.pumpWidget(_Harness(initial: KeymapConfig.fromDefaults(reg)));
    await tester.pumpAndSettle();

    // Add a binding for Help (bound to F1 by default in cua).
    final add = find.byKey(const Key('keymap-add-help'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('Press a key combination'), findsOneWidget);

    await _pressChord(tester, LogicalKeyboardKey.keyH, ctrl: true);
    // Preview shows the pending sequence with the armed trailing cue.
    expect(find.text('Ctrl+H –'), findsOneWidget);
    await tester.tap(find.byKey(const Key('keymap-capture-set')));
    await tester.pumpAndSettle();

    final state = tester.state<_HarnessState>(find.byType(_Harness));
    expect(
      state.config.bindingsFor(KeymapMode.cua)[_seq(LogicalKeyboardKey.keyH)],
      'help',
    );
  });

  testWidgets('multi-stroke capture stores the full sequence', (tester) async {
    await tester.pumpWidget(_Harness(initial: KeymapConfig.fromDefaults(reg)));
    await tester.pumpAndSettle();

    // Bind a two-stroke C-x C-s to "Open file" (arbitrary target action).
    final add = find.byKey(const Key('keymap-add-openFile'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();

    // Stroke 1: C-x.
    await _pressChord(tester, LogicalKeyboardKey.keyX, ctrl: true);
    expect(find.text('Ctrl+X –'), findsOneWidget);
    // Stroke 2: C-s. Now the preview shows both strokes.
    await _pressChord(tester, LogicalKeyboardKey.keyS, ctrl: true);
    expect(find.text('Ctrl+X Ctrl+S –'), findsOneWidget);

    // Commit with Enter.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final expected = KeyChordSequence(<KeyChord>[
      _ctrl(LogicalKeyboardKey.keyX),
      _ctrl(LogicalKeyboardKey.keyS),
    ]);
    final state = tester.state<_HarnessState>(find.byType(_Harness));
    expect(state.config.bindingsFor(KeymapMode.cua)[expected], 'openFile');
  });

  testWidgets('Backspace removes the last stroke while capturing',
      (tester) async {
    await tester.pumpWidget(_Harness(initial: KeymapConfig.fromDefaults(reg)));
    await tester.pumpAndSettle();

    final add = find.byKey(const Key('keymap-add-openFile'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();

    await _pressChord(tester, LogicalKeyboardKey.keyX, ctrl: true);
    await _pressChord(tester, LogicalKeyboardKey.keyS, ctrl: true);
    expect(find.text('Ctrl+X Ctrl+S –'), findsOneWidget);

    // Backspace drops C-s, leaving C-x.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.text('Ctrl+X –'), findsOneWidget);

    // Backspace again empties the pending -> back to the waiting prompt, Set
    // disabled.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.text('Waiting for input…'), findsOneWidget);
    final setBtn = tester.widget<FilledButton>(
      find.byKey(const Key('keymap-capture-set')),
    );
    expect(setBtn.onPressed, isNull);
  });

  testWidgets('bare modifier presses do not start a stroke', (tester) async {
    await tester.pumpWidget(_Harness(initial: KeymapConfig.fromDefaults(reg)));
    await tester.pumpAndSettle();

    final add = find.byKey(const Key('keymap-add-openFile'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();

    // Press and release Ctrl alone: nothing captured.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('Waiting for input…'), findsOneWidget);
  });

  testWidgets('capturing an already-bound chord prompts to reassign',
      (tester) async {
    await tester.pumpWidget(_Harness(initial: KeymapConfig.fromDefaults(reg)));
    await tester.pumpAndSettle();

    // Add a binding for Help, press Ctrl+S (already bound to Save buffer).
    final add = find.byKey(const Key('keymap-add-help'));
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    await _pressChord(tester, LogicalKeyboardKey.keyS, ctrl: true);
    await tester.tap(find.byKey(const Key('keymap-capture-set')));
    await tester.pumpAndSettle();

    // Conflict dialog appears.
    expect(find.text('Chord already bound'), findsOneWidget);
    await tester.tap(find.text('Reassign'));
    await tester.pumpAndSettle();

    final cua = tester
        .state<_HarnessState>(find.byType(_Harness))
        .config
        .bindingsFor(KeymapMode.cua);
    // Ctrl+S now drives Help; Save buffer lost that chord.
    expect(cua[_seq(LogicalKeyboardKey.keyS)], 'help');
    expect(cua.values.where((v) => v == 'save'), isEmpty);
  });

  testWidgets('deleting a chip unbinds it', (tester) async {
    await tester.pumpWidget(_Harness(initial: KeymapConfig.fromDefaults(reg)));
    await tester.pumpAndSettle();

    final token = _seq(LogicalKeyboardKey.keyS).token;
    final chip = find.byKey(Key('keymap-chip-save-$token'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    expect(chip, findsOneWidget);
    // The InputChip's delete button carries a 'Delete' tooltip (its glyph is a
    // Material default that varies by icon set, so match the tooltip instead).
    await tester.tap(find.descendant(
      of: chip,
      matching: find.byTooltip('Delete'),
    ));
    await tester.pumpAndSettle();

    final cua = tester
        .state<_HarnessState>(find.byType(_Harness))
        .config
        .bindingsFor(KeymapMode.cua);
    expect(cua.containsKey(_seq(LogicalKeyboardKey.keyS)), isFalse);
  });

  testWidgets('reset restores defaults after an edit', (tester) async {
    // Start from a config that has cua Ctrl+S removed.
    final edited = KeymapConfig.fromDefaults(reg).withMode(
      KeymapMode.cua,
      {}, // no cua bindings
    );
    await tester.pumpWidget(_Harness(initial: edited));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('keymap-reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset')); // confirm
    await tester.pumpAndSettle();

    final cua = tester
        .state<_HarnessState>(find.byType(_Harness))
        .config
        .bindingsFor(KeymapMode.cua);
    expect(cua[_seq(LogicalKeyboardKey.keyS)], 'save');
  });

  testWidgets('emacs tab shows the default multi-stroke C-x sequences',
      (tester) async {
    await tester.pumpWidget(_Harness(initial: KeymapConfig.fromDefaults(reg)));
    await tester.pumpAndSettle();

    // Switch to the Emacs tab.
    await tester.tap(find.text('Emacs bindings'));
    await tester.pumpAndSettle();

    // The C-x C-s sequence chip is present, labelled Emacs-style, with the
    // multi-stroke annotation (runtime dispatch via SequenceMatcher in step 3).
    expect(find.text('Ctrl+X Ctrl+S'), findsWidgets);
    expect(find.text('(multi-stroke)'), findsWidgets);
  });

  testWidgets('shadow conflict flags both rows with a warning', (tester) async {
    // Build an emacs config that binds BOTH C-x (prefix, on the C-x-prefix
    // action) and C-x C-s (on save): C-x properly-prefixes C-x C-s -> shadow.
    final cx = _ctrl(LogicalKeyboardKey.keyX);
    final cxSeq = KeyChordSequence.single(cx);
    final cxcsSeq = KeyChordSequence(<KeyChord>[
      cx,
      _ctrl(LogicalKeyboardKey.keyS),
    ]);
    final config = KeymapConfig({
      KeymapMode.emacs: {
        cxSeq: 'prefixCtrlX',
        cxcsSeq: 'save',
      },
    });
    await tester.pumpWidget(_Harness(initial: config));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emacs bindings'));
    await tester.pumpAndSettle();

    // Both the prefix chip and the shadowed chip should carry a warning icon.
    final cxChip = find.byKey(Key('keymap-chip-prefixCtrlX-${cxSeq.token}'));
    final cxcsChip = find.byKey(Key('keymap-chip-save-${cxcsSeq.token}'));
    expect(cxChip, findsOneWidget);
    expect(cxcsChip, findsOneWidget);
    expect(
      find.descendant(
        of: cxChip,
        matching: find.byIcon(Icons.warning_amber_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: cxcsChip,
        matching: find.byIcon(Icons.warning_amber_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('per-mode save hands the host that mode JSON', (tester) async {
    KeymapMode? savedMode;
    String? savedJson;
    await tester.pumpWidget(_Harness(
      initial: KeymapConfig.fromDefaults(reg),
      onSave: (mode, json) {
        savedMode = mode;
        savedJson = json;
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('keymap-save-cua')));
    await tester.pump();

    expect(savedMode, KeymapMode.cua);
    expect(savedJson, contains('cua'));
    expect(savedJson, isNot(contains('emacs')));
  });
}
