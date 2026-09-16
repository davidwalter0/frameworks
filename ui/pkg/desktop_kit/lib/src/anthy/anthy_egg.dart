import 'dart:async';

import '../host/host_process_default.dart';
import 'anthy_process.dart';

/// Thrown when the agent replies with an error line (`-ERR ...` / `-...`) or
/// when the driver is used incorrectly (e.g. converting before [AnthyEgg.start]).
class AnthyEggException implements Exception {
  AnthyEggException(this.message);

  /// Human-readable detail — the agent's error line, or a driver-side reason.
  final String message;

  @override
  String toString() => 'AnthyEggException: $message';
}

/// One bunsetsu (文節) segment of a conversion: how many candidates the agent
/// offers for it, the currently-best (top) candidate, and the hiragana reading
/// that produced it.
///
/// Wire shape (a CONVERT / RESIZE-SEGMENT segment line):
/// `"<ncands> <best> <reading>"`, e.g. `"3 日本語 にほんご"`.
class AnthySegment {
  const AnthySegment({
    required this.candidateCount,
    required this.best,
    required this.reading,
  });

  /// Number of candidates available for this segment (via [AnthyEgg.candidates]).
  final int candidateCount;

  /// The agent's current best candidate for this segment (the converted text).
  final String best;

  /// The hiragana reading this segment was produced from.
  final String reading;

  /// Parse one segment line: `"<ncands> <best> <reading>"`.
  ///
  /// Splits on the first two spaces only — the reading is taken verbatim as the
  /// remainder, and the best candidate is the single token between. (Anthy's
  /// best/reading tokens never contain spaces in practice, but taking the
  /// reading as the tail is the safe framing.)
  static AnthySegment parse(String line) {
    final firstSpace = line.indexOf(' ');
    if (firstSpace < 0) {
      throw AnthyEggException('malformed segment line: "$line"');
    }
    final secondSpace = line.indexOf(' ', firstSpace + 1);
    if (secondSpace < 0) {
      throw AnthyEggException('malformed segment line: "$line"');
    }
    final ncands = int.tryParse(line.substring(0, firstSpace));
    if (ncands == null) {
      throw AnthyEggException('malformed segment count in: "$line"');
    }
    final best = line.substring(firstSpace + 1, secondSpace);
    final reading = line.substring(secondSpace + 1);
    return AnthySegment(candidateCount: ncands, best: best, reading: reading);
  }

  @override
  String toString() => 'AnthySegment($candidateCount, $best, $reading)';
}

/// The result of a CONVERT (or RESIZE-SEGMENT): an ordered list of segments.
/// [text] is the convenience join of every segment's best candidate.
class AnthyConversion {
  const AnthyConversion(this.segments);

  /// The segments, in left-to-right order.
  final List<AnthySegment> segments;

  /// The converted string: every segment's best candidate concatenated.
  String get text => segments.map((s) => s.best).join();

  @override
  String toString() => 'AnthyConversion("$text", ${segments.length} segments)';
}

/// Dart client for `anthy-agent --egg` — kana→kanji conversion.
///
/// Lifecycle: [start] (await banner + open a context) → any number of
/// [convert] / [candidates] / [selectCandidate] / [resizeSegment] /
/// [commit] → [close] (release the context + kill the process).
///
/// All commands are async and **serialized**: an internal FIFO request queue
/// guarantees only one command is in flight at a time, so the agent's
/// response lines can never interleave between two pending calls. Each
/// command knows its own response framing (`+OK`, a counted `+DATA` block, or
/// an error), so the parser reads exactly the lines that belong to it.
class AnthyEgg {
  AnthyEgg(this._process, {this.releaseTimeout = const Duration(seconds: 2)});

  final AnthyProcess _process;

  /// Upper bound on how long [close] waits for the agent to acknowledge
  /// RELEASE-CONTEXT before giving up and killing the process regardless.
  /// Cleanup must never block the caller indefinitely.
  final Duration releaseTimeout;

  /// Buffered lines from the agent not yet consumed by a response reader, plus
  /// the waiter a reader parks on when it needs the next line.
  final List<String> _lineBuffer = <String>[];
  Completer<String>? _lineWaiter;

  /// FIFO of pending commands; only the head is actively reading the stream.
  /// The queue is non-generic (the per-command result type is hidden behind
  /// [_Pending]) so no invariant cast is needed to store mixed `T`s.
  final List<_Pending> _queue = <_Pending>[];
  bool _draining = false;

