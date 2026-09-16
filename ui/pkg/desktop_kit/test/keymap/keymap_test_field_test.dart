import 'package:desktop_kit/desktop_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A host intent used to test the [KeymapTestField.effects] extension hook.
class _ShoutIntent extends Intent {
  const _ShoutIntent();
}

/// A deterministic config (independent of the built-in defaults) so the tests
/// assert the field dispatches exactly what the config says: `C-t` →
/// moveLineStart (single stroke) and `C-x C-s` → save (sequence).
KeymapConfig _config() {
  final ctrlT = KeyChord(keyId: LogicalKeyboardKey.keyT.keyId, control: true);
  final ctrlX = KeyChord(keyId: LogicalKeyboardKey.keyX.keyId, control: true);
  final ctrlS = KeyChord(keyId: LogicalKeyboardKey.keyS.keyId, control: true);
  return KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{
    KeymapMode.emacs: <KeyChordSequence, String>{
      KeyChordSequence.single(ctrlT): 'moveLineStart',
      KeyChordSequence(<KeyChord>[ctrlX, ctrlS]): 'save',
    },
  });
}

Future<void> _pumpField(
  WidgetTester tester, {
  KeymapConfig? config,
  String initialText = '',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: KeymapTestField(
          config: config ?? _config(),
          registry: KeymapRegistry.defaults(),
          initialText: initialText,
          autofocus: true,
        ),
      ),
    ),
  );
  await tester.pump(); // let autofocus settle
}

Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  String? character,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(key, character: character);
  await tester.sendKeyUpEvent(key);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  testWidgets('single-stroke binding fires and is reported', (tester) async {
    await _pumpField(tester);
    await _chord(tester, LogicalKeyboardKey.keyT, control: true);
    expect(find.textContaining('Fired: Move to line start'), findsOneWidget);
  });

  testWidgets('multi-stroke sequence arms a prefix then fires', (tester) async {
    await _pumpField(tester);
    await _chord(tester, LogicalKeyboardKey.keyX, control: true);
    expect(find.textContaining('Prefix armed'), findsOneWidget);
    await _chord(tester, LogicalKeyboardKey.keyS, control: true);
    expect(find.textContaining('Fired: Save buffer'), findsOneWidget);
  });

  testWidgets('dispatch reflects THIS config, not the defaults',
      (tester) async {
    // C-a is a default Emacs binding but is unbound in _config() → reported
    // unbound, proving the field honours the passed config.
    await _pumpField(tester);
    await _chord(tester, LogicalKeyboardKey.keyA, control: true);
    expect(find.textContaining('Unbound: Ctrl+A'), findsOneWidget);
  });

  testWidgets('plain printable key types into the buffer', (tester) async {
    await _pumpField(tester);
    await _chord(tester, LogicalKeyboardKey.keyH, character: 'h');
    expect(find.textContaining('Typed "h"'), findsOneWidget);
  });

  testWidgets('a rebind in a new config is picked up (didUpdateWidget)',
      (tester) async {
    // Start with C-t → moveLineStart, then swap to a config binding C-t to save.
    await _pumpField(tester);
    await _chord(tester, LogicalKeyboardKey.keyT, control: true);
    expect(find.textContaining('Fired: Move to line start'), findsOneWidget);

    final ctrlT = KeyChord(keyId: LogicalKeyboardKey.keyT.keyId, control: true);
    final rebound = KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{
      KeymapMode.emacs: <KeyChordSequence, String>{
        KeyChordSequence.single(ctrlT): 'save',
      },
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeymapTestField(
            config: rebound,
            registry: KeymapRegistry.defaults(),
            autofocus: true,
          ),
        ),
      ),
    );
    await tester.pump();
    await _chord(tester, LogicalKeyboardKey.keyT, control: true);
    expect(find.textContaining('Fired: Save buffer'), findsOneWidget);
  });

  testWidgets('a host effect fires for a registered intent (not report-only)',
      (tester) async {
    final registry = KeymapRegistry.defaults()
      ..register(const KeymapAction(
        id: 'shout',
        label: 'Shout',
        group: 'Test',
        factory: _ShoutIntent.new,
      ));
    final ctrlU = KeyChord(keyId: LogicalKeyboardKey.keyU.keyId, control: true);
    final config = KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{
      KeymapMode.emacs: <KeyChordSequence, String>{
        KeyChordSequence.single(ctrlU): 'shout',
      },
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeymapTestField(
            config: config,
            registry: registry,
            initialText: 'hi',
            autofocus: true,
            effects: <String, KeymapTestEffect>{
              'shout': (String text, int caret) =>
                  (text: text.toUpperCase(), caret: caret),
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await _chord(tester, LogicalKeyboardKey.keyU, control: true);
    // Effect applied → reported as a plain fire, without the report-only note.
    expect(find.textContaining('Fired: Shout'), findsOneWidget);
    expect(find.textContaining('no buffer effect'), findsNothing);
  });
}
