import 'package:desktop_kit/desktop_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester, {
  String? title,
  String? info,
  VoidCallback? onReset,
  bool startCollapsed = false,
}) async {
  KeymapConfig config = KeymapConfig.fromDefaults(KeymapRegistry.defaults());
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 720,
          width: 720,
          child: KeymapEditor(
            value: config,
            registry: KeymapRegistry.defaults(),
            onChanged: (KeymapConfig c) => config = c,
            title: title,
            infoTooltip: info,
            onReset: onReset,
            startCollapsed: startCollapsed,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('title + info button render on the toolbar', (tester) async {
    await _pump(tester, title: 'Keymap', info: 'the help text');
    expect(find.text('Keymap'), findsOneWidget);
    expect(find.byKey(const Key('keymap-info')), findsOneWidget);
  });

  testWidgets('no title → no info button', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('keymap-info')), findsNothing);
  });

  testWidgets('onReset overrides the built-in reset (fires, no confirm)',
      (tester) async {
    int called = 0;
    await _pump(tester, onReset: () => called++);
    await tester.tap(find.byKey(const Key('keymap-reset')));
    await tester.pumpAndSettle();
    expect(called, 1);
    expect(find.text('Reset to defaults?'), findsNothing);
  });

  testWidgets('startCollapsed hides rows until a group is expanded',
      (tester) async {
    await _pump(tester, startCollapsed: true);
    expect(find.text('Move to line start'), findsNothing);

    await tester.tap(find.text('Motions').first);
    await tester.pumpAndSettle();

    expect(find.text('Move to line start'), findsWidgets);
  });
}
