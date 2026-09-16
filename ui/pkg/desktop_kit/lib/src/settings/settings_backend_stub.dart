/// Fallback [SettingsBackend] for hosts with neither `dart:io` nor a browser
/// storage API.
///
/// Reached only when a target satisfies neither conditional-import branch in
/// `settings_backend_default.dart`. Settings still work for the session; they
/// simply do not survive a restart, and [MemorySettingsBackend.persists] is
/// false so a host can say so rather than quietly forgetting the user's
/// preferences.
library;

import 'settings_backend.dart';

/// Creates the in-memory backend. Shares its signature with the io and web
/// variants so the conditional import resolves to one call shape.
SettingsBackend createSettingsBackend({
  required String appId,
  required String fileName,
  String? overridePath,
}) =>
    MemorySettingsBackend();
