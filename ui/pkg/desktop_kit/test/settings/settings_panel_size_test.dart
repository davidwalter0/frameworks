import 'package:desktop_kit/desktop_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SettingsCategory _cat({
  SettingsPanelSize size = const SettingsPanelSize(),
  SettingsPresentation present = SettingsPresentation.popup,
}) =>
    SettingsCategory(
      id: 'x',
      title: 'X',
      icon: Icons.settings,
      content: (BuildContext ctx) => const Text('body'),
      defaultPresentation: present,
      size: size,
    );

Future<void> _open(
  WidgetTester tester,
  SettingsCategory cat,
  SettingsPresentation mode, {
  SettingsPanelSize? size,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext ctx) => Center(
            child: ElevatedButton(
              onPressed: () => openSettingsCategory(ctx, cat, mode, size: size),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('popup uses the category popupWidth + popupMaxHeight',
      (tester) async {
    await _open(
      tester,
      _cat(size: const SettingsPanelSize(popupWidth: 560, popupMaxHeight: 640)),
      SettingsPresentation.popup,
    );
    expect(find.byWidgetPredicate((w) => w is SizedBox && w.width == 560),
        findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w is ConstrainedBox && w.constraints.maxHeight == 640),
        findsWidgets);
  });

  testWidgets('popup defaults to width 480', (tester) async {
    await _open(tester, _cat(), SettingsPresentation.popup);
    expect(find.byWidgetPredicate((w) => w is SizedBox && w.width == 480),
        findsOneWidget);
  });

  testWidgets('call-site size overrides the category size', (tester) async {
    await _open(
      tester,
      _cat(size: const SettingsPanelSize(popupWidth: 400)),
      SettingsPresentation.popup,
      size: const SettingsPanelSize(popupWidth: 700),
    );
    expect(find.byWidgetPredicate((w) => w is SizedBox && w.width == 700),
        findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is SizedBox && w.width == 400),
        findsNothing);
  });

  testWidgets('bottom sheet uses the category sheet fractions', (tester) async {
    await _open(
      tester,
      _cat(
        size: const SettingsPanelSize(
          sheetInitialSize: 0.6,
          sheetMinSize: 0.2,
          sheetMaxSize: 0.8,
        ),
        present: SettingsPresentation.bottomSheet,
      ),
      SettingsPresentation.bottomSheet,
    );
    expect(
      find.byWidgetPredicate((w) =>
          w is DraggableScrollableSheet &&
          w.initialChildSize == 0.6 &&
          w.minChildSize == 0.2 &&
          w.maxChildSize == 0.8),
      findsOneWidget,
    );
  });

  testWidgets('popupMaxHeightFraction sizes the popup to the window',
      (tester) async {
    // Default test window is 800×600 logical → 0.5 × 600 = 300. The full-size
    // popup is a Dialog with an explicit SizedBox(height:) — deterministic.
    await _open(
      tester,
      _cat(size: const SettingsPanelSize(popupMaxHeightFraction: 0.5)),
      SettingsPresentation.popup,
    );
    expect(
      find.byWidgetPredicate((w) => w is SizedBox && w.height == 300),
      findsWidgets,
    );
  });
}
