/// Transport abstraction over a long-running `anthy-agent --egg` subprocess.
///
/// This library holds only the interface and the protocol constants, so it
/// compiles everywhere. The real subprocess-backed implementation
/// (`SystemAnthyProcess`) lives in `anthy_process_io.dart` behind the
/// `desktop_kit_anthy_io.dart` entrypoint — keeping it out of here is what lets
/// a browser build import the Anthy driver, wire a non-subprocess transport (or
/// none), and still compile.
library;

/// Default name of the agent executable (resolved via PATH).
///
/// Lives here rather than on `SystemAnthyProcess` because `AnthyEgg` uses it as
/// a default parameter value; a static on the io-only class would have dragged
/// `dart:io` back into every library that mentions the default.
const String anthyExecutableName = 'anthy-agent';

/// Arguments that put the agent into egg-protocol mode.
const List<String> anthyEggArguments = <String>['--egg'];

/// A line-oriented transport to a running Anthy agent.
///
/// The egg protocol is a request/response dialogue spoken over the agent's
/// stdin/stdout. This interface exposes exactly what the [AnthyEgg] driver
/// needs:
///
///   * [lines] — the agent's stdout decoded as UTF-8 and split into logical
///     lines. Each emitted string has any trailing carriage return (`\r`)
///     trimmed, so the driver sees clean content regardless of whether the
///     wire framing is `\r\n` or `\n`.
///   * [send] — write a single command line (a newline is appended).
///   * [kill] — terminate the subprocess.
///
/// The whole point is dependency injection: production wires
/// `SystemAnthyProcess` (which spawns the real binary); tests wire a fake so
/// the [AnthyEgg] driver can be exercised against the captured protocol
/// fixture without ever spawning a subprocess. A remote host can wire a
/// third implementation that relays the same lines over a websocket.
abstract class AnthyProcess {
  /// Decoded stdout, one event per logical line (trailing `\r` trimmed).
  ///
  /// This is a broadcast-style stream from the driver's perspective: it
  /// subscribes once and consumes every line. Implementations may back it
  /// with either a single-subscription or broadcast controller.
  Stream<String> get lines;

  /// Write [line] to the agent's stdin, terminated with a single `\n`.
  void send(String line);

  /// Terminate the underlying process (no-op if already gone).
  Future<void> kill();
}

/// A transport that is never connected — the **compose-only** backend.
///
/// A host that offers romaji→kana composition WITHOUT kana→kanji conversion
/// (Japanese input enabled but no `anthy-agent` — the graceful-degradation
/// path, and the common case in tests) still needs an `ImeController` in order
/// to construct a `PreeditSession`, because the session owns the whole preedit
/// lifecycle. The composing phase never touches the transport: `feedKana`,
/// `backspace`, `toggleScript`, and a composing `commit`/`discard` are pure
/// state. Wiring this null transport therefore yields a fully working
/// compose-only session with **no subprocess** and no conversion-vs-compose
/// branching inside the session.
///
/// [lines] is empty and already closed, so an accidental conversion attempt
/// ([AnthyEgg.start] awaiting a greeting that will never arrive) fails FAST and
/// catchably instead of hanging. A host should still gate conversion on its own
/// availability check — this is the backstop, not the gate.
class NullAnthyProcess implements AnthyProcess {
  /// Create a never-connected transport.
  const NullAnthyProcess();

  @override
  Stream<String> get lines => const Stream<String>.empty();

  @override
  void send(String line) {
    // Deliberately dropped: nothing is connected. A conversion attempt surfaces
    // through [lines] being closed, not through a silent success here.
  }

  @override
  Future<void> kill() async {}
}
