// Tests for the SettingsPresentation extension (topSpan/bottomSpan/popover),
// legacy-token compatibility, resolvePresentation, selector scaling, and the
// category tile's span/popover affordances.

import 'package:desktop_kit/desktop_kit_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SettingsPresentation enum', () {
    test('has all five modes, and popover is not among them', () {
      expect(SettingsPresentation.values, hasLength(5));
      expect(
        SettingsPresentation.values.map((p) => p.name),
        containsAll(<String>[
          'inline',
          'popup',
          'bottomSheet',
          'topSpan',
          'bottomSpan',
        ]),
      );
      expect(
        SettingsPresentation.values.map((p) => p.name),
        isNot(contains('popover')),
        reason: 'the anchored popover was removed — an OverlayEntry outranks '
            'any route pushed after it, so a category could not host its own '
            "content's dialogs",
      );
    });

    test('legacy bottomSheet token round-trips (member NOT renamed)', () {
      // Users who persisted "bottomSheet" before the extension must get the
      // same mode back — the member name is the compat contract.
      expect(
        SettingsPresentation.fromName('bottomSheet'),
        SettingsPresentation.bottomSheet,
      );
      expect(SettingsPresentation.bottomSheet.name, 'bottomSheet');
    });

    test('bottomSheet is relabelled "Sliding sheet"', () {
      expect(SettingsPresentation.bottomSheet.label, 'Sliding sheet');
    });

    test('new modes carry word-bank labels', () {
      expect(SettingsPresentation.topSpan.label, 'Top span');
      expect(SettingsPresentation.bottomSpan.label, 'Bottom span');
    });

    test('unknown token falls back to inline', () {
      expect(
        SettingsPresentation.fromName('slidingSheet'),
        SettingsPresentation.inline,
      );
      expect(SettingsPresentation.fromName(''), SettingsPresentation.inline);
    });

    test('all six round-trip through encode/decode prefs', () {
      final Map<String, SettingsPresentation> prefs = {
        for (final p in SettingsPresentation.values) 'cat_${p.name}': p,
      };
      final decoded = decodePresentationPrefs(encodePresentationPrefs(prefs));
      expect(decoded, prefs);
    });
  });

  group('resolvePresentation', () {
    test('explicit choice wins', () {
      expect(
        resolvePresentation(SettingsPresentation.topSpan, isHandheld: true),
        SettingsPresentation.topSpan,
      );
    });

    test('form-factor defaults: handheld→sliding sheet, desktop→popup', () {
      expect(
        resolvePresentation(null, isHandheld: true),
        SettingsPresentation.bottomSheet,
      );
      expect(
        resolvePresentation(null, isHandheld: false),
        SettingsPresentation.popup,
      );
    });

    test('the retired popover token migrates to the sliding sheet', () {
      // Not the unknown-token path: "popover" was a real persisted choice (and
      // shipped as the app-wide "*" default), so it must land on a mode that
      // actually opens, not on inline.
      expect(
        SettingsPresentation.fromName('popover'),
        SettingsPresentation.bottomSheet,
      );
    });
  });

  group('SettingsCategory.allowedModes', () {
    test('null/empty allowedModes yields all values', () {
      const SettingsCategory cat = SettingsCategory(
        id: 'x',
        title: 'X',
        icon: Icons.settings,
        content: _emptyBuilder,
      );
      expect(cat.effectiveModes, SettingsPresentation.values);

      const SettingsCategory empty = SettingsCategory(
        id: 'y',
        title: 'Y',
        icon: Icons.settings,
        content: _emptyBuilder,
        allowedModes: <SettingsPresentation>[],
      );
      expect(empty.effectiveModes, SettingsPresentation.values);
    });

    test('explicit allowedModes are honored', () {
      const SettingsCategory cat = SettingsCategory(
        id: 'x',
        title: 'X',
        icon: Icons.settings,
        content: _emptyBuilder,
        allowedModes: <SettingsPresentation>[
          SettingsPresentation.inline,
          SettingsPresentation.popup,
        ],
      );
      expect(cat.effectiveModes, hasLength(2));
    });
  });

  group('selector scaling', () {
    testWidgets('≤4 options renders a SegmentedButton', (tester) async {
      const SettingsCategory cat = SettingsCategory(
        id: 'seg',
        title: 'Seg',
        icon: Icons.tune,
        content: _emptyBuilder,
        allowedModes: <SettingsPresentation>[
          SettingsPresentation.inline,
          SettingsPresentation.popup,
          SettingsPresentation.bottomSheet,
        ],
      );
      await tester.pumpWidget(_host(
        SettingsCategoryTile(
          category: cat,
          mode: SettingsPresentation.inline,
          onModeChanged: (_) {},
        ),
      ));
      expect(
          find.byType(SegmentedButton<SettingsPresentation>), findsOneWidget);
      expect(find.byType(DropdownButton<SettingsPresentation>), findsNothing);
    });

    testWidgets('>4 options renders a DropdownButton', (tester) async {
      const SettingsCategory cat = SettingsCategory(
        id: 'drop',
        title: 'Drop',
        icon: Icons.tune,
        content: _emptyBuilder,
        // null allowedModes = all 6 → dropdown.
      );
      await tester.pumpWidget(_host(
        SettingsCategoryTile(
          category: cat,
          mode: SettingsPresentation.inline,
          onModeChanged: (_) {},
        ),
      ));
      expect(find.byType(DropdownButton<SettingsPresentation>), findsOneWidget);
      expect(find.byType(SegmentedButton<SettingsPresentation>), findsNothing);
    });

    testWidgets('persisted mode outside allowedModes is still selectable',
        (tester) async {
      const SettingsCategory cat = SettingsCategory(
        id: 'stale',
        title: 'Stale',
        icon: Icons.tune,
        content: _emptyBuilder,
        allowedModes: <SettingsPresentation>[
          SettingsPresentation.inline,
          SettingsPresentation.popup,
        ],
      );
      // Mode persisted before allowedModes shrank.
      await tester.pumpWidget(_host(
        SettingsCategoryTile(
          category: cat,
          mode: SettingsPresentation.bottomSheet,
          onModeChanged: (_) {},
        ),
      ));
      // 2 allowed + 1 stale = 3 → segmented, containing the stale mode.
      final SegmentedButton<SettingsPresentation> seg = tester.widget(
        find.byType(SegmentedButton<SettingsPresentation>),
      );
      expect(
        seg.segments.map((s) => s.value),
        contains(SettingsPresentation.bottomSheet),
      );
    });
  });

  group('span affordance', () {
    testWidgets('topSpan mode shows a Pin button wired to onActivateSpan',
        (tester) async {
      SettingsCategory? pinned;
      SettingsPresentation? side;
      const SettingsCategory cat = SettingsCategory(
        id: 'span',
        title: 'Span',
        icon: Icons.tune,
        content: _emptyBuilder,
      );
      await tester.pumpWidget(_host(
        SettingsCategoryTile(
          category: cat,
          mode: SettingsPresentation.topSpan,
          onModeChanged: (_) {},
          onActivateSpan: (c, s) {
            pinned = c;
            side = s;
          },
        ),
      ));
      expect(find.textContaining('Pin as top span'), findsOneWidget);
      await tester.tap(find.textContaining('Pin as top span'));
      expect(pinned?.id, 'span');
      expect(side, SettingsPresentation.topSpan);
    });

    testWidgets('span Pin button disabled without onActivateSpan',
        (tester) async {
      const SettingsCategory cat = SettingsCategory(
        id: 'span2',
        title: 'Span2',
        icon: Icons.tune,
        content: _emptyBuilder,
      );
      await tester.pumpWidget(_host(
        SettingsCategoryTile(
          category: cat,
          mode: SettingsPresentation.bottomSpan,
          onModeChanged: (_) {},
        ),
      ));
      final FilledButton button = tester.widget(
        find.widgetWithText(FilledButton, 'Pin as bottom span'),
      );
      expect(button.onPressed, isNull);
    });
  });
}

Widget _emptyBuilder(BuildContext context) => const SizedBox.shrink();

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );
