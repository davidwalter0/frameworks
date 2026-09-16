/// Version information for desktop_kit apps.
///
/// Provides [VersionInfo] — an immutable value object holding a [version],
/// [commit], and [date] string, with a [VersionInfo.displayString] getter that
/// assembles a human-readable summary and omits empty fields automatically.
///
/// The runtime version source (package_info_plus, a D-Bus response, or a
/// compile-time constant) is always injected by the app; this library carries
/// no platform-plugin dependency.
library desktop_kit_version;

export 'src/version/version_info.dart';
