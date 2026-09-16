import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'about_dialog.dart' show AboutSection;

/// A font shipped inside the application bundle, with the licence it is
/// distributed under and the URL that licence names.
///
/// ## Why the URL is a field
///
/// Flutter auto-registers the `LICENSE` of every **pub package**, but not
/// licence text shipped as a plain **asset** — and bundled fonts are assets, so
/// without wiring their licences never reach `showLicensePage` at all.
/// [registerBundledFontLicenses] closes that half.
///
/// The other half is this: SIL OFL 1.1 clause 2 requires the copyright notice
/// and licence to travel with every copy, and permits them to live in a
/// stand-alone file, a human-readable header, or a machine-readable metadata
/// field — "as long as those fields can be easily viewed by the user." A
/// licence page buried behind two taps satisfies that weakly; naming the
/// licence AND its canonical URL directly in the About dialog satisfies it
/// plainly, and gives a reader somewhere to go that is not this application.
///
/// **The URL is per font, not per family of fonts.** Sarasa Gothic's name
/// table points at `https://openfontlicense.org/` while Klee One's points at
/// `https://scripts.sil.org/OFL` — both OFL 1.1, different canonical homes. A
/// single hardcoded URL would be wrong for one of them, which is why this is
/// declared alongside each font rather than fixed in the dialog.
@immutable
class BundledFont {
  /// Creates a bundled-font declaration.
  const BundledFont({
    required this.family,
    required this.licence,
    required this.licenceUrl,
    required this.assets,
    this.copyright,
  });

  /// Font family as the user would recognise it, e.g. `'Klee One'`.
  final String family;

  /// Short licence name, e.g. `'SIL Open Font License 1.1'`.
  final String licence;

  /// The licence's canonical URL — the font's `name` table ID 14 where the
  /// font carries one.
  ///
  /// Verify rather than trust this: a font whose ID 14 says something else, or
  /// nothing at all, makes the About dialog assert something untrue. See
  /// `test/about/bundled_fonts_test.dart` for a check that reads the field out
  /// of the font binary and compares.
  final String licenceUrl;

  /// Bundle asset paths whose contents form this entry's licence text,
  /// concatenated in order.
  ///
  /// Some upstreams ship one file carrying both the copyright notice and the
  /// full licence body; others ship an attribution notice only, with the body
  /// left to the font's `name` table. The latter pairs its sidecar with a
  /// canonical OFL copy, which is why this is a list rather than one path.
  final List<String> assets;

  /// Optional copyright line, shown in the About section when present.
  final String? copyright;
}

/// Registers every declared font's licence text with Flutter's
/// [LicenseRegistry], so it appears in `showLicensePage`.
///
/// Call once from `main()` before `runApp`. Calling it twice lists every
/// licence twice — it is deliberately not idempotent, because a silent
/// de-duplication would hide a double-registration rather than make it
/// obvious.
void registerBundledFontLicenses(List<BundledFont> fonts) {
  LicenseRegistry.addLicense(() => _entries(fonts));
}

Stream<LicenseEntry> _entries(List<BundledFont> fonts) async* {
  for (final BundledFont f in fonts) {
    final List<String> parts = <String>[];
    for (final String asset in f.assets) {
      parts.add(await rootBundle.loadString(asset));
    }
    yield LicenseEntryWithLineBreaks(
      <String>['${f.family} (font)'],
      parts.join('\n\n'),
    );
  }
}

/// Builds the About dialog section naming every bundled font, its licence and
/// that licence's URL.
///
/// Returns `null` when [fonts] is empty, so a caller can splat it into a
/// section list without branching:
///
/// ```dart
/// sections: <AboutSection>[
///   ...myMainSections,
///   ?bundledFontsSection(kMyFonts),
/// ]
/// ```
///
/// Only ONE url is carried by [AboutSection.linkUrl]. When the fonts disagree
/// — which they do as soon as an OFL font from a newer upstream sits beside an
/// older one — each font's URL is written into the body instead, and the link
/// line is left off rather than silently promoting one font's URL to stand for
/// all of them.
AboutSection? bundledFontsSection(
  List<BundledFont> fonts, {
  String title = 'Bundled fonts',
}) {
  if (fonts.isEmpty) return null;

  final Set<String> urls = <String>{
    for (final BundledFont f in fonts) f.licenceUrl
  };
  final bool oneUrl = urls.length == 1;

  final StringBuffer b = StringBuffer();
  for (int i = 0; i < fonts.length; i++) {
    final BundledFont f = fonts[i];
    if (i > 0) b.writeln();
    b.write('${f.family} — ${f.licence}');
    if (f.copyright != null) {
      b.write('\n${f.copyright}');
    }
    if (!oneUrl) {
      b.write('\n${f.licenceUrl}');
    }
  }
  b.write('\n\nFull licence text: “Open source licenses”, below.');

  return AboutSection(
    title: title,
    body: b.toString(),
    linkUrl: oneUrl ? urls.first : null,
  );
}
