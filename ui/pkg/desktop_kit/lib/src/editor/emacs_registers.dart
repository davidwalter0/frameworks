// Pure Dart Emacs-style registers (C-x r s / C-x r i) and keyboard macro
// recording (C-x ( / C-x ) / C-x e). Neither depends on Flutter or on a text
// buffer — both operate purely on strings / intent ids, so a host UI wires
// them to real key sequences and buffer text.
library;

/// Single-char named string storage, mirroring Emacs registers (`C-x r s` /
/// `C-x r i`). Register names are conventionally a single character, but this
/// class does not enforce that — the host UI decides what counts as a valid
/// register name.
class Registers {
  final Map<String, String> _values = <String, String>{};

  /// The stored value for [name], or null if nothing has been put there yet.
  String? get(String name) => _values[name];

  /// Store [value] under [name], overwriting any previous value.
  void put(String name, String value) {
    _values[name] = value;
  }

  /// A read-only snapshot of every register currently set.
  Map<String, String> get all => Map<String, String>.unmodifiable(_values);
}

/// Records and replays a flat sequence of intent ids / self-insert steps,
/// mirroring Emacs keyboard macros (`C-x (` start, `C-x )` end, `C-x e`
/// replay). Purely bookkeeping: the host UI is responsible for actually
/// re-dispatching the steps returned by [replay].
class MacroRecorder {
  bool _recording = false;
  List<String> _steps = <String>[];
  List<String>? _lastMacro;

  /// Whether a macro is currently being recorded.
  bool get recording => _recording;

  /// Whether a macro has been recorded and is available to [replay].
  bool get hasMacro => _lastMacro != null;

  /// The steps recorded so far in the current recording (empty when not
  /// recording, or after [end] until a new [start]).
  List<String> get steps => List<String>.unmodifiable(_steps);

  /// Begin recording a new macro, discarding any in-progress recording.
  void start() {
    _recording = true;
    _steps = <String>[];
  }

  /// Append [intentIdOrChar] to the in-progress recording. No-op when not
  /// currently recording.
  void record(String intentIdOrChar) {
    if (!_recording) return;
    _steps.add(intentIdOrChar);
  }

  /// Stop recording, saving the recorded steps as the last macro. No-op when
  /// not currently recording.
  void end() {
    if (!_recording) return;
    _recording = false;
    _lastMacro = List<String>.from(_steps);
  }

  /// The steps of the last recorded macro, for the host to re-dispatch.
  /// Empty when no macro has been recorded yet.
  List<String> replay() {
    final macro = _lastMacro;
    if (macro == null) return <String>[];
    return List<String>.from(macro);
  }
}
