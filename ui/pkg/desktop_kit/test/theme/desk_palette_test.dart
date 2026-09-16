import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal app-style subclass, written the RECOMMENDED way: it overrides
/// [type] to return its own runtime type and provides its own `of`. That makes
/// it keyed by `_SubPalette` (not `DeskPalette`) in [ThemeData.extensions], so
/// it is the documented subtyping caveat in action — `extension<DeskPalette>()`
/// (hence [DeskPalette.of]) does NOT resolve it, only `extension<_SubPalette>()`
/// does. (Without the [type] override a subclass would instead be keyed by
/// `DeskPalette` and WOULD be returned by `extension<DeskPalette>()` while
/// `extension<_SubPalette>()` missed it — the reason the override is the safe
/// pattern.)
@immutable
class _SubPalette extends DeskPalette {
  final Color extra;
  const _SubPalette({
    required this.extra,
    required super.danger,
    required super.warn,
    required super.ok,
    required super.info,
    required super.accent,
    required super.alt,
    required super.muted,
    required super.neutral,
    required super.background,
  });

  @override
  Object get type => _SubPalette;

  static _SubPalette of(BuildContext context) =>
      Theme.of(context).extension<_SubPalette>() ?? sample;

  static const _SubPalette sample = _SubPalette(
    extra: Color(0xFF112233),
    danger: Color(0xFFF44336),
    warn: Color(0xFFFF9800),
    ok: Color(0xFF4CAF50),
    info: Color(0xFF2196F3),
    accent: Color(0xFF9C27B0),
    alt: Color(0xFF00BCD4),
    muted: Color(0xFF9E9E9E),
    neutral: Color(0xFF607D8B),
    background: Color(0xFF121212),
  );
}

void main() {
  bool legible(String fgHex, String bgHex) =>
      isLegibleOn(DeskTheme.hexToColor(fgHex)!, DeskTheme.hexToColor(bgHex)!);

  group('DeskPalette presets', () {
    test('preset colours match the borrowed colourway hexes', () {
      expect(DeskPalette.nord.info, const Color(0xFF81A1C1));
      expect(DeskPalette.nord.background, const Color(0xFF2E3440));
      expect(DeskPalette.dracula.accent, const Color(0xFFFF79C6));
      expect(DeskPalette.dracula.background, const Color(0xFF282A36));
      expect(DeskPalette.solarizedDark.info, const Color(0xFF268BD2));
      expect(DeskPalette.gruvboxDark.alt, const Color(0xFF8EC07C));
      expect(DeskPalette.standard.danger, const Color(0xFFF44336));
    });
  });

  group('DeskPalette.copyWith', () {
    test('round-trips: copyWith() with no args reproduces every field', () {
      // DeskPalette has no value `==` (it mirrors the donor NotifPalette, which
      // relies on const-instance identity), so compare field-wise, not by ==.
      const src = DeskPalette.nord;
      final c = src.copyWith();
      expect(c.danger, src.danger);
      expect(c.warn, src.warn);
      expect(c.ok, src.ok);
      expect(c.info, src.info);
      expect(c.accent, src.accent);
      expect(c.alt, src.alt);
      expect(c.muted, src.muted);
      expect(c.neutral, src.neutral);
      expect(c.background, src.background);
    });
    test('replaces only the named field', () {
      final p = DeskPalette.standard.copyWith(danger: const Color(0xFF000001));
      expect(p.danger, const Color(0xFF000001));
      expect(p.warn, DeskPalette.standard.warn);
      expect(p.background, DeskPalette.standard.background);
    });
  });

  group('DeskPalette.lerp', () {
    test('t=0 returns the start colours, t=1 the end colours', () {
      final at0 = DeskPalette.standard.lerp(DeskPalette.dracula, 0.0);
      final at1 = DeskPalette.standard.lerp(DeskPalette.dracula, 1.0);
      expect(at0.danger, DeskPalette.standard.danger);
      expect(at1.danger, DeskPalette.dracula.danger);
      expect(at1.background, DeskPalette.dracula.background);
    });
    test('midpoint blends each colour (neither endpoint)', () {
      final mid = DeskPalette.standard.lerp(DeskPalette.dracula, 0.5);
      expect(mid, isA<DeskPalette>());
      expect(mid.danger, isNot(DeskPalette.standard.danger));
      expect(mid.danger, isNot(DeskPalette.dracula.danger));
    });
    test('lerp against a non-DeskPalette returns this', () {
      expect(DeskPalette.nord.lerp(null, 0.5), DeskPalette.nord);
    });
  });

  group('DeskPalette.of', () {
    testWidgets('falls back to standard with no extension installed', (
      tester,
    ) async {
      late DeskPalette got;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              got = DeskPalette.of(ctx);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(got, same(DeskPalette.standard));
    });

    testWidgets('resolves an exact DeskPalette extension', (tester) async {
      late DeskPalette got;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [DeskPalette.nord]),
          home: Builder(
            builder: (ctx) {
              got = DeskPalette.of(ctx);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(got, DeskPalette.nord);
    });

    testWidgets('does NOT resolve a SUBCLASS extension (subtyping caveat)', (
      tester,
    ) async {
      // _SubPalette overrides `type` to return _SubPalette, so it is keyed by
      // _SubPalette in ThemeData.extensions: extension<DeskPalette>() misses it
      // and DeskPalette.of falls back to standard. This is the documented
      // reason core widgets must take colours as parameters, not call
      // DeskPalette.of and hope the app's subclass answers.
      late DeskPalette got;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [_SubPalette.sample]),
          home: Builder(
            builder: (ctx) {
              got = DeskPalette.of(ctx);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(got, same(DeskPalette.standard));
      // ...but the subclass IS resolvable by its own type, which is exactly what
      // its own `of` does (the recommended app pattern).
      late _SubPalette sub;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [_SubPalette.sample]),
          home: Builder(
            builder: (ctx) {
              sub = _SubPalette.of(ctx);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(sub.extra, const Color(0xFF112233));
    });
  });

  // Blue-swatch WCAG gating invariants (ported from alert-log's
  // blue_swatch_gating_test): the voicelab blues stay subject to the contrast
  // guard, and the swatch lists still carry them.
  group('blue swatches are present', () {
    test('background list carries the voicelab blues', () {
      final hexes = kBackgroundPresets.map((c) => c.hex).toSet();
      expect(
        hexes.containsAll({'EAF2FB', 'D6E4F2', '1E3A5F', '0A1929'}),
        isTrue,
      );
    });
    test('foreground list carries the voicelab blues', () {
      final hexes = kForegroundPresets.map((c) => c.hex).toSet();
      expect(
        hexes.containsAll({'0D47A1', '13315C', '5B8DEF', '9EC1F0'}),
        isTrue,
      );
    });
  });

  group('contrast guard isolates low-contrast blue pairs', () {
    test('light blue on pale blue is illegible (blue-on-blue → disabled)', () {
      expect(legible('9EC1F0', 'EAF2FB'), isFalse);
    });
    test('light blue on white is illegible (→ disabled)', () {
      expect(legible('9EC1F0', 'FFFFFF'), isFalse);
    });
    test('strong blue on white is legible (→ enabled)', () {
      expect(legible('0D47A1', 'FFFFFF'), isTrue);
    });
    test('medium blue on deep navy is legible (→ enabled)', () {
      expect(legible('5B8DEF', '0A1929'), isTrue);
    });
  });
}
