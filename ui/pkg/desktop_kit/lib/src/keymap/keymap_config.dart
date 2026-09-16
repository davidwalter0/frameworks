// Serialisable user keybinding configuration.
//
// A [KeymapConfig] is the persisted, editable representation of the keymaps:
// per [KeymapMode], a map of [KeyChordSequence] → intent id. It round-trips
// through JSON (the sequence [KeyChordSequence.token] as the object key, intent
// id as the value), builds a live `Map<ShortcutActivator, Intent>` against a
// [KeymapRegistry], and can be seeded from the kit defaults so the editor has a
// starting point and a reset target.
//
// ## Single-stroke vs multi-stroke — the load-bearing split
//
// Flutter's [Shortcuts]/[ShortcutActivator] machinery has no way to express a
// multi-stroke sequence like `C-x C-s` (there is no "chord *then* chord"
// combinator). So the config draws a hard line:
//
//   * **Length-1 sequences** (a single keystroke) build a [ShortcutActivator]
//     exactly as before and flow through [toKeymap] into the live Flutter
//     shortcut map.
//   * **Length>1 sequences** are *excluded* from [toKeymap] and are instead
//     exposed by [sequenceBindings]. A prefix-dispatch matcher (a later step)
//     consumes those; until then, multi-stroke bindings are editor-visible and
//     rebindable, but are dispatched by the hardcoded [PrefixDispatcher], not by
//     this map.
//
// ## Backward compatibility with pre-sequence configs
//
// Before sequences existed, keys were bare [KeyChord] tokens (no spaces). A
// spaceless token parses as a length-1 [KeyChordSequence], and a length-1
// sequence re-encodes to exactly that bare token, so:
//
//   * every previously-saved config loads unchanged ([fromJson] routes each key
//     through [KeyChordSequence.parse]); and
//   * re-encoding old data is byte-stable ([toJson]/[encodeMode] emit
//     [KeyChordSequence.token], which for a single stroke is the old token).
//
// The `keymap_config_test.dart` "backward-compat" group proves both with a
// verbatim pre-change JSON fixture.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'key_chord.dart';
import 'key_chord_sequence.dart';
import 'keymap_mode.dart';
import 'keymap_registry.dart';
import 'keymaps.dart';

/// Per-mode keybindings: `mode → (key-sequence → intent-id)`.
///
/// The sequence→id direction (each sequence maps to exactly one intent; an
/// intent may appear under several sequences, e.g. Help on C-h and F1) matches
/// both the runtime keymap shape and the JSON on-disk form. Sequence uniqueness
/// per mode is the invariant the editor's conflict detection maintains.
@immutable
class KeymapConfig {
  /// Create a [KeymapConfig] from a per-mode sequence→id map.
  ///
  /// [schemaVersion] is the on-disk marker (see [currentSchemaVersion]); leave
  /// it null for an in-memory config that is not a persisted delta.
  const KeymapConfig(this.modes, {this.schemaVersion});

  /// The persisted-config schema this build writes.
  ///
  /// * **absent / null** — the *snapshot era*. The file was written before
  ///   delta persistence, by a host that saved the WHOLE config on the first
  ///   rebind, so it is a frozen copy of whatever the defaults were that day.
  ///   [upgraded] converts one.
  /// * **2** — a DELTA: only bindings that differ from the shipped defaults,
  ///   plus [unboundId] tombstones for defaults the user removed.
  ///
  /// The marker exists so a future migration does not have to GUESS which
  /// defaults seeded a file. Its absence today is exactly why [upgraded] needs
  /// a hand-written retirement list at all; stamping it means the next default
  /// change needs none.
  static const int currentSchemaVersion = 2;

  /// Reserved intent id marking a shipped default the user has UNBOUND.
  ///
  /// A delta has to express removal: the editor's ✕ (`_removeSequence`) and
  /// rebinding-onto-another-chord both DELETE a default binding, and a merge
  /// that only knows about additions would resurrect it on the next load.
  ///
  /// The `!` prefix cannot collide with a registered intent id (they are
  /// camelCase identifiers), and [KeymapRegistry.intentFor] returns null for
  /// it, so a tombstone that leaks into a live keymap is inert rather than
  /// fatal.
  static const String unboundId = '!unbound';

