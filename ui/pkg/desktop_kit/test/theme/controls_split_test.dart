// Tests for the decoupled appearance controls — [ThemeColorControls] and
// [FontControls] — plus the [AppearancePane] composition:
//   • ThemeColorControls fires onChanged for preset / brightness / colour edits
//     and edits ONLY colour fields (fonts/size/weight untouched);
//   • FontControls fires onChanged for the base-size slider and edits ONLY
//     font/size/weight fields (colour untouched);
//   • FontControls.extraFontFamilies are surfaced (prepended) in the picker;
//   • AppearancePane composes both halves (one combined preview).
library;

import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pump [child] under a light-brightness MediaQuery so the effective-background
/// maths (and the contrast gate) are deterministic across hosts.
Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(platformBrightness: Brightness.light),
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
      ),
    ),
  );
}

/// Open the app-font picker (first "Pick…") and wait until its font list has
/// resolved, so [find] on a font name is meaningful.
///
/// The picker's `FutureBuilder` awaits `systemFontFamilies()`, which performs
/// REAL async I/O (Process.run / Isolate on Linux, a curated fallback
/// otherwise). Real I/O does not advance under the fake test clock, so we
/// interleave `tester.runAsync` (which grants real wall-clock time) with
/// `pump`s, polling until the list appears — up to a bounded number of tries.
Future<void> _openPickerAndSettle(WidgetTester tester) async {
  final Finder pick = find.text('Pick…').first;
  await tester.ensureVisible(pick);
  await tester.pump();
  await tester.tap(pick);
  await tester.pump(); // start dialog open transition
  await tester.pump(const Duration(milliseconds: 400)); // finish it

  // Poll: let the real font enumeration make progress, then rebuild.
  for (int i = 0; i < 40; i++) {
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }
}

