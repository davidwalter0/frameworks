/// Host capability model — the contract that makes platform divergence
/// explicit instead of silent.
///
/// desktop_kit apps run against materially different hosts:
///
/// | Host mode | Filesystem | Subprocesses | PRIMARY selection |
/// |---|---|---|---|
/// | `direct` (desktop) | full `dart:io` | yes | yes (xclip/wl-copy) |
/// | `remote` (web + local backend) | via RPC | via RPC | no — browser sandbox |
/// | `browser` (web, no backend) | user-granted handles only | no | no |
///
/// The failure this library exists to prevent is a feature that *looks*
/// present and then does nothing. A command bound to a key that silently
/// no-ops is worse than one that is visibly disabled with a stated reason,
/// because the user cannot tell a broken editor from an unsupported host.
///
/// So every host-dependent facility is named in [HostCapability], every host
/// declares a [CapabilityStatus] for each one, and the UI is expected to read
/// [HostCapabilities] and *say* what it cannot do — see [CapabilityStatus.detail],
/// which is required precisely so no host can decline a capability without
/// explaining itself.
library;

import 'package:flutter/foundation.dart';

/// A host-provided facility that a feature may depend on.
///
/// Granularity rule: a capability is listed separately when some host grades it
/// differently from its neighbours. [fileRead] and [fileWrite] are split because
/// a browser host can be granted read-only handles; [subprocess] and [shell] are
/// split because a remote host may allow one-shot commands while refusing an
/// interactive pty.
enum HostCapability {
  /// Read file contents by path.
  fileRead,

  /// Write file contents by path.
  fileWrite,

  /// Enumerate a directory (dired, file completion).
  directoryList,

  /// Resolve arbitrary host paths — `$HOME`, `..`, tilde expansion, absolute
  /// paths the user typed. Distinct from [fileRead]: a browser host can read a
  /// file the user picked while having no notion of a path namespace at all.
  pathNamespace,

  /// Observe changes to a file made outside the editor.
  fileWatch,

  /// Spawn a one-shot subprocess and collect its output.
  subprocess,

  /// Run an interactive, long-lived shell attached to a buffer.
  shell,

  /// Japanese henkan via the `anthy-agent` egg protocol.
  anthyIme,

  /// JMDict SQLite gloss lookups for henkan candidates.
  dictionaryGloss,

  /// X11 / Wayland PRIMARY selection (highlight-to-copy, middle-click-paste).
  primarySelection,

  /// The ordinary system clipboard (Ctrl+C / Ctrl+V).
  systemClipboard,

  /// Enumerate installed font families.
  hostFonts,

  /// Detect the desktop environment's UI font.
  hostUiFont,

  /// Persist settings across restarts.
  persistentSettings,

  /// Read the process environment (`$HOME`, `$PATH`, `$XDG_*`).
  processEnvironment,

  /// Exclusive receipt of keyboard chords the app's own keymap binds —
  /// whether the app's `Focus.onKeyEvent`/`Shortcuts` handling is the ONLY
  /// consumer of a keydown, or whether some OTHER layer (a browser's own
  /// accelerators; a window manager's global bindings) can intercept a bound
  /// chord before the app ever sees it. Desktop apps get this for free — the
  /// OS delivers every keydown to the focused window. A browser tab (or an
  /// installed/standalone PWA window — window furniture is not keyboard
  /// routing) reserves a subset of chords for itself regardless of what the
  /// page does; `event.preventDefault()` reclaims the rest, but only if the
  /// page calls it before the browser's own default-action check runs.
  keyboardShortcuts,

  /// Org-mode structural support: outline/`structure`, `tangle`, `execute`
  /// (babel), and `resultsRange` — the four verbs
  /// `package:desktop_kit/desktop_kit_org.dart`'s `OrgSupport` exposes.
  ///
  /// Split from [subprocess] rather than reusing it: a host can provide
  /// three of these four verbs (structure, tangle preview/compute,
  /// resultsRange are pure Go computation, no process spawn) while
  /// genuinely lacking the fourth. `execute` (babel) delegates to
  /// `os/exec` in the underlying Go binary, so it needs a real process
  /// host regardless of how the other three verbs are served — a browser
  /// tab can never provide it, no matter how the other three are wired.
  /// A single [subprocess]-keyed grade could not express "3 of 4 verbs
  /// work"; this capability exists so a host can say exactly that,
  /// per [CapabilityStatus.detail].
  orgSupport,
}

/// How well a host provides a capability.
///
/// The middle grade is the load-bearing one. Without [degraded], a host must
/// claim a capability is either perfect or missing, and the honest answer for
/// most web facilities is neither — a browser *can* read a file, just not any
/// file, and not by path.
enum CapabilityGrade {
  /// Provided with the same semantics a desktop host would give.
  full,

