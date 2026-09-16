/// Settings persistence for desktop_kit apps.
///
/// Provides:
/// - [SettingsStore] — a generic, XDG-aware, debounced JSON config store whose
///   path is scoped per-app via an [appId] constructor argument;
/// - [SavedIndicator] — a controlled "Saved ✓" flash widget that listens to
///   [SettingsStore.savedAt];
/// - a configurable settings-presentation framework
///   ([SettingsPresentation], [SettingsCategory], [SettingsCategoryTile],
///   [openSettingsCategory], [resolvePresentation], and the pure
///   [encodePresentationPrefs] / [decodePresentationPrefs] helpers) that lets
///   each settings category be surfaced inline, as a popup, as a sliding
///   (bottom) sheet, pinned as a top/bottom span (via a
///   `desktop_kit_layout.dart` [SpanHost]) — persisted via the store above.
///
/// The anchored-popover mode and its host were removed: a popover was a
/// hand-inserted [OverlayEntry], so any dialog a category's content pushed
/// (the keymap editor's chord capture) rendered underneath the card that
/// opened it. Persisted `"popover"` migrates to the sliding sheet.
///
/// No state-management dependency: the store is a plain class, [SavedIndicator]
/// accepts a [ValueListenable], and [SettingsCategoryTile] is controlled (mode
/// in, change-callback out) so any notification source works.
library desktop_kit_settings;

export 'src/settings/saved_indicator.dart';
export 'src/settings/settings_backend.dart';
export 'src/settings/settings_backend_default.dart';
export 'src/settings/settings_category_list.dart';
export 'src/settings/settings_presentation.dart';
export 'src/settings/settings_presentation_menu_button.dart';
export 'src/settings/settings_store.dart';