  /// The empty config (no user overrides) — [Keymaps.forMode] then yields the
  /// kit defaults unchanged.
  static const KeymapConfig empty =
      KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{});

  /// Seed a config from the kit's default keymaps for every [KeymapMode], using
  /// [registry] to resolve each default [Intent] to its id. Bindings whose
  /// intent is not registered (or that are not [SingleActivator]s) are dropped.
  /// This is the editor's initial value and its reset-to-defaults target.
  ///
  /// The result carries two layers:
  ///   * the **single-stroke** defaults, inverted from the live Flutter keymap
  ///     ([Keymaps.forMode]); plus
  ///   * the kit's canonical **multi-stroke** sequences (e.g. `C-x C-s`), from
  ///     [Keymaps.defaultSequenceBindings], so the editor shows and can rebind
  ///     them even though Flutter's [ShortcutActivator] cannot express them.
  ///     (Runtime dispatch for those still comes from [PrefixDispatcher] until a
  ///     later step wires a sequence matcher — see the library doc.)
  factory KeymapConfig.fromDefaults(
    KeymapRegistry registry, {
    MetaKey metaKey = MetaKey.alt,
  }) {
    final out = <KeymapMode, Map<KeyChordSequence, String>>{};
    for (final mode in KeymapMode.values) {
      final m = <KeyChordSequence, String>{};
      // Single-stroke defaults: invert the SingleActivator keymap.
      Keymaps.forMode(mode, metaKey: metaKey).forEach((activator, intent) {
        if (activator is SingleActivator) {
          final id = registry.idFor(intent);
          if (id != null) {
            m[KeyChordSequence.single(KeyChord.fromActivator(activator))] = id;
          }
        }
      });
      // Multi-stroke defaults: the kit's canonical C-x sequences, editor-only
      // (kept out of the SingleActivator map). Ids the registry lacks drop.
      Keymaps.defaultSequenceBindings(mode).forEach((seq, id) {
        if (registry.contains(id)) m[seq] = id;
      });
      out[mode] = m;
    }
    return KeymapConfig(out);
  }

  /// Parse a [KeymapConfig] from decoded JSON (see [toJson]). Unknown mode keys
  /// and malformed sequence tokens are skipped defensively rather than throwing
  /// on a partially-forward config.
  ///
  /// Backward-compatible: a pre-sequence key is a bare single-chord token with
  /// no spaces, which [KeyChordSequence.parse] reads as a length-1 sequence, so
  /// every previously-saved config loads unchanged.
  factory KeymapConfig.fromJson(Map<String, dynamic> json) {
    final out = <KeymapMode, Map<KeyChordSequence, String>>{};
    for (final entry in json.entries) {
      final mode = _modeByName(entry.key);
      if (mode == null) continue;
      final inner = entry.value;
      if (inner is! Map) continue;
      final m = <KeyChordSequence, String>{};
      inner.forEach((token, id) {
        if (token is! String || id is! String) return;
        try {
          m[KeyChordSequence.parse(token)] = id;
        } on FormatException {
          // Skip an unparseable token rather than failing the whole load.
        }
      });
      out[mode] = m;
    }
    final v = json['schemaVersion'];
    return KeymapConfig(out, schemaVersion: v is int ? v : null);
  }

  /// Decode a JSON string into a [KeymapConfig].
  factory KeymapConfig.decode(String source) =>
      KeymapConfig.fromJson(jsonDecode(source) as Map<String, dynamic>);

  /// Per-mode bindings: `mode → (key-sequence → intent-id)`.
  final Map<KeymapMode, Map<KeyChordSequence, String>> modes;

  /// On-disk schema marker, or null for a snapshot-era file / an in-memory
  /// config that was never persisted. See [currentSchemaVersion].
  final int? schemaVersion;

  /// Whether this config has been through [upgraded] (or was written by a build
  /// that persists deltas).
  bool get isDelta =>
      schemaVersion != null && schemaVersion! >= currentSchemaVersion;

  /// The bindings for [mode], or an empty map if none. Includes both
  /// single-stroke and multi-stroke sequences; use [singleStrokeBindings] /
  /// [sequenceBindings] to split them.
  Map<KeyChordSequence, String> bindingsFor(KeymapMode mode) =>
      modes[mode] ?? const <KeyChordSequence, String>{};

  /// The **single-stroke** (length-1) bindings for [mode] — the subset Flutter's
  /// [ShortcutActivator] machinery can express. This is what [toKeymap] builds
  /// from.
  Map<KeyChordSequence, String> singleStrokeBindings(KeymapMode mode) {
    final out = <KeyChordSequence, String>{};
    bindingsFor(mode).forEach((seq, id) {
      if (seq.isSingle) out[seq] = id;
    });
    return out;
  }

  /// The **multi-stroke** (length>1) bindings for [mode] — the sequences Flutter
  /// cannot express as a [ShortcutActivator]. A later step's prefix-dispatch
  /// matcher consumes this; [toKeymap] deliberately omits these. Returned as
  /// `sequence → intent-id` (the caller resolves ids through a [KeymapRegistry],
  /// mirroring [toKeymap]).
  Map<KeyChordSequence, String> sequenceBindings(KeymapMode mode) {
    final out = <KeyChordSequence, String>{};
    bindingsFor(mode).forEach((seq, id) {
      if (!seq.isSingle) out[seq] = id;
    });
    return out;
  }

  /// Whether this config carries any bindings at all.
  bool get isEmpty => modes.values.every((m) => m.isEmpty);

  /// Build the live `Map<ShortcutActivator, Intent>` for [mode], resolving each
  /// intent id through [registry]. Ids the registry doesn't know are dropped.
  ///
  /// **Only length-1 sequences are included** — Flutter's [ShortcutActivator]
  /// cannot express a multi-stroke sequence, so `C-x C-s` and friends are
  /// intentionally absent here; retrieve them with [sequenceBindings] and drive
  /// them through the prefix dispatcher instead. See the library doc.
  Map<ShortcutActivator, Intent> toKeymap(
    KeymapMode mode,
    KeymapRegistry registry,
  ) {
    final out = <ShortcutActivator, Intent>{};
    bindingsFor(mode).forEach((seq, id) {
      final single = seq.asSingle;
      if (single == null) return; // multi-stroke: not ShortcutActivator-able.
      final intent = registry.intentFor(id);
      if (intent != null) out[single.toActivator()] = intent;
    });
    return out;
  }

  /// A copy with [mode]'s bindings replaced by [bindings].
  KeymapConfig withMode(
    KeymapMode mode,
    Map<KeyChordSequence, String> bindings,
  ) {
    final next = Map<KeymapMode, Map<KeyChordSequence, String>>.from(modes);
    next[mode] = Map<KeyChordSequence, String>.from(bindings);
    return KeymapConfig(next, schemaVersion: schemaVersion);
  }

  /// The set of intent ids bound in [mode].
  Set<String> intentIdsFor(KeymapMode mode) => bindingsFor(mode).values.toSet();

  /// The bindings that DIFFER from [against] — the thing a host persists.
  ///
  /// This is half of the layered model that replaces whole-config snapshots:
  ///
  /// ```text
  /// persist  ->  delta(against: shipped)
  /// load     ->  storedDelta.mergedOnto(shipped)
  /// ```
  ///
  /// Under it a corrected shipped default reaches every user automatically,
  /// because the file no longer claims authorship of bindings the user never
  /// chose. The failure it fixes: hosts call `persist(config.toJson())` on the
  /// FIRST rebind, writing a complete frozen copy of every binding — the file
  /// never passes through "a delta" — and load decodes it wholesale. One rebind
  /// and that user owned a private fork of the shipped defaults forever.
  ///
  /// Three kinds of entry come out:
  ///   * a sequence bound to a DIFFERENT intent than the default — the rebind;
  ///   * a sequence the defaults do not bind at all — a new binding;
  ///   * with [tombstones] (the default), a default the user REMOVED, recorded
  ///     as [unboundId]. Without it a merge would resurrect it on next load.
  ///
  /// A mode absent from [modes] entirely is left out rather than tombstoned
  /// wholesale — "this file does not configure CUA" is not "the user unbound
  /// every CUA key".
  ///
  /// **The trade, stated rather than discovered:** a user who deliberately
  /// rebinds a key to the value it ALREADY has is indistinguishable from one
  /// who never touched it, so that choice is dropped and they will inherit a
  /// later change to that default. This is the standard layered-config trade.
  /// It is the price of a corrected default reaching eleven apps without a
  /// maintained per-fix list, and it is much cheaper than the alternative.
  KeymapConfig delta({
    required KeymapConfig against,
    bool tombstones = true,
  }) {
    final out = <KeymapMode, Map<KeyChordSequence, String>>{};
    for (final mode in KeymapMode.values) {
      if (!modes.containsKey(mode)) continue;
      final mine = bindingsFor(mode);
      final theirs = against.bindingsFor(mode);
      final d = <KeyChordSequence, String>{};
      mine.forEach((seq, id) {
        if (id == unboundId) {
          // Already a tombstone; keep it only while the default it buries
          // still exists, else it is dead weight.
          if (tombstones && theirs.containsKey(seq)) d[seq] = unboundId;
          return;
        }
        if (theirs[seq] != id) d[seq] = id;
      });
      if (tombstones) {
        theirs.forEach((seq, _) {
          if (!mine.containsKey(seq)) d[seq] = unboundId;
        });
      }
      if (d.isNotEmpty) out[mode] = d;
    }
    return KeymapConfig(out, schemaVersion: currentSchemaVersion);
  }

  /// [defaults] with this config layered on top — the EFFECTIVE keymap.
  ///
  /// The inverse of [delta]. [unboundId] tombstones delete; everything else
  /// overrides or adds. A mode this config does not mention keeps [defaults]
  /// unchanged. The result never contains a tombstone, so it is safe to hand
  /// to the editor, to [toKeymap], and to `Keymaps.forMode(overrides:)`.
  KeymapConfig mergedOnto(KeymapConfig defaults) {
    final out = <KeymapMode, Map<KeyChordSequence, String>>{};
    for (final mode in KeymapMode.values) {
      final m = Map<KeyChordSequence, String>.from(defaults.bindingsFor(mode));
      bindingsFor(mode).forEach((seq, id) {
        if (id == unboundId) {
          m.remove(seq);
        } else {
          m[seq] = id;
        }
      });
      out[mode] = m;
    }
    return KeymapConfig(out, schemaVersion: schemaVersion);
  }

  /// Bring a loaded config to [currentSchemaVersion]. Call once, at load, and
  /// RE-SAVE when `changed` is true.
  ///
  /// ```dart
  /// final stored = KeymapConfig.decode(json);
  /// final up = stored.upgraded(defaults: shipped);
  /// if (up.changed) await store.save(up.config.encode());
  /// final effective = up.config.mergedOnto(shipped);  // editor + runtime
  /// ```
  ///
  /// Already a delta ([isDelta]) → returned untouched, `changed: false`. This
  /// is idempotent and cheap enough to run unconditionally.
  ///
  /// ## What the snapshot-era branch does, and why it is CLOSED-ENDED
  ///
  /// Delta persistence alone does not repair files ALREADY on disk as full
  /// snapshots. Two things are done to one:
  ///
  /// 1. **Diff it against the shipped defaults**, WITHOUT tombstones. A
  ///    snapshot froze the defaults of its day, and the defaults have grown
  ///    since; a snapshot from an older build is missing dozens of bindings
  ///    that did not exist yet. Reading that absence as "the user unbound it"
  ///    would silently strip most of the keymap. So the transition errs toward
  ///    the shipped defaults, and the honest limitation is recorded here: a
  ///    binding a user genuinely REMOVED in the snapshot era comes back once.
  ///    That is unrecoverable from the data — the file cannot tell the two
  ///    apart — and it fails in the safe direction.
  ///
  /// 2. **Sweep [kSnapshotEraRetirements]**, AFTER the diff. This exists for
  ///    one case the diff cannot catch: an entry that restates a default which
  ///    has since been CHANGED still differs from the new default, so it
  ///    survives the diff and goes on enforcing a binding the user never chose.
  ///
  /// Order matters and is the easy thing to get backwards. Sweeping first would
  /// delete the entry, and the diff would then read the gap as a removal and
  /// tombstone it — permanently unbinding the key it was trying to free.
  ///
  /// **This branch is a bounded transition, not a mechanism.** Once a file
  /// carries the marker it never runs again, and because a delta no longer
  /// contains bindings the user did not choose, a FUTURE default change needs
  /// no entry here — it simply reaches the user. Do not add rows to
  /// [kSnapshotEraRetirements] for new default changes; that would rebuild the
  /// maintained registry this design exists to avoid.
  ({KeymapConfig config, bool changed, List<RetiredDefaultBinding> dropped})
      upgraded({required KeymapConfig defaults}) {
    if (isDelta) {
      return (
        config: this,
        changed: false,
        dropped: const <RetiredDefaultBinding>[],
      );
    }
    // (1) diff first — see the doc: sweeping first would turn the gap into a
    // tombstone. No tombstones: absence in a snapshot means "did not exist
    // yet", not "removed".
    final diffed = delta(against: defaults, tombstones: false);
    // (2) then sweep the closed retirement list.
    final dropped = <RetiredDefaultBinding>[];
    final swept = <KeymapMode, Map<KeyChordSequence, String>>{};
    diffed.modes.forEach((mode, bindings) {
      final kept = <KeyChordSequence, String>{};
      bindings.forEach((seq, id) {
        RetiredDefaultBinding? hit;
        for (final r in kSnapshotEraRetirements) {
          if (r.mode == mode && r.sequence == seq && r.intentId == id) {
            hit = r;
            break;
          }
        }
        if (hit == null) {
          kept[seq] = id;
        } else {
          dropped.add(hit);
        }
      });
      if (kept.isNotEmpty) swept[mode] = kept;
    });
    return (
      config: KeymapConfig(swept, schemaVersion: currentSchemaVersion),
      changed: true,
      dropped: dropped,
    );
  }

  /// JSON form:
  /// `{ "schemaVersion": 2, "emacs": { "<sequence-token>": "<intent-id>" }, ... }`.
  ///
  /// For a length-1 sequence the token is the bare chord token (no spaces), so
  /// this is byte-stable with pre-sequence configs.
  ///
  /// [schemaVersion] is emitted ONLY when non-null, so a snapshot-era file
  /// re-encodes byte-identically — the guarantee the `keymap_config_test`
  /// "byte-stable" case pins — and "carries a marker" is exactly "has been
  /// through [upgraded]". Every existing reader already skips an unknown
  /// top-level key ([fromJson] drops anything that is not a mode name), so the
  /// addition is compatible in both directions.
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (schemaVersion != null) 'schemaVersion': schemaVersion,
        for (final entry in modes.entries)
          entry.key.name: <String, String>{
            for (final b in entry.value.entries) b.key.token: b.value,
          },
      };

  /// Encode the whole config as a JSON string.
  String encode() => jsonEncode(toJson());

  /// Encode a single [mode]'s bindings as a JSON string (the per-mode Save
  /// form): `{ "schemaVersion": 2, "<mode>": { "<sequence-token>": "<id>" } }`.
  ///
  /// Carries the marker too: a host that saves per-mode (the editor's `onSave`)
  /// must still stamp the file, or its config stays snapshot-era forever and
  /// [upgraded] re-runs on every load.
  String encodeMode(KeymapMode mode) => jsonEncode(<String, dynamic>{
        if (schemaVersion != null) 'schemaVersion': schemaVersion,
        mode.name: <String, String>{
          for (final b in bindingsFor(mode).entries) b.key.token: b.value,
        },
      });

  static KeymapMode? _modeByName(String name) {
    for (final m in KeymapMode.values) {
      if (m.name == name) return m;
    }
    return null;
  }
}