  /// Provided, but with restrictions the user can observe. The
  /// [CapabilityStatus.detail] must say what the restriction is.
  degraded,

  /// Not provided at all. The [CapabilityStatus.detail] must say why, and
  /// where practical, what the user could do instead.
  absent,
}

/// One host's verdict on one capability, with a mandatory human-readable
/// explanation.
///
/// [detail] is not optional and not decorative: it is the string the UI shows
/// when a user asks why a command is greyed out. "unsupported" is not an
/// acceptable value; "no process host — run `eedit --serve` and connect in
/// remote mode" is.
@immutable
class CapabilityStatus {
  /// Creates a status. Prefer the [full], [degraded] and [absent] factories.
  const CapabilityStatus({
    required this.capability,
    required this.grade,
    required this.detail,
  });

  /// Declares [capability] fully provided. [detail] describes *how*, which is
  /// what makes a bug report legible ("via the local backend at :7373").
  const CapabilityStatus.full(this.capability, this.detail)
      : grade = CapabilityGrade.full;

  /// Declares [capability] provided with an observable restriction, stated in
  /// [detail].
  const CapabilityStatus.degraded(this.capability, this.detail)
      : grade = CapabilityGrade.degraded;

  /// Declares [capability] unavailable, with the reason in [detail].
  const CapabilityStatus.absent(this.capability, this.detail)
      : grade = CapabilityGrade.absent;

  /// The facility being graded.
  final HostCapability capability;

  /// How well this host provides it.
  final CapabilityGrade grade;

  /// Why — shown verbatim to the user. Never empty.
  final String detail;

  /// True when the capability can be used at all (full or degraded).
  bool get usable => grade != CapabilityGrade.absent;

  @override
  String toString() => '${capability.name}: ${grade.name} — $detail';

  @override
  bool operator ==(Object other) =>
      other is CapabilityStatus &&
      other.capability == capability &&
      other.grade == grade &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(capability, grade, detail);
}

/// The complete, self-describing capability manifest of one host.
///
/// A host constructs this once at startup. The UI reads it to decide what to
/// enable, and — more importantly — what to explain.
///
/// Every [HostCapability] is always addressable: [statusOf] never returns null,
/// falling back to an `absent` status naming the omission, so a host that
/// forgets to declare a capability produces a visible "not declared" rather
/// than a silent false.
@immutable
class HostCapabilities {
  /// Creates a manifest for [hostMode] from [statuses].
  HostCapabilities({
    required this.hostMode,
    required this.description,
    required List<CapabilityStatus> statuses,
  }) : _statuses = <HostCapability, CapabilityStatus>{
          for (final CapabilityStatus s in statuses) s.capability: s,
        };

  /// Short machine-readable host id — `direct`, `remote`, `browser`.
  final String hostMode;

  /// One line naming this host for the UI, e.g.
  /// "browser — no host process, files via the File System Access API".
  final String description;

  final Map<HostCapability, CapabilityStatus> _statuses;

  /// The status of [c]. Never null: an undeclared capability reports as
  /// [CapabilityGrade.absent] with a detail saying it was never declared,
  /// which surfaces the omission instead of hiding it.
  CapabilityStatus statusOf(HostCapability c) =>
      _statuses[c] ??
      CapabilityStatus.absent(
        c,
        'not declared by the "$hostMode" host — this is a host-definition gap, '
        'please report it',
      );

  /// True when [c] is usable at all (full or degraded).
  bool has(HostCapability c) => statusOf(c).usable;

  /// True only when [c] is provided with full desktop semantics.
  bool isFull(HostCapability c) => statusOf(c).grade == CapabilityGrade.full;

  /// The user-facing reason [c] is unavailable or restricted, or null when it
  /// is fully provided.
  String? restrictionOn(HostCapability c) {
    final CapabilityStatus s = statusOf(c);
    return s.grade == CapabilityGrade.full ? null : s.detail;
  }

  /// Every declared status, ordered by [HostCapability] declaration order, for
  /// rendering a divergence table in a help screen.
  List<CapabilityStatus> get all =>
      HostCapability.values.map(statusOf).toList(growable: false);

  /// Capabilities this host does not fully provide — the divergence list.
  List<CapabilityStatus> get divergences => all
      .where((CapabilityStatus s) => s.grade != CapabilityGrade.full)
      .toList(growable: false);

  @override
  String toString() => 'HostCapabilities($hostMode, '
      '${divergences.length}/${HostCapability.values.length} diverge)';
}
