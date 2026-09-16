// Pure value object representing build-time version information.
//
// The version source (package_info_plus, D-Bus, a --version subprocess, or a
// compile-time constant) is always INJECTED by the application.  This library
// carries no platform-plugin dependency so any app can consume it regardless
// of its state-management or plugin choices.
library;

/// Immutable build-version descriptor.
///
/// All three fields default to empty strings so callers can always construct a
/// [VersionInfo] without knowing which fields are available at compile time.
///
/// Use [displayString] to produce a human-readable summary that omits empty
/// parts automatically.
///
/// ```dart
/// const info = VersionInfo(version: '1.2.3', commit: 'abc1234', date: '2024-01-01');
/// print(info.displayString); // "1.2.3 (abc1234) built 2024-01-01"
/// ```
class VersionInfo {
  /// Creates a [VersionInfo] with the given fields.
  ///
  /// Any field may be omitted; omitted fields default to `''` and are excluded
  /// from [displayString].
  const VersionInfo({
    this.version = '',
    this.commit = '',
    this.date = '',
  });

  /// The semver / tag portion of the version string (e.g. `'1.2.3'`).
  final String version;

  /// Short git commit hash (e.g. `'abc1234'`). May be empty.
  final String commit;

  /// Build date in any human-readable format (e.g. `'2024-01-15'`). May be empty.
  final String date;

  // ── Factories ─────────────────────────────────────────────────────────────

  /// Deserializes from a plain map (e.g. from a JSON response or D-Bus call).
  ///
  /// Missing or non-string values fall back to `''` — never throws.
  factory VersionInfo.fromMap(Map<String, dynamic> map) {
    String str(String key) {
      final v = map[key];
      return v is String ? v : '';
    }

    return VersionInfo(
      version: str('version'),
      commit: str('commit'),
      date: str('date'),
    );
  }

  // ── Display ───────────────────────────────────────────────────────────────

  /// Returns a human-readable version string, omitting empty fields.
  ///
  /// Examples:
  /// - All fields: `'1.2.3 (abc1234) built 2024-01-15'`
  /// - No commit:  `'1.2.3 built 2024-01-15'`
  /// - Version only: `'1.2.3'`
  /// - All empty:  `''`
  String get displayString {
    final parts = <String>[];
    if (version.isNotEmpty) parts.add(version);
    if (commit.isNotEmpty) parts.add('($commit)');
    if (date.isNotEmpty) parts.add('built $date');
    return parts.join(' ');
  }

  @override
  String toString() => displayString;
}
