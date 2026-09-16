// Reusable About dialog for desktop_kit apps.
//
// Version is INJECTED (via [VersionInfo]) — no package_info_plus dependency.
// Links are shown as selectable text only — no url_launcher dependency.
// "Open source licenses" action uses Flutter's built-in [showLicensePage].
library;

import 'package:flutter/material.dart';

import '../version/version_info.dart';

/// A self-contained section of content shown inside [showDesktopKitAbout].
///
/// Each section has a bold [title] and a [body] rendered as [SelectableText].
/// An optional [linkUrl] is shown as an additional selectable line beneath the
/// body so the user can copy it to a browser without needing url_launcher.
class AboutSection {
  /// Creates an [AboutSection].
  const AboutSection({
    required this.title,
    required this.body,
    this.linkUrl,
  });

  /// Section heading displayed in [TextTheme.labelLarge] with the primary colour.
  final String title;

  /// Section body rendered as [SelectableText].
  final String body;

  /// Optional URL shown as a [SelectableText] link beneath [body].
  /// No url_launcher — the user copies and opens it manually.
  final String? linkUrl;
}

/// Opens a scrollable [AlertDialog] showing the app's identity, version, and
/// content sections.
///
/// ### Parameters
///
/// - [appName] — required; shown as the dialog headline.
/// - [icon] — optional app icon widget displayed above [appName].
/// - [tagline] — optional one-line description beneath [appName].
/// - [version] — optional [VersionInfo]; its [VersionInfo.displayString] is
///   shown if non-empty.
/// - [serviceVersion] — optional future resolving to a service-side version
///   string; displayed via [FutureBuilder] while loading (shows `'…'`).
/// - [sections] — zero or more [AboutSection] items shown after the version
///   block.
/// - [applicationLegalese] — optional copyright / legalese string shown at
///   the bottom, passed through to [showLicensePage].
///
/// No platform-plugin imports: version is supplied by the caller.
/// No url_launcher: link URLs are shown as [SelectableText] only.
Future<void> showDesktopKitAbout(
  BuildContext context, {
  required String appName,
  Widget? icon,
  String? tagline,
  VersionInfo? version,
  Future<String>? serviceVersion,
  List<AboutSection> sections = const <AboutSection>[],
  String? applicationLegalese,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => _AboutDialogContent(
      appName: appName,
      icon: icon,
      tagline: tagline,
      version: version,
      serviceVersion: serviceVersion,
      sections: sections,
      applicationLegalese: applicationLegalese,
    ),
  );
}

// ── Private implementation ────────────────────────────────────────────────────

class _AboutDialogContent extends StatelessWidget {
  const _AboutDialogContent({
    required this.appName,
    this.icon,
    this.tagline,
    this.version,
    this.serviceVersion,
    this.sections = const <AboutSection>[],
    this.applicationLegalese,
  });

  final String appName;
  final Widget? icon;
  final String? tagline;
  final VersionInfo? version;
  final Future<String>? serviceVersion;
  final List<AboutSection> sections;
  final String? applicationLegalese;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return AlertDialog(
      title: _buildTitle(tt),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Version block ──────────────────────────────────────────
              if (_hasVersion) ...[
                _sectionLabel('Version', tt, cs),
                const SizedBox(height: 4),
                ..._versionRows(tt),
                const SizedBox(height: 16),
              ],

              // ── Content sections ───────────────────────────────────────
              for (final s in sections) ...[
                _sectionLabel(s.title, tt, cs),
                const SizedBox(height: 4),
                SelectableText(s.body, style: tt.bodyMedium),
                if (s.linkUrl != null) ...[
                  const SizedBox(height: 4),
                  SelectableText(
                    s.linkUrl!,
                    style: tt.bodySmall?.copyWith(
                      color: cs.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
              ],

              // ── Legalese ───────────────────────────────────────────────
              if (applicationLegalese != null) ...[
                SelectableText(
                  applicationLegalese!,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
              ],

              // ── License button ─────────────────────────────────────────
              OutlinedButton.icon(
                icon: const Icon(Icons.description_outlined),
                label: const Text('Open source licenses'),
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: appName,
                  applicationVersion: version?.displayString,
                  applicationLegalese: applicationLegalese,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  bool get _hasVersion {
    final vStr = version?.displayString ?? '';
    return vStr.isNotEmpty || serviceVersion != null;
  }

  List<Widget> _versionRows(TextTheme tt) {
    final rows = <Widget>[];
    final vStr = version?.displayString ?? '';
    if (vStr.isNotEmpty) {
      rows.add(_labeledRow('App', vStr, tt));
    }
    if (serviceVersion != null) {
      rows.add(
        FutureBuilder<String>(
          future: serviceVersion,
          builder: (context, snap) =>
              _labeledRow('Service', snap.data ?? '…', tt),
        ),
      );
    }
    return rows;
  }

  Widget _buildTitle(TextTheme tt) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[icon!, const SizedBox(height: 8)],
        Text(appName, style: tt.headlineSmall),
        if (tagline != null) ...[
          const SizedBox(height: 4),
          Text(tagline!, style: tt.bodySmall),
        ],
      ],
    );
  }

  Widget _sectionLabel(String label, TextTheme tt, ColorScheme cs) => Text(
        label,
        style: tt.labelLarge?.copyWith(color: cs.primary),
      );

  Widget _labeledRow(String label, String value, TextTheme tt) => Padding(
        padding: const EdgeInsets.only(left: 8, bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Text(label, style: tt.bodySmall),
            ),
            Expanded(
              child: SelectableText(value, style: tt.bodyMedium),
            ),
          ],
        ),
      );
}
