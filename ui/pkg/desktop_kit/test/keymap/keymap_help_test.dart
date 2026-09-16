// Widget tests for showKeymapHelp.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const List<KeymapHelpGroup> _testGroups = [
  KeymapHelpGroup('Motions', [
    KeymapBinding('C-a', 'Beginning of line'),
    KeymapBinding('C-e', 'End of line'),
    KeymapBinding('M-f', 'Forward word', available: false),
  ]),
  KeymapHelpGroup('Kill ring', [
    KeymapBinding('C-k', 'Kill line'),
  ]),
];

Future<void> _openHelp(
  WidgetTester tester, {
  KeymapHelpPresentation presentation = KeymapHelpPresentation.popup,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showKeymapHelp(
              context,
              groups: _testGroups,
              title: 'Test shortcuts',
              intro: 'Intro paragraph.',
              presentation: presentation,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('showKeymapHelp dialog', () {
    testWidgets('shows custom title', (tester) async {
      await _openHelp(tester);
      expect(find.text('Test shortcuts'), findsOneWidget);
    });

    testWidgets('shows intro paragraph', (tester) async {
      await _openHelp(tester);
      expect(find.text('Intro paragraph.'), findsOneWidget);
    });

    testWidgets('shows group titles', (tester) async {
      await _openHelp(tester);
      expect(find.text('Motions'), findsOneWidget);
      expect(find.text('Kill ring'), findsOneWidget);
    });

    testWidgets('shows binding keys and descriptions', (tester) async {
      await _openHelp(tester);
      expect(find.text('C-a'), findsOneWidget);
      expect(find.text('Beginning of line'), findsOneWidget);
      expect(find.text('C-k'), findsOneWidget);
      expect(find.text('Kill line'), findsOneWidget);
    });

    testWidgets('shows "not yet available" for unavailable bindings',
        (tester) async {
      await _openHelp(tester);
      expect(find.text('not yet available'), findsOneWidget);
    });

    testWidgets('close button dismisses the dialog', (tester) async {
      await _openHelp(tester);
      expect(find.text('Test shortcuts'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('Test shortcuts'), findsNothing);
    });

    testWidgets('Escape dismisses the popup (pops one route)', (tester) async {
      await _openHelp(tester);
      expect(find.text('Test shortcuts'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Test shortcuts'), findsNothing);
    });
  });

  group('showKeymapHelp bottom sheet', () {
    testWidgets('renders the same content in a bottom sheet', (tester) async {
      await _openHelp(
        tester,
        presentation: KeymapHelpPresentation.bottomSheet,
      );
      expect(find.text('Test shortcuts'), findsOneWidget);
      expect(find.text('Motions'), findsOneWidget);
      expect(find.text('C-k'), findsOneWidget);
      expect(find.text('Kill line'), findsOneWidget);
    });

    testWidgets('Escape dismisses the sheet (pops one route)', (tester) async {
      await _openHelp(
        tester,
        presentation: KeymapHelpPresentation.bottomSheet,
      );
      expect(find.text('Test shortcuts'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Test shortcuts'), findsNothing);
    });
  });
}
