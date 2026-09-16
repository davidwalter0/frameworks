/// CLIPBOARD selection helpers (Ctrl+C / Ctrl+V).
///
/// [setClipboard] writes to the OS clipboard via Flutter's platform channel,
/// and [readClipboard] is its symmetric read.  [copyToClipboard] wraps the
/// write with a SnackBar acknowledgement so every call site gets consistent
/// "Copied …" feedback without re-implementing it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Writes [text] to the system CLIPBOARD selection.
///
/// This is the Ctrl+C / Ctrl+V clipboard that Flutter's [Clipboard] API
/// covers on all platforms.  Silently no-ops when [text] is empty, because
/// clobbering the clipboard with nothing is almost never intentional.
Future<void> setClipboard(String text) async {
  if (text.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: text));
}

/// Reads the system CLIPBOARD selection and returns its text.
///
/// This is the symmetric read for [setClipboard]: it pulls the plain-text
/// payload from the Ctrl+C / Ctrl+V clipboard via Flutter's [Clipboard] API.
/// Returns `null` when the clipboard is empty or holds no plain text (so an
/// empty-string clipboard and an absent one are both reported as `null`,
/// matching how the rest of desktop_kit treats "nothing here").
Future<String?> readClipboard() async {
  final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
  final String? text = data?.text;
  if (text == null || text.isEmpty) return null;
  return text;
}

/// Writes [text] to the CLIPBOARD selection and shows a SnackBar.
///
/// The SnackBar message is `'Copied <label>'` when a [label] is provided,
/// or `'Copied <N> chars'` (where N = [text].length) when it is omitted.
///
/// The [context] must be mounted when this method is called.  If no
/// [ScaffoldMessenger] is in scope (e.g. in a bare test pump that has no
/// [Scaffold]), the clipboard is still written but the SnackBar is silently
/// skipped rather than throwing.
///
/// Example:
/// ```dart
/// await copyToClipboard(context, selectedText, label: 'path');
/// ```
Future<void> copyToClipboard(
  BuildContext context,
  String text, {
  String? label,
}) async {
  await setClipboard(text);

  // Guard: widget may have been disposed between the await and here.
  if (!context.mounted) return;

  // Only show a SnackBar when there is actually a Scaffold registered in the
  // tree.  ScaffoldMessenger.maybeOf returns non-null even without a Scaffold
  // (MaterialApp installs one), but showSnackBar asserts `_scaffolds.isNotEmpty`
  // — so we must gate on Scaffold.maybeOf to avoid the assertion.
  if (Scaffold.maybeOf(context) == null) return;

  final String message =
      label != null ? 'Copied $label' : 'Copied ${text.length} chars';

  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));
}
