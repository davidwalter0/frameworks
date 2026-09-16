// Widget tests for KeymapEditorSurface: each presentation renders the editor,
// and the modal presentations open from a launch button + close on Escape.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final reg = KeymapRegistry.defaults();
  final config = KeymapConfig.fromDefaults(reg);

  Widget host(KeymapEditorPresentation p) => MaterialApp(
        home: Scaffold(
          body: KeymapEditorSurface(
            presentation: p,
            value: config,
            onChanged: (_) {},
            registry: reg,
          ),
        ),
      );

  testWidgets('inline renders the editor directly', (tester) async {
    await tester.pumpWidget(host(KeymapEditorPresentation.inline));
    await tester.pumpAndSettle();
    expect(find.byType(KeymapEditor), findsOneWidget);
    expect(find.text('CUA bindings'), findsOneWidget);
  });

  testWidgets('foldable shows the editor only once expanded', (tester) async {
    await tester.pumpWidget(host(KeymapEditorPresentation.foldable));
    await tester.pumpAndSettle();
    // Collapsed by default → the editor body is not built.
    expect(find.byType(KeymapEditor), findsNothing);
    expect(find.text('Keybindings'), findsOneWidget); // the fold header
    await tester.tap(find.text('Keybindings'));
    await tester.pumpAndSettle();
    expect(find.byType(KeymapEditor), findsOneWidget);
  });

  for (final p in const [
    KeymapEditorPresentation.popup,
    KeymapEditorPresentation.bottomSheet,
  ]) {
    testWidgets('$p opens from a launch button and Escape closes it', (
      tester,
    ) async {
      await tester.pumpWidget(host(p));
      await tester.pumpAndSettle();
      // Nothing open yet — just the launch button.
      expect(find.byType(KeymapEditor), findsNothing);
      expect(find.byKey(const Key('keymap-editor-launch')), findsOneWidget);

      await tester.tap(find.byKey(const Key('keymap-editor-launch')));
      await tester.pumpAndSettle();
      expect(find.byType(KeymapEditor), findsOneWidget);

      // Escape pops exactly this one overlay route.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(KeymapEditor), findsNothing);
    });
  }

  testWidgets('modal edits are mirrored to the host onChanged', (tester) async {
    KeymapConfig? seen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeymapEditorSurface(
            presentation: KeymapEditorPresentation.popup,
            value: config,
            registry: reg,
            onChanged: (next) => seen = next,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('keymap-editor-launch')));
    await tester.pumpAndSettle();
    // Reset-to-defaults (an always-visible toolbar button) → confirm → the
    // editor fires onChanged; the modal must mirror that to the host.
    await tester.tap(find.byKey(const Key('keymap-reset')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(seen, isNotNull, reason: 'a modal edit must reach the host');
  });
}
