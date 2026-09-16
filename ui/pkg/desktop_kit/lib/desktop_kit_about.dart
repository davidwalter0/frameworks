/// About dialog for desktop_kit apps.
///
/// Provides [showDesktopKitAbout] — a function that opens a scrollable
/// [AlertDialog] showing the app's name, optional icon/tagline, injected
/// [VersionInfo], an optional future-based service version, zero or more
/// [AboutSection] content blocks, and an "Open source licenses" button backed
/// by Flutter's built-in [showLicensePage].
///
/// No url_launcher dependency: link URLs in [AboutSection.linkUrl] are shown
/// as [SelectableText] only.
/// No package_info_plus dependency: version is supplied by the caller via
/// [VersionInfo].
///
/// Also provides bundled-font licensing: [BundledFont] declares a font shipped
/// as an asset together with its licence and that licence's URL,
/// [registerBundledFontLicenses] puts the text into `showLicensePage` (Flutter
/// registers pub packages' licences automatically but never an asset's), and
/// [bundledFontsSection] names them in the dialog itself. [readFontName] reads
/// the licence fields back out of the font binary so an app can TEST its
/// declaration instead of trusting it — the fields are routinely stripped by
/// subsetting.
library desktop_kit_about;

export 'src/about/about_dialog.dart';
export 'src/about/bundled_fonts.dart';
export 'src/about/font_name_table.dart';
