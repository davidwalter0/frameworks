// Tests for the settings category list and the two ways it is hosted:
//   • SettingsCategoryList — one single-line row per category;
//   • openSettingsCategoryList — the list as a route (sliding sheet, popup),
//     each row's page stacked on top, Escape popping one layer at a time;
//   • SettingsCategoryNavigator — the list in a non-route region, a row's
//     page shown in place, Escape going back one layer before the host's.
library;

import 'package:desktop_kit/desktop_kit_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

SettingsCategory _category(String id, {String? title}) => SettingsCategory(
      id: id,
      title: title ?? 'Category $id',
      icon: Icons.tune,
      content: (BuildContext context) => Text('BODY-$id'),
    );

final List<SettingsCategory> _categories = <SettingsCategory>[
  _category('a'),
  _category('b'),
];

/// A host page with a button that runs [onPressed] with a context below the
/// Navigator.
Future<void> _pumpHost(
  WidgetTester tester,
  void Function(BuildContext context) onPressed,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => onPressed(context),
            child: const Text('OPEN'),
          ),
        ),
      ),
    ),
  );
}

Finder _row(String id) =>
    find.byKey(ValueKey<String>('settingsCategoryList.$id'));

void main() {
  group('SettingsCategoryList', () {
    testWidgets('one row per category, header above, a tap names its category',
        (WidgetTester tester) async {
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsCategoryList(
              categories: _categories,
              header: const <Widget>[Text('HEADER')],
              onOpen: (SettingsCategory c) => opened.add(c.id),
            ),
          ),
        ),
      );

      expect(_row('a'), findsOneWidget);
      expect(_row('b'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('HEADER')).dy,
        lessThan(tester.getTopLeft(_row('a')).dy),
      );
      expect(
        find.descendant(
            of: _row('a'), matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget,
      );

      await tester.tap(_row('b'));
      expect(opened, <String>['b']);
    });
  });

  group('openSettingsCategoryList', () {
    testWidgets(
        'sliding sheet: a row opens its page ON TOP of the list, and '
        'Escape pops one layer at a time', (WidgetTester tester) async {
      await _pumpHost(
        tester,
        (BuildContext c) => openSettingsCategoryList(
          c,
          _categories,
          SettingsPresentation.bottomSheet,
        ),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      expect(_row('a'), findsOneWidget);

      await tester.tap(_row('a'));
      await tester.pumpAndSettle();
      expect(find.text('BODY-a'), findsOneWidget);
      expect(_row('a'), findsOneWidget,
          reason: 'the list sheet is still under it');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('BODY-a'), findsNothing, reason: 'the page popped');
      expect(_row('a'), findsOneWidget, reason: 'the list did not');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_row('a'), findsNothing,
          reason: 'the second Escape pops the list');
    });

    testWidgets(
        'popup: a row opens its page as a second dialog on top; '
        'closing it returns to the list', (WidgetTester tester) async {
      await _pumpHost(
        tester,
        (BuildContext c) => openSettingsCategoryList(
            c, _categories, SettingsPresentation.popup),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(_row('b'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNWidgets(2));
      expect(find.text('BODY-b'), findsOneWidget);

      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(_row('b'), findsOneWidget);
    });

    testWidgets(
        'a row whose presentation is a span closes the list and pins '
        'it through onPinSpan, opening nothing', (WidgetTester tester) async {
      final List<(String, SettingsPresentation)> pinned =
          <(String, SettingsPresentation)>[];
      await _pumpHost(
        tester,
        (BuildContext c) => openSettingsCategoryList(
          c,
          _categories,
          SettingsPresentation.bottomSheet,
          presentationFor: (SettingsCategory cat) => cat.id == 'a'
              ? SettingsPresentation.topSpan
              : SettingsPresentation.bottomSheet,
          onPinSpan: (SettingsCategory cat, SettingsPresentation span) =>
              pinned.add((cat.id, span)),
        ),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();

      await tester.tap(_row('a'));
      await tester.pumpAndSettle();

      expect(pinned, <(String, SettingsPresentation)>[
        ('a', SettingsPresentation.topSpan),
      ]);
      expect(_row('a'), findsNothing, reason: 'the list closed');
      expect(find.text('BODY-a'), findsNothing, reason: 'nothing was opened');
    });

    testWidgets(
        'with no onPinSpan, a span answer opens the page in the list '
        'mode instead', (WidgetTester tester) async {
      await _pumpHost(
        tester,
        (BuildContext c) => openSettingsCategoryList(
          c,
          _categories,
          SettingsPresentation.bottomSheet,
          presentationFor: (_) => SettingsPresentation.bottomSpan,
        ),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      await tester.tap(_row('b'));
      await tester.pumpAndSettle();
      expect(find.text('BODY-b'), findsOneWidget);
    });

    for (final SettingsPresentation mode in <SettingsPresentation>[
      SettingsPresentation.inline,
      SettingsPresentation.topSpan,
      SettingsPresentation.bottomSpan,
    ]) {
      testWidgets('${mode.name}: a region the host lays out, so nothing opens',
          (WidgetTester tester) async {
        await _pumpHost(
          tester,
          (BuildContext c) => openSettingsCategoryList(c, _categories, mode),
        );
        await tester.tap(find.text('OPEN'));
        await tester.pumpAndSettle();
        expect(_row('a'), findsNothing);
      });
    }
  });

  group('SettingsCategoryNavigator', () {
    /// The navigator under a host whose OWN focus and Escape binding sit
    /// above it — the shape of a docked settings panel.
    Future<List<String?>> pumpNavigator(
      WidgetTester tester, {
      required ValueChanged<int> onHostEscape,
    }) async {
      final List<String?> pages = <String?>[];
      var hostEscapes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    onHostEscape(++hostEscapes),
              },
              child: Focus(
                autofocus: true,
                child: SingleChildScrollView(
                  child: SettingsCategoryNavigator(
                    categories: _categories,
                    onPageChanged: pages.add,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return pages;
    }

    testWidgets('a row shows its page in place; back returns to the list',
        (WidgetTester tester) async {
      final List<String?> pages =
          await pumpNavigator(tester, onHostEscape: (_) {});
      expect(_row('a'), findsOneWidget);

      await tester.tap(_row('a'));
      await tester.pumpAndSettle();
      expect(find.text('BODY-a'), findsOneWidget);
      expect(find.text('Category a'), findsOneWidget);
      expect(_row('b'), findsNothing, reason: 'the page replaces the list');

      await tester.tap(find.byKey(const Key('settingsCategoryNavigator.back')));
      await tester.pumpAndSettle();
      expect(find.text('BODY-a'), findsNothing);
      expect(_row('b'), findsOneWidget);
      expect(pages, <String?>['a', null]);
    });

    testWidgets(
        'Escape on a page goes back to the list without reaching the '
        'host; on the list it reaches the host', (WidgetTester tester) async {
      final List<int> hostEscapes = <int>[];
      await pumpNavigator(tester, onHostEscape: hostEscapes.add);

      await tester.tap(_row('b'));
      await tester.pumpAndSettle();
      expect(find.text('BODY-b'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('BODY-b'), findsNothing, reason: 'back one layer');
      expect(hostEscapes, isEmpty, reason: 'the host saw nothing');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(hostEscapes, <int>[1], reason: 'the list binds no Escape');
    });

    testWidgets(
        "the page's content spans the navigator's full width, and its icon "
        "takes the host's IconTheme size", (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IconTheme.merge(
              data: const IconThemeData(size: 40),
              child: SettingsCategoryNavigator(categories: _categories),
            ),
          ),
        ),
      );
      await tester.tap(_row('a'));
      await tester.pumpAndSettle();

      // The page's column stretches the content, so its own edges show any
      // inset (a Padding's rect would not: it includes the padding).
      final Rect navigator =
          tester.getRect(find.byType(SettingsCategoryNavigator));
      final Rect body = tester.getRect(find.text('BODY-a'));
      expect(body.left, navigator.left);
      expect(body.right, navigator.right);
      expect(
        tester.getSize(find.byIcon(Icons.tune)).width,
        40,
        reason: 'no hard-coded icon size',
      );
    });
  });
}
