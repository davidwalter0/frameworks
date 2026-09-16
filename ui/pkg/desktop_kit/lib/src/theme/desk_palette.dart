// The base semantic colour palette shared by every consuming desktop app,
// carried as a [ThemeExtension] so any widget can read it from context. It holds
// the small SEMANTIC swatch that alert-log's NotifPalette and
// notekeep's OrgPalette have in common — danger/warn/ok/info/accent/alt/muted/
// neutral/background — and apps subclass it to add their domain colours
// (badges, org headings, etc.) while reusing the shared base.
//
// ── ThemeExtension subtyping caveat (READ THIS) ────────────────────────────
// [ThemeData.extensions] is a `Map<Object, ThemeExtension>` keyed by each
// extension's `type` getter, and `Theme.of(context).extension<T>()` is exactly
// `extensions[T]`. By default `ThemeExtension<T>.type` returns the *type
// parameter* `T` — NOT `runtimeType`. This makes subclassing subtle (verified
// against Flutter's theme_data.dart, this SDK):
//
//   * A subclass that does NOT re-bind the type parameter — `class NotifPalette
//     extends DeskPalette` (which is `ThemeExtension<DeskPalette>`) — inherits
//     `type == DeskPalette`. It is stored under the key `DeskPalette`, so
//     `extension<DeskPalette>()` (hence [DeskPalette.of]) DOES return the
//     subclass instance, while `extension<NotifPalette>()` returns null.
//   * A subclass that overrides `type` to return its own type — `@override
//     Object get type => NotifPalette;` — is stored under `NotifPalette`, so
//     `extension<NotifPalette>()` finds it and `extension<DeskPalette>()` does
//     NOT (it falls back to [standard]).
//
// RECOMMENDED app pattern: a subclass SHOULD override `type` to return its own
// runtime type AND provide its own static `of`. Then each palette is keyed by
// its own type unambiguously, an app may even install both a base [DeskPalette]
// and a subclass side by side, and [DeskPalette.of] reliably resolves only a
// true base [DeskPalette]. Consequences, all handled here:
//
//   (a) [copyWith] and [lerp] are overridable so a subclass returns ITS own
//       type — preserving the subclass (and its extra fields) through theme
//       transitions (animated theme lerps, copyWith edits) instead of silently
//       narrowing to a bare DeskPalette.
//   (b) [DeskPalette.of] resolves ONLY the extension stored under the exact key
//       `DeskPalette`. With the recommended override an app subclass is NOT
//       returned by it, so subclasses MUST provide their own static `of` that
//       looks up their own type (e.g.
//       `Theme.of(context).extension<NotifPalette>()`).
//   (c) Core widgets in this package therefore MUST NOT depend on
//       [DeskPalette.of] to obtain colours — they receive the colours they need
//       as plain parameters, so they work regardless of which palette subtype
//       (if any) the host app installed, and regardless of whether that subtype
//       overrode `type`.
library;

import 'package:flutter/material.dart';

import 'hct_tools.dart' show accentOn;

/// Base semantic colour palette shared across apps, attached to a theme as a
/// [ThemeExtension]. Subclass it to add domain-specific colours; the eight
/// semantic roles plus [background] stay common.
@immutable
class DeskPalette extends ThemeExtension<DeskPalette> {
  /// Danger / critical / security accent.
  final Color danger;

  /// Warning / caution accent.
  final Color warn;

  /// Success / OK / progress accent.
  final Color ok;

  /// Informational / normal accent.
  final Color info;

  /// Primary decorative accent.
  final Color accent;

  /// Secondary / alternate accent.
  final Color alt;

  /// Muted / low-emphasis tone.
  final Color muted;

  /// Neutral / system tone.
  final Color neutral;

  /// Signature background floor for the colourway (used by dark themes as the
  /// scaffold background; apps may ignore it in light mode).
  final Color background;

  /// Creates a palette; every semantic role plus [background] is required.
  const DeskPalette({
    required this.danger,
    required this.warn,
    required this.ok,
    required this.info,
    required this.accent,
    required this.alt,
    required this.muted,
    required this.neutral,
    required this.background,
  });

  /// Reads the active palette from context, falling back to [standard].
  ///
  /// Resolves ONLY the extension stored under the exact key `DeskPalette` (i.e.
  /// `Theme.of(context).extension<DeskPalette>()`). A subclass that overrides
  /// `type` (the recommended pattern — see the library-level caveat) is keyed by
  /// its OWN type, so this returns [standard] for it; such subclasses must
  /// define their own `of` (e.g. `extension<NotifPalette>()`). Conversely, a
  /// subclass that does NOT override `type` is keyed by `DeskPalette` and WOULD
  /// be returned here as its subclass instance. Core widgets avoid this ambiguity
  /// entirely by taking colours as parameters.
  static DeskPalette of(BuildContext context) =>
      Theme.of(context).extension<DeskPalette>() ?? standard;

  /// Returns a copy with the given fields replaced; omitted fields are kept.
  ///
  /// Overridable so a subclass can return its own type and preserve its extra
  /// fields. The return type is the [ThemeExtension] interface type so an
  /// override may legally widen it to the subclass.
  @override
  DeskPalette copyWith({
    Color? danger,
    Color? warn,
    Color? ok,
    Color? info,
    Color? accent,
    Color? alt,
    Color? muted,
    Color? neutral,
    Color? background,
  }) {
    return DeskPalette(
      danger: danger ?? this.danger,
      warn: warn ?? this.warn,
      ok: ok ?? this.ok,
      info: info ?? this.info,
      accent: accent ?? this.accent,
      alt: alt ?? this.alt,
      muted: muted ?? this.muted,
      neutral: neutral ?? this.neutral,
      background: background ?? this.background,
    );
  }

