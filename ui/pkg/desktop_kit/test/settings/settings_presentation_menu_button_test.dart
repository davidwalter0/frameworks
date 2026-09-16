// Tests for SettingsPresentationMenuButton: the face shows the current
// presentation; the menu offers exactly [options], checks the current one, and
// reports a pick.
library;

import 'package:desktop_kit/desktop_kit_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<SettingsPresentation>> _pump(
  WidgetTester tester, {
  required SettingsPresentation current,
  List<SettingsPresentation> options = SettingsPresentation.values,
}) async {
  final List<SettingsPresentation> picked = <SettingsPresentation>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SettingsPresentationMenuButton(
            current: current,
            options: options,
            onSelected: picked.add,
          ),
        ),
      ),
    ),
  );
  return picked;
}

const Key _button = Key('settingsPresentationMenu.button');
Finder _item(SettingsPresentation mode) =>
    find.byKey(Key('settingsPresentationMenu.${mode.name}'));

void main() {
  testWidgets(
      "the face is the current presentation's icon, named in its "
      'tooltip', (WidgetTester tester) async {
    await _pump(tester, current: SettingsPresentation.topSpan);
    final IconButton face = tester.widget<IconButton>(find.byKey(_button));
    expect((face.icon as Icon).icon, SettingsPresentation.topSpan.icon);
    expect(face.tooltip, 'Settings presentation: Top span');
  });

  testWidgets(
      'the menu lists every option with a check on the current one, '
      'and a pick is reported', (WidgetTester tester) async {
    final List<SettingsPresentation> picked =
        await _pump(tester, current: SettingsPresentation.bottomSheet);
    await tester.tap(find.byKey(_button));
    await tester.pumpAndSettle();

    for (final SettingsPresentation mode in SettingsPresentation.values) {
      expect(_item(mode), findsOneWidget, reason: mode.name);
      final MenuItemButton item = tester.widget<MenuItemButton>(_item(mode));
      expect(
        item.trailingIcon != null,
        mode == SettingsPresentation.bottomSheet,
        reason: '${mode.name} checked?',
      );
    }

    await tester.tap(_item(SettingsPresentation.popup));
    await tester.pumpAndSettle();
    expect(picked, <SettingsPresentation>[SettingsPresentation.popup]);
    expect(_item(SettingsPresentation.popup), findsNothing, reason: 'closed');
  });

  testWidgets(
      'labelOf and iconOf rename a presentation on the face, in the tooltip '
      'and in the menu; the others keep the kit\'s names',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SettingsPresentationMenuButton(
              current: SettingsPresentation.inline,
              onSelected: (_) {},
              labelOf: (SettingsPresentation m) =>
                  m == SettingsPresentation.inline ? 'Side panel' : m.label,
              iconOf: (SettingsPresentation m) =>
                  m == SettingsPresentation.inline
                      ? Icons.view_sidebar
                      : m.icon,
            ),
          ),
        ),
      ),
    );
    final IconButton face = tester.widget<IconButton>(find.byKey(_button));
    expect((face.icon as Icon).icon, Icons.view_sidebar);
    expect(face.tooltip, 'Settings presentation: Side panel');

    await tester.tap(find.byKey(_button));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: _item(SettingsPresentation.inline),
        matching: find.text('Side panel'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _item(SettingsPresentation.popup),
        matching: find.text(SettingsPresentation.popup.label),
      ),
      findsOneWidget,
    );
  });

  testWidgets('options limits the menu (textloom offers the sheet and the spans)',
      (WidgetTester tester) async {
    await _pump(
      tester,
      current: SettingsPresentation.bottomSheet,
      options: const <SettingsPresentation>[
        SettingsPresentation.bottomSheet,
        SettingsPresentation.topSpan,
        SettingsPresentation.bottomSpan,
      ],
    );
    await tester.tap(find.byKey(_button));
    await tester.pumpAndSettle();
    expect(_item(SettingsPresentation.topSpan), findsOneWidget);
    expect(_item(SettingsPresentation.inline), findsNothing);
    expect(_item(SettingsPresentation.popup), findsNothing);
  });
}
