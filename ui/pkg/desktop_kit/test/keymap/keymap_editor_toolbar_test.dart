import 'package:desktop_kit/desktop_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester) async {
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
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('toolbar exposes search, help, and the view toggle',
      (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('keymap-search-open')), findsOneWidget);
    expect(find.byKey(const Key('keymap-view-toggle')), findsOneWidget);
    expect(find.byIcon(Icons.help_outline), findsWidgets);
  });

  testWidgets('search filters the action list', (tester) async {
    await _pump(tester);
    expect(find.text('Kill line'), findsWidgets);

    await tester.tap(find.byKey(const Key('keymap-search-open')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('keymap-search')), 'yank');
    await tester.pumpAndSettle();

    expect(find.text('Yank'), findsWidgets);
    expect(find.text('Kill line'), findsNothing);
  });

  testWidgets('tree view collapses a group on header tap', (tester) async {
    await _pump(tester);
    expect(find.text('Move to line start'), findsWidgets); // in Motions

    await tester.tap(find.text('Motions').first);
    await tester.pumpAndSettle();

    expect(find.text('Move to line start'), findsNothing);
  });

  testWidgets('view toggle switches tree ↔ table (chevrons only in tree)',
      (tester) async {
    await _pump(tester);
    expect(find.byIcon(Icons.expand_more), findsWidgets); // tree default

    await tester.tap(find.byKey(const Key('keymap-view-toggle')));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.expand_more), findsNothing); // table: no chevrons
    expect(find.text('Kill line'), findsWidgets); // rows still there
  });

  testWidgets('switching back to tree view starts folded', (tester) async {
    await _pump(tester); // default tree, expanded
    expect(find.text('Move to line start'), findsWidgets);

    await tester.tap(find.byKey(const Key('keymap-view-toggle'))); // → table
    await tester.pumpAndSettle();
    expect(find.text('Move to line start'), findsWidgets); // table shows rows

    await tester.tap(find.byKey(const Key('keymap-view-toggle'))); // → tree
    await tester.pumpAndSettle();
    expect(find.text('Move to line start'), findsNothing); // folded on entry
  });
}