void main() {
  group('ThemeColorControls (controlled)', () {
    testWidgets('renders the colour controls but NOT the font controls',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pump(
        tester,
        ThemeColorControls(
          value: const AppearanceSettings(),
          onChanged: changes.add,
          showPreview: false,
        ),
      );

      expect(find.text('Preset'), findsOneWidget);
      expect(find.text('Brightness'), findsOneWidget);
      expect(find.text('Seed colour'), findsOneWidget);
      expect(find.text('Text colour'), findsOneWidget);
      // Font-only sections must be absent — this is the colour half.
      expect(find.text('App font'), findsNothing);
      expect(find.text('Mono font'), findsNothing);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('tapping a preset chip fires onChanged with that preset',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pump(
        tester,
        ThemeColorControls(
          value: const AppearanceSettings(),
          onChanged: changes.add,
          showPreview: false,
        ),
      );

      await tester.tap(find.text('Dracula'));
      await tester.pump();

      expect(changes, isNotEmpty);
      expect(changes.last.presetName, 'Dracula');
    });

    testWidgets('selecting Dark brightness fires onChanged',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pump(
        tester,
        ThemeColorControls(
          value: const AppearanceSettings(),
          onChanged: changes.add,
          showPreview: false,
        ),
      );

      await tester.tap(find.text('Dark'));
      await tester.pump();

      expect(changes, isNotEmpty);
      expect(changes.last.mode, ThemeMode.dark);
    });

    testWidgets('a colour edit leaves font/size/weight fields untouched',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      // Seed a value with non-default font/size/weight to prove they survive.
      const AppearanceSettings seed = AppearanceSettings(
        appFont: 'Cantarell',
        monoFont: 'JetBrains Mono',
        baseSize: 17,
        weight: 600,
      );
      await _pump(
        tester,
        ThemeColorControls(
          value: seed,
          onChanged: changes.add,
          showPreview: false,
        ),
      );

      await tester.tap(find.text('Nord'));
      await tester.pump();

      expect(changes, isNotEmpty);
      final AppearanceSettings out = changes.last;
      expect(out.presetName, 'Nord');
      // The typography fields must be carried through unchanged.
      expect(out.appFont, 'Cantarell');
      expect(out.monoFont, 'JetBrains Mono');
      expect(out.baseSize, 17);
      expect(out.weight, 600);
    });
  });

  group('FontControls (controlled)', () {
    testWidgets('renders the font controls but NOT the colour controls',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pump(
        tester,
        FontControls(
          value: const AppearanceSettings(),
          onChanged: changes.add,
          showPreview: false,
        ),
      );

      expect(find.text('App font'), findsOneWidget);
      expect(find.text('Mono font'), findsOneWidget);
      expect(
          find.byType(Slider), findsNWidgets(3)); // base size + weight + scale
      // Colour-only sections must be absent — this is the typography half.
      expect(find.text('Preset'), findsNothing);
      expect(find.text('Seed colour'), findsNothing);
    });

    testWidgets('moving the base-size slider fires onChanged',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pump(
        tester,
        FontControls(
          value: const AppearanceSettings(),
          onChanged: changes.add,
          showPreview: false,
        ),
      );

      final Finder slider = find.byType(Slider).first;
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final Rect r = tester.getRect(slider);
      await tester.tapAt(Offset(r.right - 8, r.center.dy));
      await tester.pump();

      expect(changes, isNotEmpty);
      expect(changes.last.baseSize, greaterThan(13));
      expect(changes.last.baseSize, lessThanOrEqualTo(20));
    });

    testWidgets('a font-size edit leaves colour fields untouched',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      const AppearanceSettings seed = AppearanceSettings(
        presetName: 'Nord',
        seedHex: 'BD93F9',
        backgroundHex: '2E3440',
        foregroundHex: 'ECEFF4',
      );
      await _pump(
        tester,
        FontControls(
          value: seed,
          onChanged: changes.add,
          showPreview: false,
        ),
      );

      final Finder slider = find.byType(Slider).first;
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final Rect r = tester.getRect(slider);
      await tester.tapAt(Offset(r.right - 8, r.center.dy));
      await tester.pump();

      expect(changes, isNotEmpty);
      final AppearanceSettings out = changes.last;
      // Colour fields carried through unchanged.
      expect(out.presetName, 'Nord');
      expect(out.seedHex, 'BD93F9');
      expect(out.backgroundHex, '2E3440');
      expect(out.foregroundHex, 'ECEFF4');
    });

    testWidgets(
        'extraFontFamilies are surfaced (prepended) in the app-font picker',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      const String extra = 'ZZ Embedded Marker Font';
      await _pump(
        tester,
        FontControls(
          value: const AppearanceSettings(),
          onChanged: changes.add,
          extraFontFamilies: const <String>[extra],
          showPreview: false,
        ),
      );

      // Open the app-font picker and wait for its (real-async) font list.
      await _openPickerAndSettle(tester);

      // The injected family appears in the picker list even though fc-list
      // could never have enumerated it.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(extra), findsOneWidget);

      // Selecting it fires onChanged with that family as the app font.
      await tester.tap(find.text(extra));
      await tester.pump();
      expect(changes, isNotEmpty);
      expect(changes.last.appFont, extra);
    });
  });

  group('AppearancePane composition', () {
    testWidgets('renders both halves and a single combined preview',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pump(
        tester,
        AppearancePane(
          value: const AppearanceSettings(),
          onChanged: changes.add,
        ),
      );

      // Colour half + font half both present.
      expect(find.text('Preset'), findsOneWidget);
      expect(find.text('App font'), findsOneWidget);
      expect(
          find.byType(Slider), findsNWidgets(3)); // base size + weight + scale
      // Exactly one preview (the two halves suppress theirs).
      expect(find.text('Live preview'), findsOneWidget);
    });

    testWidgets('extraFontFamilies pass through to the picker',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      const String extra = 'QQ Pane Passthrough Font';
      await _pump(
        tester,
        AppearancePane(
          value: const AppearanceSettings(),
          onChanged: changes.add,
          extraFontFamilies: const <String>[extra],
          showPreview: false,
        ),
      );

      await _openPickerAndSettle(tester);

      expect(find.text(extra), findsOneWidget);
    });
  });
}