  StreamSubscription<String>? _sub;
  bool _started = false;
  bool _closed = false;
  Future<void>? _closeFuture;
  int? _contextId;

  /// The opened context id (valid after [start]); exposed for diagnostics.
  int? get contextId => _contextId;

  /// Whether `anthy-agent` is resolvable on PATH (a cheap pre-flight check so
  /// callers can disable IME features gracefully when it is not installed).
  static Future<bool> isAvailable({
    String executable = anthyExecutableName,
  }) async {
    // Resolves a PATH lookup without launching the agent. On a host with no
    // process facility (every browser) this reports false, so callers disable
    // IME features by the same path they would on a desktop that simply lacks
    // the binary — no separate web branch needed at the call site.
    return hostExecutableExists(executable);
  }

  /// Await the startup banner, open a conversion context, and remember its id.
  ///
  /// Idempotent-ish: calling it twice throws (a context is already open).
  Future<void> start() async {
    if (_started) {
      throw AnthyEggException('AnthyEgg already started');
    }
    _started = true;
    _sub = _process.lines.listen(
      _onLine,
      onError: _onStreamError,
      onDone: _onStreamDone,
    );

    // 1) Banner: `Anthy (Version 0.4) [] : Nice to meet you.` — wait for it.
    await _awaitBanner();

    // 2) Open a context. The literal `#18` selects UTF-8 for both directions.
    //    Reply is `+OK <ctxid>`.
    final ctx = await _enqueue<int>(
      'NEW-CONTEXT INPUT=#18 OUTPUT=#18',
      _readOkInt,
    );
    _contextId = ctx;
  }

  /// Convert a hiragana string into segmented kana→kanji output.
  Future<AnthyConversion> convert(String hiragana) {
    final ctx = _ctx();
    return _enqueue<AnthyConversion>('CONVERT $ctx $hiragana', _readConvert);
  }

  /// List candidate strings for [segment]. [first] is the starting index and
  /// [count] the maximum number requested (the agent may return fewer).
  Future<List<String>> candidates(
    int segment, {
    int first = 0,
    int count = 16,
  }) {
    final ctx = _ctx();
    return _enqueue<List<String>>(
      'GET-CANDIDATES $ctx $segment $first $count',
      _readCandidates,
    );
  }

  /// Choose candidate [index] for [segment]. Resolves on `+OK`.
  Future<void> selectCandidate(int segment, int index) {
    final ctx = _ctx();
    return _enqueue<void>('SELECT-CANDIDATE $ctx $segment $index', _readOk);
  }

  /// Resize [segment] and get the re-segmented conversion. `dir` 0 grows the
  /// segment (the empirically-pinned behavior); other values shrink it.
  Future<AnthyConversion> resizeSegment(int segment, {int dir = 0}) {
    final ctx = _ctx();
    return _enqueue<AnthyConversion>(
      'RESIZE-SEGMENT $ctx $segment $dir',
      _readResize,
    );
  }

  /// Finalize the conversion. `learn: true` (mode 0) commits and writes the
  /// learning to `~/.anthy`; `learn: false` (mode 1) discards (cancel/Esc).
  /// Resolves on `+OK`.
  Future<void> commit({bool learn = true}) {
    final ctx = _ctx();
    final mode = learn ? 0 : 1;
    return _enqueue<void>('COMMIT $ctx $mode', _readOk);
  }

  /// Release the context and kill the subprocess. Safe to call more than once
  /// (concurrent / repeat calls return the same in-flight close).
  Future<void> close() {
    return _closeFuture ??= _close();
  }

  Future<void> _close() async {
    // Release the context first (best-effort) — this must happen *before*
    // `_closed` is set, otherwise [_enqueue] would reject it.
    //
    // Bounded by [releaseTimeout]: cleanup must never hang the caller, so if
    // the agent is wedged and never acknowledges RELEASE-CONTEXT we give up and
    // proceed to kill the process anyway.
    final ctx = _contextId;
    if (ctx != null) {
      try {
        await _enqueue<void>(
          'RELEASE-CONTEXT $ctx',
          _readOk,
        ).timeout(releaseTimeout);
      } catch (_) {
        // Best-effort: the agent may already be gone / unresponsive — proceed.
      }
    }
    _closed = true;
    await _sub?.cancel();
    _sub = null;
    await _process.kill();
    // Fail any commands still parked (shouldn't normally happen).
    _failPending(AnthyEggException('AnthyEgg closed'));
  }

