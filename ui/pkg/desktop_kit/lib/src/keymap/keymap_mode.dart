// Keymap mode and Meta-key enums for the Emacs/CUA keymap engine.
//
// These are the foundational types: [KeymapMode] selects Emacs vs CUA
// bindings; [MetaKey] selects which physical key carries the Emacs Meta
// modifier. Both apps (notekeep, voicelab) share this set, so the full
// four-value MetaKey from voicelab is carried here even though notekeep
// only uses [MetaKey.alt].
library;

/// Which key binding scheme is active in the editor.
enum KeymapMode {
  cua,
  emacs;

  /// Human-readable label, e.g. displayed in a toolbar chip.
  String get label => switch (this) {
        KeymapMode.cua => 'CUA',
        KeymapMode.emacs => 'Emacs',
      };

  /// Stable wire token for persistence — same as [Object.name].
  String get jsonValue => name;

  /// Parse a persisted [jsonValue]. Unknown or legacy tokens (including
  /// `null`) fall back to [KeymapMode.emacs], the editor's historical mode,
  /// so a forgotten/renamed value never silently strands a user on a mode
  /// they didn't choose.
  static KeymapMode fromJson(String? raw) => switch (raw) {
        'cua' => KeymapMode.cua,
        _ => KeymapMode.emacs,
      };
}

/// Which physical key acts as the Emacs "Meta" modifier.
///
/// | Value    | Behaviour                                                          |
/// |----------+--------------------------------------------------------------------|
/// | alt      | Alt key (default). M-f = Alt+F, etc.                              |
/// | ctrl     | Ctrl key. M-f = Ctrl+F. **Note:** Ctrl-as-Meta collides with the  |
/// |          | existing C- bindings (C-f, C-k, etc.) in the same map. Because   |
/// |          | the C- entries appear first in the literal, they win on collision.|
/// |          | M- bindings are effectively unavailable under ctrl. Prefer alt or |
/// |          | superKey for collision-free M- access.                            |
/// | superKey | Super (Windows / Command) key. M-f = Super+F. No collisions.     |
/// | esc      | Esc-as-Meta. By design this maps onto the alt bindings — Alt      |
/// |          | already provides Meta, so a separate Esc-prefix state machine is  |
/// |          | intentionally not implemented (redundant). See [MetaKey.esc].     |
///
/// The string values mirror AppConfig.metaKey tokens: `alt`, `ctrl`,
/// `super`, `esc`.
enum MetaKey {
  /// Alt key — the default. M-f = Alt+F.
  alt,

  /// Ctrl key as Meta. Collides with C- bindings; C- wins on conflict.
  ctrl,

  /// Super (Windows / Command) key. Collision-free Meta.
  superKey,

  /// Esc-as-Meta. **By design resolves to the alt bindings** — a dedicated
  /// Esc-prefix state machine is redundant (Alt already carries Meta) and is
  /// intentionally not implemented.
  esc;

  /// Parse a lower-case config token, returning [MetaKey.alt] for any
  /// unknown value.
  static MetaKey fromString(String s) => switch (s.toLowerCase()) {
        'ctrl' => MetaKey.ctrl,
        'super' => MetaKey.superKey,
        'esc' => MetaKey.esc,
        _ => MetaKey.alt,
      };
}
