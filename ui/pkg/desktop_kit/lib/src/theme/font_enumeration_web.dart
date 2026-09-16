/// Host font enumeration in a browser — there is none.
///
/// A browser deliberately refuses to enumerate installed fonts: the full list
/// is a high-entropy fingerprinting vector, and the Local Font Access API that
/// would expose it is permission-gated and not broadly available. Returning an
/// empty list makes the caller fall back to the curated per-platform families,
/// which is the correct behaviour rather than a workaround.
///
/// The browser host grades `HostCapability.hostFonts` as `absent` and says so,
/// so the Appearance pane can explain why the picker is short instead of
/// looking broken.
library;

/// Always false — no executable is reachable from a browser.
bool isOnPath(String exe) => false;

/// Always empty — browsers do not expose installed font families.
Future<List<String>> enumerateHostFontFamilies() async => const <String>[];