  // --- command queue -------------------------------------------------------

  int _ctx() {
    final ctx = _contextId;
    if (ctx == null) {
      throw AnthyEggException('AnthyEgg.start() must be awaited first');
    }
    return ctx;
  }

  /// Enqueue [command]: write it to the agent and parse its response with
  /// [reader]. Only one command's reader runs at a time (FIFO), so responses
  /// never interleave.
  Future<T> _enqueue<T>(String command, _ResponseReader<T> reader) {
    if (_closed) {
      return Future<T>.error(AnthyEggException('AnthyEgg is closed'));
    }
    final pending = _PendingCommand<T>(command, reader);
    _queue.add(pending);
    _drain();
    return pending.future;
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final pending = _queue.first;
        _process.send(pending.command);
        await pending.execute(_nextLine);
        // Remove the command we just ran. Guard against the queue having been
        // cleared concurrently by [_failPending] (e.g. the stream closed while
        // this reader was parked) — only drop it if it is still at the head.
        if (_queue.isNotEmpty && identical(_queue.first, pending)) {
          _queue.removeAt(0);
        }
      }
    } finally {
      _draining = false;
    }
  }

  void _failPending(Object error) {
    final pendings = List<_Pending>.from(_queue);
    _queue.clear();
    for (final p in pendings) {
      p.fail(error);
    }
  }

  // --- line plumbing -------------------------------------------------------

  void _onLine(String line) {
    final waiter = _lineWaiter;
    if (waiter != null && !waiter.isCompleted) {
      _lineWaiter = null;
      waiter.complete(line);
    } else {
      _lineBuffer.add(line);
    }
  }

  void _onStreamError(Object error, StackTrace st) {
    final waiter = _lineWaiter;
    if (waiter != null && !waiter.isCompleted) {
      _lineWaiter = null;
      waiter.completeError(error, st);
    }
    _failPending(AnthyEggException('agent stream error: $error'));
  }

  void _onStreamDone() {
    final waiter = _lineWaiter;
    if (waiter != null && !waiter.isCompleted) {
      _lineWaiter = null;
      waiter.completeError(
        AnthyEggException('agent stream closed unexpectedly'),
      );
    }
    _failPending(AnthyEggException('agent stream closed'));
  }

  /// Pull the next line — from the buffer if available, otherwise park on a
  /// waiter the stream callback completes. Only one reader pulls at a time.
  Future<String> _nextLine() {
    if (_lineBuffer.isNotEmpty) {
      return Future<String>.value(_lineBuffer.removeAt(0));
    }
    final waiter = Completer<String>();
    _lineWaiter = waiter;
    return waiter.future;
  }

  /// Consume lines until the banner is seen. Tolerates leading blank lines.
  Future<void> _awaitBanner() async {
    while (true) {
      final line = await _nextLine();
      if (line.trim().isEmpty) continue;
      if (line.startsWith('Anthy')) return;
      // Any non-banner, non-blank first line is unexpected.
      _throwIfError(line);
      // Otherwise tolerate and keep reading (defensive).
    }
  }

  // --- response readers ----------------------------------------------------
  //
  // Each reader is handed a `pull` that yields the next logical line. It reads
  // exactly the lines belonging to its command's response and returns the
  // parsed value, throwing [AnthyEggException] on an error line.

  /// `+OK` (value ignored).
  Future<void> _readOk(_LinePuller pull) async {
    final line = await pull();
    _throwIfError(line);
    if (!line.startsWith('+OK')) {
      throw AnthyEggException('expected +OK, got: "$line"');
    }
  }

  /// `+OK <int>` → the trailing integer (used for NEW-CONTEXT's ctx id).
  Future<int> _readOkInt(_LinePuller pull) async {
    final line = await pull();
    _throwIfError(line);
    if (!line.startsWith('+OK')) {
      throw AnthyEggException('expected +OK, got: "$line"');
    }
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      throw AnthyEggException('expected "+OK <id>", got: "$line"');
    }
    final id = int.tryParse(parts[1]);
    if (id == null) {
      throw AnthyEggException('expected an integer id in: "$line"');
    }
    return id;
  }

  /// CONVERT: `+DATA <start> <reserved> <nsegments>` + nsegments segment lines
  /// + a trailing blank line. nsegments is the 3rd header field.
  Future<AnthyConversion> _readConvert(_LinePuller pull) =>
      _readSegments(pull, segmentCountField: 2);

  /// RESIZE-SEGMENT: `+DATA <ctx> <n> <nsegments>` + nsegments segment lines +
  /// a trailing blank line. nsegments is also the 3rd header field (the middle
  /// field differs from CONVERT but the segment count is still last).
  Future<AnthyConversion> _readResize(_LinePuller pull) =>
      _readSegments(pull, segmentCountField: 2);

  /// Shared CONVERT/RESIZE reader: parse the `+DATA` header, read the segment
  /// count from header field [segmentCountField] (0-based, excluding the
  /// `+DATA` token), then read that many segment lines and skip the blank
  /// terminator.
  Future<AnthyConversion> _readSegments(
    _LinePuller pull, {
    required int segmentCountField,
  }) async {
    final header = await pull();
    _throwIfError(header);
    if (!header.startsWith('+DATA')) {
      throw AnthyEggException('expected +DATA, got: "$header"');
    }
    final fields = header.split(RegExp(r'\s+'));
    // fields[0] == '+DATA'; data fields start at index 1.
    final idx = segmentCountField + 1;
    if (fields.length <= idx) {
      throw AnthyEggException('malformed +DATA header: "$header"');
    }
    final n = int.tryParse(fields[idx]);
    if (n == null) {
      throw AnthyEggException('malformed segment count in: "$header"');
    }
    final segments = <AnthySegment>[];
    for (var i = 0; i < n; i++) {
      final line = await pull();
      segments.add(AnthySegment.parse(line));
    }
    await _skipBlankTerminator(pull);
    return AnthyConversion(segments);
  }

  /// GET-CANDIDATES: `+DATA <ctx> <ncands>` + ncands candidate lines + a
  /// trailing blank line. The count is the 2nd header field.
  Future<List<String>> _readCandidates(_LinePuller pull) async {
    final header = await pull();
    _throwIfError(header);
    if (!header.startsWith('+DATA')) {
      throw AnthyEggException('expected +DATA, got: "$header"');
    }
    final fields = header.split(RegExp(r'\s+'));
    if (fields.length < 3) {
      throw AnthyEggException('malformed +DATA header: "$header"');
    }
    final n = int.tryParse(fields[2]);
    if (n == null) {
      throw AnthyEggException('malformed candidate count in: "$header"');
    }
    final cands = <String>[];
    for (var i = 0; i < n; i++) {
      cands.add(await pull());
    }
    await _skipBlankTerminator(pull);
    return cands;
  }

  /// Consume the single blank line that terminates a `+DATA` block.
  ///
  /// Robust to a missing terminator: if the next available line is non-blank
  /// (e.g. another response header arriving immediately), push it back so the
  /// following reader sees it.
  Future<void> _skipBlankTerminator(_LinePuller pull) async {
    final line = await pull();
    if (line.trim().isNotEmpty) {
      // Not the expected blank — return it to the buffer for the next reader.
      _lineBuffer.insert(0, line);
    }
  }

  void _throwIfError(String line) {
    if (line.startsWith('-')) {
      throw AnthyEggException(line);
    }
  }
}

/// Pulls the next logical response line (see [AnthyEgg._nextLine]).
typedef _LinePuller = Future<String> Function();

/// Parses a command's framed response from a [_LinePuller].
typedef _ResponseReader<T> = Future<T> Function(_LinePuller pull);

/// A queued command. The base is intentionally non-generic so the request
/// queue can hold commands of mixed result type without an (invalid,
/// invariant) cast; the concrete [_PendingCommand] hides `T` behind
/// [execute]/[fail] and its own typed [Completer].
abstract class _Pending {
  String get command;

  /// Run the command's reader against [pull] and settle the future.
  Future<void> execute(_LinePuller pull);

  /// Settle the future with [error] (used when the stream dies).
  void fail(Object error);
}

class _PendingCommand<T> implements _Pending {
  _PendingCommand(this.command, this._reader);

  @override
  final String command;

  final _ResponseReader<T> _reader;
  final Completer<T> _completer = Completer<T>();

  /// The future handed back to the caller of the command.
  Future<T> get future => _completer.future;

  @override
  Future<void> execute(_LinePuller pull) async {
    try {
      final value = await _reader(pull);
      if (!_completer.isCompleted) _completer.complete(value);
    } on AnthyEggException catch (e) {
      if (!_completer.isCompleted) _completer.completeError(e);
    } catch (e, st) {
      if (!_completer.isCompleted) _completer.completeError(e, st);
    }
  }

  @override
  void fail(Object error) {
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}
