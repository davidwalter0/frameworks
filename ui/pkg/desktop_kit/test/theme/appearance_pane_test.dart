import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Asserts two [DeskPalette]s are field-equal across the nine roles. [DeskPalette]
/// uses identity equality (no `operator ==` — it is a subclass-friendly
/// ThemeExtension), so a `guardedFor(...)` copy can never be `==` a separately
/// built copy; this compares the roles directly instead.
void _expectSamePalette(DeskPalette? got, DeskPalette want) {
  expect(got, isNotNull);
  expect(got!.danger, want.danger);
  expect(got.warn, want.warn);
  expect(got.ok, want.ok);
  expect(got.info, want.info);
  expect(got.accent, want.accent);
  expect(got.alt, want.alt);
  expect(got.muted, want.muted);
  expect(got.neutral, want.neutral);
  expect(got.background, want.background);
}

/// Pump an [AppearancePane] with [settings], capturing every [onChanged] into
/// [out]. Forces light platform brightness so the effective-background maths
/// (and the contrast gate) are deterministic across hosts.
Future<void> _pumpPane(
  WidgetTester tester,
  AppearanceSettings settings,
  List<AppearanceSettings> out, {
  bool showPreview = true,
}) {
  return tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(platformBrightness: Brightness.light),
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AppearancePane(
              value: settings,
              showPreview: showPreview,
              onChanged: out.add,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  // ── AppearanceSettings value type ──────────────────────────────────────────

  group('AppearanceSettings defaults', () {
    test('the no-arg const value is the "nothing overridden" state', () {
      const AppearanceSettings s = AppearanceSettings();
      expect(s.presetName, 'Default');
      expect(s.mode, ThemeMode.system);
      expect(s.seedHex, '');
      expect(s.backgroundHex, '');
      expect(s.foregroundHex, '');
      expect(s.appFont, '');
      expect(s.monoFont, '');
      expect(s.baseSize, 13);
      expect(s.weight, 400);
      expect(s.uiScale, 1.0);
    });
  });

  group('AppearanceSettings.copyWith', () {
    test('replaces only the given fields', () {
      const AppearanceSettings base = AppearanceSettings(presetName: 'Nord');
      final AppearanceSettings s = base.copyWith(
        mode: ThemeMode.dark,
        appFont: 'Cantarell',
        baseSize: 16,
        weight: 700,
      );
      expect(s.presetName, 'Nord'); // kept
      expect(s.mode, ThemeMode.dark);
      expect(s.appFont, 'Cantarell');
      expect(s.baseSize, 16);
      expect(s.weight, 700);
    });
  });

  group('AppearanceSettings equality', () {
    test('== and hashCode agree for equal field sets', () {
      const AppearanceSettings a = AppearanceSettings(
        presetName: 'Dracula',
        mode: ThemeMode.light,
        seedHex: 'BD93F9',
        baseSize: 15,
      );
      const AppearanceSettings b = AppearanceSettings(
        presetName: 'Dracula',
        mode: ThemeMode.light,
        seedHex: 'BD93F9',
        baseSize: 15,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(a.copyWith(weight: 900)));
    });
  });

  group('AppearanceSettings fromMap / toMap', () {
    test('round-trips a fully-populated value', () {
      const AppearanceSettings original = AppearanceSettings(
        presetName: 'Gruvbox Dark',
        mode: ThemeMode.dark,
        seedHex: '8EC07C',
        backgroundHex: '282828',
        foregroundHex: 'EBDBB2',
        appFont: 'Cantarell',
        monoFont: 'JetBrains Mono',
        baseSize: 17,
        weight: 600,
        uiScale: 1.25,
      );
      final AppearanceSettings restored =
          AppearanceSettings.fromMap(original.toMap());
      expect(restored, original);
    });

    test('toMap stores the mode by its enum name', () {
      const AppearanceSettings s = AppearanceSettings(mode: ThemeMode.light);
      expect(s.toMap()['mode'], 'light');
    });

    test('defensive: a non-map yields all defaults', () {
      expect(AppearanceSettings.fromMap(null), const AppearanceSettings());
      expect(AppearanceSettings.fromMap('garbage'), const AppearanceSettings());
      expect(AppearanceSettings.fromMap(42), const AppearanceSettings());
    });

    test('defensive: wrong-typed / missing fields fall back to defaults', () {
      final AppearanceSettings s = AppearanceSettings.fromMap(<String, dynamic>{
        'presetName': 123, // wrong type → default
        'mode': 'not-a-mode', // unknown → default (system)
        'baseSize': '18', // numeric string → parsed
        'weight': 500.0, // num → int
        // seedHex / fonts absent → defaults
      });
      expect(s.presetName, 'Default');
      expect(s.mode, ThemeMode.system);
      expect(s.baseSize, 18);
      expect(s.weight, 500);
      expect(s.seedHex, '');
      expect(s.appFont, '');
    });
  });

  group('AppearanceSettings.uiScale defensive fromMap', () {
    test('round-trips through toMap/fromMap', () {
      const AppearanceSettings original = AppearanceSettings(uiScale: 1.3);
      expect(
        AppearanceSettings.fromMap(original.toMap()).uiScale,
        closeTo(1.3, 1e-9),
      );
    });

    test('a missing key falls back to the 1.0 default', () {
      final AppearanceSettings s = AppearanceSettings.fromMap(
        <String, dynamic>{'presetName': 'Nord'},
      );
      expect(s.uiScale, 1.0);
    });

    test('an out-of-range value is clamped into [0.8, 1.5]', () {
      expect(
        AppearanceSettings.fromMap(<String, dynamic>{'uiScale': 3.0}).uiScale,
        1.5,
      );
      expect(
        AppearanceSettings.fromMap(<String, dynamic>{'uiScale': 0.1}).uiScale,
        0.8,
      );
    });

    test('a malformed (non-numeric) value falls back to the 1.0 default', () {
      expect(
        AppearanceSettings.fromMap(<String, dynamic>{'uiScale': 'huge'})
            .uiScale,
        1.0,
      );
    });
  });

  // ── AppearanceSettings.toDisplayConfig — the content-text bridge ──────────
  //
  // buildAppearanceTheme does NOT thread monoFont/baseSize/weight into the
  // ThemeData it builds (see that function's "SCOPE" doc) — toDisplayConfig
  // is the supported way for a host to apply them to its own content text.
  // These tests pin the mapping so the bridge cannot silently drift out of
  // step with AppearanceSettings as fields are added to one type and not
  // the other.

  group('AppearanceSettings.toDisplayConfig', () {
    test('the default settings value maps to the default DisplayConfig', () {
      // DisplayConfig has no operator== (see display_config_test.dart, which
      // likewise always compares fields), so compare field-by-field against
      // the documented defaults rather than whole-object equality.
      const AppearanceSettings s = AppearanceSettings();
      final DisplayConfig d = s.toDisplayConfig();
      expect(d.appFont, '');
      expect(d.monoFont, '');
      expect(d.baseSize, 13);
      expect(d.weight, 400);
      expect(d.uiScale, 1.0);
    });

    test('every content-text field round-trips unchanged', () {
      const AppearanceSettings s = AppearanceSettings(
        // Colour/preset fields deliberately included to prove they are NOT
        // carried into DisplayConfig — it has no such fields to carry them
        // into; only the five below exist on both types.
        presetName: 'Nord',
        seedHex: 'FF0000',
        backgroundHex: '2E3440',
        foregroundHex: 'ECEFF4',
        appFont: 'Cantarell',
        monoFont: 'JetBrains Mono',
        baseSize: 17,
        weight: 600,
        uiScale: 1.25,
      );
      final DisplayConfig d = s.toDisplayConfig();
      expect(d.appFont, 'Cantarell');
      expect(d.monoFont, 'JetBrains Mono');
      expect(d.baseSize, 17);
      expect(d.weight, 600);
      expect(d.uiScale, 1.25);
    });

    test(
        'feeds DisplayConfig.bodyStyle/monoStyle exactly as a hand-built '
        'DisplayConfig would', () {
      // Proves the bridge is not just field-copying in isolation — the
      // result drives the SAME derived styles (fontSize/fontWeight/
      // fontVariations) a host actually paints text with.
      const AppearanceSettings s = AppearanceSettings(
        appFont: 'Cantarell',
        monoFont: 'JetBrains Mono',
        baseSize: 16,
        weight: 700,
      );
      final DisplayConfig viaBridge = s.toDisplayConfig();
      const DisplayConfig handBuilt = DisplayConfig(
        appFont: 'Cantarell',
        monoFont: 'JetBrains Mono',
        baseSize: 16,
        weight: 700,
      );
      expect(viaBridge.bodyStyle, handBuilt.bodyStyle);
      expect(viaBridge.monoStyle, handBuilt.monoStyle);
    });
  });

  // ── buildAppearanceTheme ───────────────────────────────────────────────────

  group('buildAppearanceTheme', () {
    test('attaches the named preset palette as a ThemeExtension', () {
      const AppearanceSettings s = AppearanceSettings(presetName: 'Nord');
      final ThemeData theme = buildAppearanceTheme(s, Brightness.dark);
      // The Nord preset carries a signature dark background (#2E3440), so an
      // override is active and DeskTheme now attaches the palette GUARDED for
      // that page (deliverable C) — retoned so every role is legible on it,
      // instead of the raw preset whose muted/neutral fail the floor. The
      // colourway still plumbs through; it is the page-guarded form of it.
      final Color page = DeskTheme.hexToColor('2E3440')!;
      _expectSamePalette(
        theme.extension<DeskPalette>(),
        DeskPalette.nord.guardedFor(page),
      );
    });

    test('honours the requested brightness', () {
      const AppearanceSettings s = AppearanceSettings();
      expect(
        buildAppearanceTheme(s, Brightness.dark).brightness,
        Brightness.dark,
      );
      expect(
        buildAppearanceTheme(s, Brightness.light).brightness,
        Brightness.light,
      );
    });

    test('an explicit palette overrides the preset palette', () {
      const AppearanceSettings s = AppearanceSettings(presetName: 'Nord');
      final ThemeData theme = buildAppearanceTheme(
        s,
        Brightness.dark,
        palette: DeskPalette.dracula,
      );
      // The explicit Dracula palette still wins over the Nord preset's palette;
      // but the Nord preset's page (#2E3440) is active, so the attached value is
      // Dracula GUARDED for that page (deliverable C), not the raw Dracula
      // palette. Asserting the guarded form keeps the "explicit palette wins"
      // contract while reflecting the page-legibility retone.
      final Color page = DeskTheme.hexToColor('2E3440')!;
      _expectSamePalette(
        theme.extension<DeskPalette>(),
        DeskPalette.dracula.guardedFor(page),
      );
    });

    test('applies the app font + carries the seed override into the scheme',
        () {
      const AppearanceSettings s = AppearanceSettings(
        appFont: 'Cantarell',
        seedHex: 'FF0000',
      );
      final ThemeData theme = buildAppearanceTheme(s, Brightness.light);
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Cantarell');
      // A red seed yields a non-default primary tone (sanity that seed flows).
      expect(theme.colorScheme.brightness, Brightness.light);
    });

    test('falls back to the preset seed when no seed override is set', () {
      // Selecting a colourway must re-tint the M3 chrome, not just swap the
      // semantic palette: with an empty seedHex the scheme must derive from
      // the preset's signature seed, not the global default. The preset's
      // signature BACKGROUND applies too, and Nord's page is dark, so
      // DeskTheme derives a DARK scheme even under a light request
      // (brightness follows the page) — compare dark-seeded expectations.
      const AppearanceSettings nord = AppearanceSettings(presetName: 'Nord');
      final ColorScheme got =
          buildAppearanceTheme(nord, Brightness.light).colorScheme;
      final ColorScheme fromNordSeed = ColorScheme.fromSeed(
        seedColor: presetByName('Nord').seed,
        brightness: Brightness.dark,
      );
      final ColorScheme fromDefaultSeed = ColorScheme.fromSeed(
        seedColor: presetByName('Default').seed,
        brightness: Brightness.dark,
      );
      expect(got.primary, fromNordSeed.primary);
      expect(got.primary, isNot(fromDefaultSeed.primary));
    });

    test('an explicit seed override still wins over the preset seed', () {
      const AppearanceSettings s = AppearanceSettings(
        presetName: 'Nord',
        seedHex: 'FF0000',
      );
      final ColorScheme got =
          buildAppearanceTheme(s, Brightness.light).colorScheme;
      // Nord's dark signature background still applies (only the seed was
      // overridden), so the derived scheme is dark.
      final ColorScheme fromRed = ColorScheme.fromSeed(
        seedColor: const Color(0xFFFF0000),
        brightness: Brightness.dark,
      );
      expect(got.primary, fromRed.primary);
    });
  });

  // ── AppearancePane widget — controlled callbacks ───────────────────────────

  group('AppearancePane (controlled)', () {
    testWidgets('renders preset chips, brightness segments and sliders',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pumpPane(tester, const AppearanceSettings(), changes);

      expect(find.text('Preset'), findsOneWidget);
      expect(find.text('Nord'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(
          find.byType(Slider), findsNWidgets(3)); // base size + weight + scale
      expect(find.text('Live preview'), findsOneWidget);
    });

    testWidgets('tapping a preset chip fires onChanged with that preset',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pumpPane(tester, const AppearanceSettings(), changes);

      await tester.tap(find.text('Dracula'));
      await tester.pump();

      expect(changes, isNotEmpty);
      expect(changes.last.presetName, 'Dracula');
    });

    testWidgets('selecting the Dark brightness segment fires onChanged',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pumpPane(tester, const AppearanceSettings(), changes);

      await tester.tap(find.text('Dark'));
      await tester.pump();

      expect(changes, isNotEmpty);
      expect(changes.last.mode, ThemeMode.dark);
    });

    testWidgets('tapping a background swatch fires onChanged with its hex',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pumpPane(tester, const AppearanceSettings(), changes);

      // The Nord background swatch (#2E3440) — addressed by its tooltip.
      await tester.tap(find.byTooltip('Nord • #2E3440'));
      await tester.pump();

      expect(changes, isNotEmpty);
      expect(changes.last.backgroundHex, '2E3440');
    });

    testWidgets('a low-contrast foreground swatch is disabled (no onChanged)',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      // Force a WHITE background so a white text swatch is illegible and a
      // black one is legible — deterministic, host-independent.
      await _pumpPane(
        tester,
        const AppearanceSettings(
          mode: ThemeMode.light,
          backgroundHex: 'FFFFFF',
        ),
        changes,
      );

      // White-on-white: gated off → tooltip carries the low-contrast message,
      // and tapping it must NOT fire onChanged.
      final Finder whiteFg =
          find.byTooltip('White — low contrast on current background');
      expect(whiteFg, findsOneWidget);
      await tester.tap(whiteFg, warnIfMissed: false);
      await tester.pump();
      expect(changes, isEmpty);

      // Black-on-white: legible → enabled; tapping it fires onChanged.
      await tester.tap(find.byTooltip('Black • #000000'));
      await tester.pump();
      expect(changes, isNotEmpty);
      expect(changes.last.foregroundHex, '000000');
    });

    testWidgets('moving the base-size slider fires onChanged',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pumpPane(tester, const AppearanceSettings(), changes);

      // Tap near the right edge of the (discrete) base-size slider: this jumps
      // the value toward max and fires onChanged deterministically. Scroll it
      // into view first — off-screen taps are dropped in the test viewport.
      final Finder slider = find.byType(Slider).first;
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final Rect r = tester.getRect(slider);
      await tester.tapAt(Offset(r.right - 8, r.center.dy));
      await tester.pump();

      expect(changes, isNotEmpty);
      // Base size only ever moves within its 10..20 range, and moving right
      // raises it above the 13 default.
      expect(changes.last.baseSize, greaterThan(13));
      expect(changes.last.baseSize, lessThanOrEqualTo(20));
    });

    testWidgets('renders a UI-scale slider labelled with a percent',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pumpPane(tester, const AppearanceSettings(), changes);

      // The section label above the slider carries the live percent value —
      // the Slider's own `label` bubble only appears while actively dragged.
      expect(find.text('UI scale — 100%'), findsOneWidget);
    });

    testWidgets('moving the UI-scale slider fires onChanged with the update',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pumpPane(tester, const AppearanceSettings(), changes);

      // Three sliders in document order: base size, weight, UI scale.
      final Finder slider = find.byType(Slider).at(2);
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final Rect r = tester.getRect(slider);
      await tester.tapAt(Offset(r.right - 8, r.center.dy));
      await tester.pump();

      expect(changes, isNotEmpty);
      // UI scale only ever moves within its 0.8..1.5 range, and moving right
      // raises it above the 1.0 default.
      expect(changes.last.uiScale, greaterThan(1.0));
      expect(changes.last.uiScale, lessThanOrEqualTo(1.5));
    });

    testWidgets(
        'the live preview still renders baseSize/weight/monoFont after '
        'switching to toDisplayConfig — the dedup did not change behaviour',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      const AppearanceSettings settings = AppearanceSettings(
        monoFont: 'JetBrains Mono',
        baseSize: 18,
        weight: 700,
      );
      await _pumpPane(tester, settings, changes);

      final Text body = tester.widget<Text>(
        find.text('The quick brown fox jumps over the lazy dog.'),
      );
      expect(body.style?.fontSize, 18);
      expect(body.style?.fontWeight, FontWeight.w700);

      final Text mono = tester.widget<Text>(
        find.text('const sha = 0xDEADBEEF; // mono 0123456789'),
      );
      expect(mono.style?.fontFamily, 'JetBrains Mono');
      expect(mono.style?.fontSize, 17, // DisplayConfig.monoStyle: baseSize-1
          reason: 'buildAppearanceTheme never sees monoFont/baseSize/weight '
              '— this can only render correctly because the preview builds '
              'a DisplayConfig from them (now via settings.toDisplayConfig, '
              'a dedup of what this widget already did by hand — this test '
              'guards that the dedup kept the same behaviour)');
    });

    testWidgets('showPreview:false hides the live preview block',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pumpPane(
        tester,
        const AppearanceSettings(),
        changes,
        showPreview: false,
      );
      expect(find.text('Live preview'), findsNothing);
    });

    testWidgets('opening the app-font picker shows the searchable dialog',
        (WidgetTester tester) async {
      final List<AppearanceSettings> changes = <AppearanceSettings>[];
      await _pumpPane(tester, const AppearanceSettings(), changes);

      // Two "Pick…" buttons (app + mono); open the first. Do NOT pumpAndSettle:
      // the font list loads off-isolate behind a CircularProgressIndicator that
      // never settles — just advance frames past the dialog open transition.
      final Finder pick = find.text('Pick…').first;
      await tester.ensureVisible(pick);
      await tester.pump();
      await tester.tap(pick);
      await tester.pump(); // start the open transition
      await tester.pump(const Duration(milliseconds: 350)); // finish it

      // The searchable dialog is up: the unique search hint + Cancel action
      // identify it (the "App font" title text also appears as the page's
      // section label, so it is not a unique marker).
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget); // the search box
      expect(find.text('Search fonts…'), findsOneWidget); // search field hint
      expect(find.text('Cancel'), findsOneWidget);
    });
  });
}
