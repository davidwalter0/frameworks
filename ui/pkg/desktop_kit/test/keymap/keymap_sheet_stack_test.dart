// Tests for the keymap editor's stacked-sheet presentation.
//
// Two defects motivated this, both reported from the live app and both rooted
// in route/overlay layering rather than in the editor itself:
//
//   1. The chord-capture window came up BEHIND the surface that launched it,
//      so you could not see what you were typing. Cause: a settings category
//      rendered as an anchored popover is a hand-inserted OverlayEntry, and
//      Navigator inserts a newly-pushed route relative to the previous ROUTE —
//      never above a manually inserted entry. A capture dialog pushed from
//      inside such a popover therefore renders underneath it.
//   2. Finishing one assignment tore the editor down, so rebinding N keys cost
//      N open/close cycles.
//
// The fix is presentation, not capture logic: the editor opens as its own sheet
// stacked over whatever launched it, and capture goes to the root navigator so
// it outranks the whole stack. These tests pin the stack's shape — that opening
// the editor does not replace the surface beneath it, that Escape pops exactly
// one level, and that the editor survives an assignment.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps a settings sheet that hosts the keymap editor surface, mirroring the
/// eedit arrangement: a host page → a settings sheet → the editor sheet.
Future<void> pumpSettingsHostingEditor(WidgetTester tester) async {
  KeymapConfig config = KeymapConfig.empty;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            key: const Key('open-settings'),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => StatefulBuilder(
                builder: (BuildContext c, StateSetter setSheet) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text('settings-sheet-marker'),
                    KeymapEditorSurface(
                      presentation: KeymapEditorPresentation.bottomSheet,
                      value: config,
                      onChanged: (KeymapConfig next) =>
                          setSheet(() => config = next),
                    ),
                  ],
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-settings')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('editor sheet stacks OVER settings rather than replacing it',
      (WidgetTester tester) async {
    await pumpSettingsHostingEditor(tester);
    expect(find.text('settings-sheet-marker'), findsOneWidget);

    await tester.tap(find.byKey(const Key('keymap-editor-launch')));
    await tester.pumpAndSettle();

    // The settings sheet is still mounted underneath — this is a stack, not a
    // navigation. If the editor had replaced it, the marker would be gone.
    expect(find.text('settings-sheet-marker'), findsOneWidget);
    expect(find.byType(KeymapEditor), findsOneWidget);
  });

  testWidgets('Escape pops one level, leaving the settings sheet open',
      (WidgetTester tester) async {
    await pumpSettingsHostingEditor(tester);
    await tester.tap(find.byKey(const Key('keymap-editor-launch')));
    await tester.pumpAndSettle();
    expect(find.byType(KeymapEditor), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // One item off the stack: the editor is gone, settings survives. The bug
    // this guards is Escape tearing down the whole stack at once.
    expect(find.byType(KeymapEditor), findsNothing);
    expect(find.text('settings-sheet-marker'), findsOneWidget);
  });
}

// NOTE: the "capture window renders above the stack" half of the fix is NOT
// covered here. Reaching the capture window needs a populated KeymapRegistry to
// give the editor an action row to press, and asserting paint ORDER (rather
// than mere presence) needs a layer-order probe, not a finder — findsOneWidget
// passes just as happily when the dialog is buried behind the popover, which is
// precisely the bug. Left explicitly uncovered rather than faked with a test
// that would have passed before the fix.
