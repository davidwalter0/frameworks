// Tests for the configurable settings-presentation framework:
//   • SettingsPresentation.fromName / .name round-trip (incl. unknown→inline);
//   • encodePresentationPrefs / decodePresentationPrefs round-trip + defensive
//     decode of garbage input;
//   • openSettingsCategory(popup) shows a dialog with the content;
//   • openSettingsCategory(bottomSheet) shows a sheet with the content;
//   • SettingsCategoryTile inline embeds content; non-inline shows "Open …".
library;

import 'package:desktop_kit/desktop_kit_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A category whose body is an easy-to-find marker widget.
SettingsCategory _markerCategory({String id = 'cat'}) {
  return SettingsCategory(
    id: id,
    title: 'Demo Category',
    icon: Icons.tune,
    content: (BuildContext context) => const Text('CATEGORY-BODY-MARKER'),
  );
}

void main() {
  // ── Enum <-> name ──────────────────────────────────────────────────────────

  group('SettingsPresentation.fromName / .name', () {
    test('round-trips every value via .name', () {
      for (final SettingsPresentation p in SettingsPresentation.values) {
        expect(SettingsPresentation.fromName(p.name), p);
      }
    });

    test('unknown name falls back to inline', () {
      expect(SettingsPresentation.fromName('nonsense'),
          SettingsPresentation.inline);
      expect(SettingsPresentation.fromName(''), SettingsPresentation.inline);
    });

    test('label is non-empty for every value', () {
      for (final SettingsPresentation p in SettingsPresentation.values) {
        expect(p.label, isNotEmpty);
      }
    });

    test('names are the expected stable strings', () {
      expect(SettingsPresentation.inline.name, 'inline');
      expect(SettingsPresentation.popup.name, 'popup');
      expect(SettingsPresentation.bottomSheet.name, 'bottomSheet');
    });
  });

  // ── encode / decode ────────────────────────────────────────────────────────

  group('encode / decode presentation prefs', () {
    test('round-trips a populated map', () {
      const Map<String, SettingsPresentation> prefs = {
        'appearance': SettingsPresentation.popup,
        'clipboard': SettingsPresentation.bottomSheet,
        'keymap': SettingsPresentation.inline,
      };
      final Map<String, dynamic> encoded = encodePresentationPrefs(prefs);

      // Encoded values are the enum names (JSON-friendly strings).
      expect(encoded['appearance'], 'popup');
      expect(encoded['clipboard'], 'bottomSheet');
      expect(encoded['keymap'], 'inline');

      final Map<String, SettingsPresentation> decoded =
          decodePresentationPrefs(encoded);
      expect(decoded, prefs);
    });

    test('round-trips an empty map', () {
      expect(encodePresentationPrefs(const {}), isEmpty);
      expect(decodePresentationPrefs(const <String, dynamic>{}), isEmpty);
    });

    test('decode of null returns empty', () {
      expect(decodePresentationPrefs(null), isEmpty);
    });

    test('decode of a non-map returns empty', () {
      expect(decodePresentationPrefs('a string'), isEmpty);
      expect(decodePresentationPrefs(42), isEmpty);
      expect(decodePresentationPrefs(<int>[1, 2, 3]), isEmpty);
    });

    test('decode skips non-string keys/values but keeps valid entries', () {
      final Map<Object?, Object?> raw = <Object?, Object?>{
        'good': 'popup',
        'badValue': 123,
        7: 'inline', // non-string key
        'unknownName': 'not-a-mode',
      };
      final Map<String, SettingsPresentation> decoded =
          decodePresentationPrefs(raw);

      expect(decoded['good'], SettingsPresentation.popup);
      // Unknown name → inline (defensive fromName).
      expect(decoded['unknownName'], SettingsPresentation.inline);
      // Non-string value skipped; non-string key skipped.
      expect(decoded.containsKey('badValue'), isFalse);
      expect(decoded.length, 2);
    });
  });

  // ── openSettingsCategory ─────────────────────────────────────────────────────

  group('openSettingsCategory', () {
    testWidgets('inline mode is a no-op (no dialog/sheet)', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => openSettingsCategory(
                  context,
                  _markerCategory(),
                  SettingsPresentation.inline,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // Inline opens nothing.
      expect(find.text('CATEGORY-BODY-MARKER'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('popup mode shows a dialog containing the content', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => openSettingsCategory(
                  context,
                  _markerCategory(),
                  SettingsPresentation.popup,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Demo Category'), findsOneWidget); // dialog title
      expect(find.text('CATEGORY-BODY-MARKER'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);

      // Close action dismisses the dialog.
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('bottomSheet mode shows a sheet containing the content', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => openSettingsCategory(
                  context,
                  _markerCategory(),
                  SettingsPresentation.bottomSheet,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('CATEGORY-BODY-MARKER'), findsOneWidget);
    });

    testWidgets('Escape pops a bottom sheet (desktop escape-to-pop wiring)', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => openSettingsCategory(
                  context,
                  _markerCategory(),
                  SettingsPresentation.bottomSheet,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('CATEGORY-BODY-MARKER'), findsOneWidget);

      // Send Escape — the _EscapeToPop wrapper should Navigator.maybePop().
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // The sheet is gone; the host page (the "open" button) is back.
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('CATEGORY-BODY-MARKER'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('sheets STACK and Escape unwinds them one at a time', (
      WidgetTester tester,
    ) async {
      // A category whose body opens ANOTHER sheet on top of itself.
      late SettingsCategory inner;
      inner = SettingsCategory(
        id: 'inner',
        title: 'Inner',
        icon: Icons.layers,
        content: (BuildContext context) => const Text('INNER-BODY'),
      );
      final SettingsCategory outer = SettingsCategory(
        id: 'outer',
        title: 'Outer',
        icon: Icons.layers_outlined,
        content: (BuildContext context) => Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('OUTER-BODY'),
            TextButton(
              onPressed: () => openSettingsCategory(
                context,
                inner,
                SettingsPresentation.bottomSheet,
              ),
              child: const Text('open-inner'),
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => openSettingsCategory(
                  context,
                  outer,
                  SettingsPresentation.bottomSheet,
                ),
                child: const Text('open-outer'),
              ),
            ),
          ),
        ),
      );

      // Open the outer sheet.
      await tester.tap(find.text('open-outer'));
      await tester.pumpAndSettle();
      expect(find.text('OUTER-BODY'), findsOneWidget);

      // From inside it, open the inner sheet — they stack (two sheets now).
      await tester.tap(find.text('open-inner'));
      await tester.pumpAndSettle();
      expect(find.text('INNER-BODY'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNWidgets(2));

      // Escape pops the TOP (inner) sheet, revealing the outer one beneath.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('INNER-BODY'), findsNothing);
      expect(find.text('OUTER-BODY'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);

      // Escape again pops the outer sheet, back to the host page.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('open-outer'), findsOneWidget);
    });
  });

  // ── SettingsCategoryTile ─────────────────────────────────────────────────────

  group('SettingsCategoryTile', () {
    testWidgets('inline mode embeds the content directly', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsCategoryTile(
              category: _markerCategory(),
              mode: SettingsPresentation.inline,
              onModeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Content is embedded (ExpansionTile starts expanded by default).
      expect(find.text('CATEGORY-BODY-MARKER'), findsOneWidget);
      // No "Open …" button in inline mode.
      expect(find.text('Open Demo Category'), findsNothing);
      // The selector is present — a category allowing all 6 modes renders the
      // dropdown variant (segments don't scale past 4 options).
      expect(find.byType(DropdownButton<SettingsPresentation>), findsOneWidget);
    });

    testWidgets(
        'inline: expanding a category with a scrollable child does not throw '
        '(PageStorage bool/double regression)', (WidgetTester tester) async {
      // A category whose body holds a multi-line TextField — its internal
      // Scrollable participates in PageStorage. With a PageStorageKey on the
      // ExpansionTile, its expanded *bool* landed in the same bucket the
      // Scrollable read as a scroll-offset *double*, throwing "type 'bool' is
      // not a subtype of type 'double?'" the instant the section expanded.
      final SettingsCategory scrollableCat = SettingsCategory(
        id: 'scrollable',
        title: 'Scrollable Category',
        icon: Icons.edit,
        content: (BuildContext context) => const TextField(maxLines: 3),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: <Widget>[
                SettingsCategoryTile(
                  category: scrollableCat,
                  mode: SettingsPresentation.inline,
                  onModeChanged: (_) {},
                  initiallyExpanded: false,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Expanding the section is the exact action that used to crash.
      await tester.tap(find.text('Scrollable Category'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('popup mode shows the "Open …" button, not embedded content', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsCategoryTile(
              category: _markerCategory(),
              mode: SettingsPresentation.popup,
              onModeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Not embedded.
      expect(find.text('CATEGORY-BODY-MARKER'), findsNothing);
      // "Open Demo Category" button present.
      expect(find.text('Open Demo Category'), findsOneWidget);

      // Tapping it opens the popup with the content.
      await tester.tap(find.text('Open Demo Category'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('CATEGORY-BODY-MARKER'), findsOneWidget);
    });

    testWidgets('changing the selector calls onModeChanged', (
      WidgetTester tester,
    ) async {
      SettingsPresentation? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsCategoryTile(
              category: _markerCategory(),
              mode: SettingsPresentation.inline,
              onModeChanged: (SettingsPresentation m) => picked = m,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // All-6-modes category → dropdown selector: open it, pick "Popup".
      await tester.tap(find.byType(DropdownButton<SettingsPresentation>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Popup').last);
      await tester.pumpAndSettle();
      expect(picked, SettingsPresentation.popup);
    });
  });
}
