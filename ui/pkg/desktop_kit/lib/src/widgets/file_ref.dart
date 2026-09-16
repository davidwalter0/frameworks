/// FileRef widget — path display with tilde-home collapse,
/// optional copy-to-clipboard and reveal-in-file-manager actions.
///
/// Public symbols:
/// - [collapseTilde]: pure helper for collapsing `$HOME` → `~`.
/// - [FileRef]: a controlled path-display widget.
library;

import 'package:flutter/material.dart';

import '../host/host_env_default.dart';

/// Replaces a leading `$HOME` prefix in [path] with `~`.
///
/// [home] defaults to the host's home directory ([HostEnv.home]).  If [home]
/// is `null` or empty — which is always the case in a browser, where there is
/// no home directory to collapse against — or [path] does not start with
/// [home], the original [path] is returned unchanged.
///
/// Only a *leading* occurrence is replaced — the function never substitutes
/// `$HOME` that appears later in the path.
///
/// ```dart
/// collapseTilde('/home/alice/docs/notes.org'); // '~/docs/notes.org'
/// collapseTilde('/etc/hosts');                  // '/etc/hosts'
/// ```
String collapseTilde(String path, {String? home}) {
  final String resolvedHome = home ?? hostEnv.home ?? '';
  if (resolvedHome.isNotEmpty && path.startsWith(resolvedHome)) {
    return '~${path.substring(resolvedHome.length)}';
  }
  return path;
}

/// A controlled path-display widget.
///
/// Shows [path] as a single-line [Text] with [TextOverflow.ellipsis],
/// wrapped in a [Tooltip] showing the full unmodified path.
///
/// When [collapseHome] is `true` (the default) the leading `$HOME`
/// directory is replaced with `~` in the visible label via [collapseTilde].
/// The tooltip always shows the original full path regardless.
///
/// Optional trailing action buttons:
/// - [onCopyPath] → copy icon ([Icons.copy], tooltip `'Copy path'`).
/// - [onReveal]   → folder-open icon ([Icons.folder_open],
///   tooltip `'Show in file manager'`).
///
/// Both buttons are omitted when the corresponding callback is `null`.
class FileRef extends StatelessWidget {
  /// Creates a [FileRef].
  const FileRef({
    required this.path,
    this.collapseHome = true,
    this.onCopyPath,
    this.onReveal,
    this.style,
    super.key,
  });

  /// The file-system path to display.
  final String path;

  /// When `true` (default) replaces a leading `$HOME` with `~` in the
  /// visible label.
  final bool collapseHome;

  /// Optional callback fired when the user taps the copy-path button.
  ///
  /// When `null` the copy button is not rendered.
  final VoidCallback? onCopyPath;

  /// Optional callback fired when the user taps the reveal button.
  ///
  /// When `null` the reveal button is not rendered.
  final VoidCallback? onReveal;

  /// Optional text style for the path label.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final String displayPath = collapseHome ? collapseTilde(path) : path;

    final Widget label = Tooltip(
      message: path,
      child: Text(
        displayPath,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: label),
        if (onCopyPath != null)
          IconButton(
            onPressed: onCopyPath,
            icon: const Icon(Icons.copy),
            tooltip: 'Copy path',
            visualDensity: VisualDensity.compact,
          ),
        if (onReveal != null)
          IconButton(
            onPressed: onReveal,
            icon: const Icon(Icons.folder_open),
            tooltip: 'Show in file manager',
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}