  /// Linearly interpolates toward [other] by [t].
  ///
  /// Overridable so a subclass can lerp its own extra fields; the base
  /// implementation returns `this` unchanged when [other] is not a
  /// [DeskPalette].
  @override
  DeskPalette lerp(covariant ThemeExtension<DeskPalette>? other, double t) {
    if (other is! DeskPalette) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return DeskPalette(
      danger: c(danger, other.danger),
      warn: c(warn, other.warn),
      ok: c(ok, other.ok),
      info: c(info, other.info),
      accent: c(accent, other.accent),
      alt: c(alt, other.alt),
      muted: c(muted, other.muted),
      neutral: c(neutral, other.neutral),
      background: c(background, other.background),
    );
  }

  /// Returns a copy of this palette whose eight CONTENT roles
  /// (danger/warn/ok/info/accent/alt/muted/neutral) are each retoned — hue- and
  /// chroma-preserving, via [accentOn] — to clear a WCAG contrast [target]
  /// (default 4.5) against the page background [bg]. The [background] field is
  /// left untouched: it is the colourway's signature floor, not a foreground
  /// role, and is never painted as text.
  ///
  /// This is the palette counterpart of [DeskTheme]'s scheme-level HCT retone:
  /// a colourway's fixed swatches (e.g. Nord's muted #616E88 at ~2.4:1 on its
  /// own #2E3440 page) are unguarded by the M3 scheme, so any widget reading a
  /// [DeskPalette] role directly can render illegibly low-contrast text on a page
  /// override. [DeskTheme] calls this when a background override is active so the
  /// attached palette is legible on the actual page. A role that already clears
  /// [target] is returned unchanged (perfect hue+chroma fidelity).
  ///
  /// Subtype-preserving: it routes through [copyWith], so an app's palette
  /// subclass keeps its own runtime type and its extra fields (which are copied
  /// through unretoned — a subclass that adds foreground roles needing the guard
  /// should override this to retone them too).
  ///
  /// Chosen as an INSTANCE method (rather than a free `guardPalette(p, bg)`)
  /// because the guard is intrinsic to the palette — it is discoverable on the
  /// type, reads as `palette.guardedFor(pageBg)` at the call site, and naturally
  /// preserves the subtype through [copyWith].
  DeskPalette guardedFor(Color bg, {double target = 4.5}) => copyWith(
        danger: accentOn(danger, bg, target: target),
        warn: accentOn(warn, bg, target: target),
        ok: accentOn(ok, bg, target: target),
        info: accentOn(info, bg, target: target),
        accent: accentOn(accent, bg, target: target),
        alt: accentOn(alt, bg, target: target),
        muted: accentOn(muted, bg, target: target),
        neutral: accentOn(neutral, bg, target: target),
      );

  // ── Presets ──────────────────────────────────────────────────────────────
  // Semantic-swatch hex values mirror alert-log's NotifPalette
  // presets for the shared fields; [background] is the colourway's signature
  // dark background (alert-log's preset bgHex). The "standard"
  // background is a neutral near-black floor (the Default preset forces no
  // background in light mode, so this only surfaces if a dark theme uses it).

  /// The default Material-tuned swatch — works in light AND dark.
  static const DeskPalette standard = DeskPalette(
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

  /// Nord colourway.
  static const DeskPalette nord = DeskPalette(
    danger: Color(0xFFBF616A),
    warn: Color(0xFFD08770),
    ok: Color(0xFFA3BE8C),
    info: Color(0xFF81A1C1),
    accent: Color(0xFFB48EAD),
    alt: Color(0xFF88C0D0),
    muted: Color(0xFF616E88),
    neutral: Color(0xFF5E81AC),
    background: Color(0xFF2E3440),
  );

  /// Dracula colourway.
  static const DeskPalette dracula = DeskPalette(
    danger: Color(0xFFFF5555),
    warn: Color(0xFFFFB86C),
    ok: Color(0xFF50FA7B),
    info: Color(0xFF8BE9FD),
    accent: Color(0xFFFF79C6),
    alt: Color(0xFFBD93F9),
    muted: Color(0xFF6272A4),
    neutral: Color(0xFF6272A4),
    background: Color(0xFF282A36),
  );

  /// Solarized Dark colourway.
  static const DeskPalette solarizedDark = DeskPalette(
    danger: Color(0xFFDC322F),
    warn: Color(0xFFCB4B16),
    ok: Color(0xFF859900),
    info: Color(0xFF268BD2),
    accent: Color(0xFF6C71C4),
    alt: Color(0xFF2AA198),
    muted: Color(0xFF586E75),
    neutral: Color(0xFF657B83),
    background: Color(0xFF002B36),
  );

  /// Gruvbox Dark colourway.
  static const DeskPalette gruvboxDark = DeskPalette(
    danger: Color(0xFFFB4934),
    warn: Color(0xFFFE8019),
    ok: Color(0xFFB8BB26),
    info: Color(0xFF83A598),
    accent: Color(0xFFD3869B),
    alt: Color(0xFF8EC07C),
    muted: Color(0xFF928374),
    neutral: Color(0xFF458588),
    background: Color(0xFF282828),
  );

  /// Catppuccin Mocha colourway. base #1E1E2E.
  static const DeskPalette catppuccinMocha = DeskPalette(
    danger: Color(0xFFF38BA8), // red
    warn: Color(0xFFFAB387), // peach
    ok: Color(0xFFA6E3A1), // green
    info: Color(0xFF89B4FA), // blue
    accent: Color(0xFFCBA6F7), // mauve
    alt: Color(0xFF94E2D5), // teal
    muted: Color(0xFF6C7086), // overlay0
    neutral: Color(0xFF585B70), // surface2
    background: Color(0xFF1E1E2E), // base
  );
}