/// A `(mode, sequence, intent-id)` triple that WAS a kit default and no longer
/// is — the unit [KeymapConfig.upgraded]'s snapshot-era branch matches on.
///
/// The full triple is the point: matching on the chord alone would also delete
/// a user's deliberate rebind of that chord to something else.
@immutable
class RetiredDefaultBinding {
  /// Create a retirement record.
  const RetiredDefaultBinding({
    required this.mode,
    required this.sequence,
    required this.intentId,
    required this.retiredIn,
    required this.reason,
  });

  /// The mode the retired binding belonged to. A binding retired in one mode is
  /// untouched in the other.
  final KeymapMode mode;

  /// The chord sequence the retired default occupied.
  final KeyChordSequence sequence;

  /// The intent id the retired default pointed at.
  final String intentId;

  /// Package version that retired it, for the log line a host prints.
  final String retiredIn;

  /// Why it was retired — shown to the user when a host reports the migration.
  final String reason;

  @override
  String toString() => 'RetiredDefaultBinding(${mode.name} ${sequence.label} '
      '→ $intentId, retired in $retiredIn)';
}

/// **CLOSED LIST — do not add to it.**
///
/// Defaults that changed while configs were persisted as whole snapshots, and
/// which therefore survive [KeymapConfig.delta] as a difference the user never
/// authored. It covers exactly the files written before
/// [KeymapConfig.currentSchemaVersion] existed.
///
/// A NEW default change needs no entry here. Under delta persistence a stored
/// config contains only genuine user choices, so a corrected default reaches
/// every user by itself. Adding a row for a future change would rebuild the
/// maintained per-fix registry that delta persistence exists to retire — and
/// it would be wrong as well as redundant, because a schema-2 file never
/// reaches this code path.
final List<RetiredDefaultBinding> kSnapshotEraRetirements =
    List<RetiredDefaultBinding>.unmodifiable(<RetiredDefaultBinding>[
  RetiredDefaultBinding(
    mode: KeymapMode.emacs,
    sequence: KeyChordSequence.single(
      KeyChord(keyId: LogicalKeyboardKey.keyS.keyId, control: true),
    ),
    intentId: 'save',
    retiredIn: '0.2.4',
    reason: 'C-s was bound to Save buffer, a CUA convention with no place in '
        'an Emacs map. GNU Emacs binds C-s to isearch-forward and saves on '
        'C-x C-s, which the kit already binds. CUA keeps Ctrl+S = save.',
  ),
]);
