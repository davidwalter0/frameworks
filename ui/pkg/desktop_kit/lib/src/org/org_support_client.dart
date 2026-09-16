// Dart client for the Go org support binary.
//
// Protocol: JSON-lines over stdio.
//   Request:  {"id": <int>, "verb": <string>, "params": <object>}
//   Response: {"id": <int>, "ok": <bool>, "result": <object>?, "error": <string>?}
//
// All positions exchanged with the support binary are 0-based LINE indices
// (never byte/character offsets), matching the seam contract in
// docs/design/go-support-binary-seam.org: Go decides WHAT (org structure,
// tangle, execute), Dart decides HOW IT LOOKS (rendering, folding, faces).
library org_support_client;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Raised when the support binary returns an error response
/// (`{"ok": false, "error": "..."}`) for a given request.
class OrgSupportException implements Exception {
  OrgSupportException(this.verb, this.message);

  final String verb;
  final String message;

  @override
  String toString() => 'OrgSupportException($verb): $message';
}

/// Raised when the transport itself fails (process exit, malformed
/// framing, decode failure) rather than the binary reporting a verb-level
/// error.
class OrgSupportTransportException implements Exception {
  OrgSupportTransportException(this.message);

  final String message;

  @override
  String toString() => 'OrgSupportTransportException: $message';
}

/// A single org heading as reported by the `structure` verb.
///
/// [line] is the 0-based line index of the heading itself.
class OrgOutlineNode {
  const OrgOutlineNode({
    required this.line,
    required this.level,
    required this.title,
    this.todo = '',
  });

  factory OrgOutlineNode.fromJson(Map<String, dynamic> json) {
    return OrgOutlineNode(
      line: (json['line'] as num).toInt(),
      level: (json['level'] as num).toInt(),
      title: json['title'] as String? ?? '',
      todo: json['todo'] as String? ?? '',
    );
  }

  final int line;
  final int level;
  final String title;
  final String todo;
}

/// A single `#+begin_src` block as reported by the `structure` verb.
/// [startLine]/[endLine] bound the whole block (including the
/// `#+begin_src`/`#+end_src` delimiter lines); [contentStartLine]/
/// [contentEndLine] bound the body only. All 0-based, inclusive.
class OrgBlock {
  const OrgBlock({
    required this.startLine,
    required this.endLine,
    required this.contentStartLine,
    required this.contentEndLine,
    required this.lang,
    this.headerArgs = const <String, String>{},
  });

  factory OrgBlock.fromJson(Map<String, dynamic> json) {
    return OrgBlock(
      startLine: (json['startLine'] as num).toInt(),
      endLine: (json['endLine'] as num).toInt(),
      contentStartLine: (json['contentStartLine'] as num).toInt(),
      contentEndLine: (json['contentEndLine'] as num).toInt(),
      lang: json['lang'] as String? ?? '',
      headerArgs: (json['headerArgs'] as Map<dynamic, dynamic>?)?.map(
            (dynamic k, dynamic v) => MapEntry<String, String>(
              k as String,
              v as String,
            ),
          ) ??
          const <String, String>{},
    );
  }

  final int startLine;
  final int endLine;
  final int contentStartLine;
  final int contentEndLine;
  final String lang;
  final Map<String, String> headerArgs;
}

/// The result of a `structure` call: the outline headings plus the
/// `#+begin_src` blocks in the text.
class OrgStructure {
  const OrgStructure({
    required this.headings,
    required this.blocks,
  });

  factory OrgStructure.fromJson(Map<String, dynamic> json) {
    return OrgStructure(
      headings: (json['headings'] as List<dynamic>? ?? const <dynamic>[])
          .map(
              (dynamic e) => OrgOutlineNode.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      blocks: (json['blocks'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => OrgBlock.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  final List<OrgOutlineNode> headings;
  final List<OrgBlock> blocks;

  /// The block whose `#+begin_src`..`#+end_src` span contains [line], or
  /// null if [line] isn't inside any block. Used to resolve "the block
  /// at point" for C-c C-c.
  OrgBlock? blockContaining(int line) {
    for (final OrgBlock b in blocks) {
      if (line >= b.startLine && line <= b.endLine) return b;
    }
    return null;
  }
}

/// A single tangled output file as reported by the `tangle` verb.
/// [mode] is the file's permission bits as an octal string (e.g.
/// `"0644"`, `"0755"`).
class TangledFile {
  const TangledFile({
    required this.path,
    required this.content,
    this.mode = '0644',
  });

  factory TangledFile.fromJson(Map<String, dynamic> json) {
    return TangledFile(
      path: json['path'] as String? ?? '',
      content: json['content'] as String? ?? '',
      mode: json['mode'] as String? ?? '0644',
    );
  }

  final String path;
  final String content;
  final String mode;
}

/// The result of a `tangle` call.
class TangleResult {
  const TangleResult({required this.files});

  factory TangleResult.fromJson(Map<String, dynamic> json) {
    return TangleResult(
      files: (json['files'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => TangledFile.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }

  final List<TangledFile> files;
}

/// The result of an `execute` call for a single source block: combined
/// stdout+stderr output, and whether the interpreter exited cleanly
/// within the timeout.
class ExecuteResult {
  const ExecuteResult({
    required this.output,
    required this.ok,
  });

  factory ExecuteResult.fromJson(Map<String, dynamic> json) {
    return ExecuteResult(
      output: json['output'] as String? ?? '',
      ok: json['ok'] as bool? ?? false,
    );
  }

  final String output;
  final bool ok;
}

/// The result of a `resultsRange` call: where a `#+RESULTS:` block for
/// a given source block belongs. When no `#+RESULTS:` block already
/// follows the source block, [replaceStartLine]/[replaceEndLine] are
/// null and [insertLine] is right after `#+end_src`. When one exists,
/// [replaceStartLine]/[replaceEndLine] bound it (inclusive) and
/// [insertLine] equals [replaceStartLine].
class ResultsRange {
  const ResultsRange({
    required this.insertLine,
    this.replaceStartLine,
    this.replaceEndLine,
  });

  factory ResultsRange.fromJson(Map<String, dynamic> json) {
    return ResultsRange(
      insertLine: (json['insertLine'] as num?)?.toInt() ?? 0,
      replaceStartLine: (json['replaceStartLine'] as num?)?.toInt(),
      replaceEndLine: (json['replaceEndLine'] as num?)?.toInt(),
    );
  }

  final int insertLine;
  final int? replaceStartLine;
  final int? replaceEndLine;

  /// True when an existing `#+RESULTS:` block should be replaced rather
  /// than a fresh one inserted.
  bool get hasExisting => replaceStartLine != null && replaceEndLine != null;
}

/// Transport-level interface to the org support binary. Implementations
/// exchange JSON objects keyed by verb; callers normally use the typed
/// wrapper methods below rather than [call] directly.
abstract class OrgSupport {
  /// Sends a single request for [verb] with [params] and returns the
  /// decoded `result` object. Throws [OrgSupportException] on a
  /// verb-level error response, or [OrgSupportTransportException] on a
  /// transport failure.
  Future<Map<String, dynamic>> call(String verb, Map<String, dynamic> params);

  /// Releases any resources (e.g. kills the child process). Safe to call
  /// more than once.
  void dispose();

  // -- Typed convenience wrappers -------------------------------------

  Future<OrgStructure> structure(String text) async {
    final Map<String, dynamic> result =
        await call('structure', <String, dynamic>{'text': text});
    return OrgStructure.fromJson(result);
  }

  Future<TangleResult> tangle(
    String text,
    String docDir, {
    bool dryRun = false,
  }) async {
    final Map<String, dynamic> result = await call('tangle', <String, dynamic>{
      'text': text,
      'docDir': docDir,
      'dryRun': dryRun,
    });
    return TangleResult.fromJson(result);
  }

  Future<ExecuteResult> execute(
    String text,
    int blockStartLine, {
    int timeoutSec = 30,
  }) async {
    final Map<String, dynamic> result = await call('execute', <String, dynamic>{
      'text': text,
      'blockStartLine': blockStartLine,
      'timeoutSec': timeoutSec,
    });
    return ExecuteResult.fromJson(result);
  }

  Future<ResultsRange> resultsRange(String text, int blockStartLine) async {
    final Map<String, dynamic> result =
        await call('resultsRange', <String, dynamic>{
      'text': text,
      'blockStartLine': blockStartLine,
    });
    return ResultsRange.fromJson(result);
  }
}

/// Process-backed [OrgSupport] implementation. Spawns the org support
/// binary once, frames requests/responses as newline-delimited JSON on
/// stdin/stdout, and matches responses to pending requests by `id`.
class OrgSupportProcess extends OrgSupport {
  OrgSupportProcess(this.binaryPath);

  /// Default location of the org support binary relative to the repo
  /// root, matching the build layout under `tools/orgsupport/`.
  static String defaultBinaryPath(String repoRoot) =>
      '$repoRoot/tools/orgsupport/bin/orgsupport';

  final String binaryPath;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  bool _disposed = false;
  Future<Process>? _starting;

  Future<Process> _ensureStarted() {
    return _starting ??= Process.start(binaryPath, const <String>[]).then(
      (Process process) {
        _process = process;
        _stdoutSub = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(_onLine, onError: _onStreamError, onDone: _onDone);
        _stderrSub = process.stderr.listen((_) {});
        return process;
      },
    );
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      _failAllPending('malformed response line: $e');
      return;
    }
    final int? id = (decoded['id'] as num?)?.toInt();
    if (id == null) {
      return;
    }
    final Completer<Map<String, dynamic>>? completer = _pending.remove(id);
    if (completer == null) {
      return;
    }
    final bool ok = decoded['ok'] as bool? ?? false;
    if (ok) {
      final Map<String, dynamic> result =
          (decoded['result'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      completer.complete(result);
    } else {
      final String error = decoded['error'] as String? ?? 'unknown error';
      completer.completeError(
        OrgSupportException(decoded['verb'] as String? ?? '', error),
      );
    }
  }

  void _onStreamError(Object error) {
    _failAllPending('stdout stream error: $error');
  }

  void _onDone() {
    _failAllPending('org support process exited');
  }

  void _failAllPending(String message) {
    final Iterable<Completer<Map<String, dynamic>>> completers =
        _pending.values.toList(growable: false);
    _pending.clear();
    for (final Completer<Map<String, dynamic>> completer in completers) {
      if (!completer.isCompleted) {
        completer.completeError(OrgSupportTransportException(message));
      }
    }
  }

  @override
  Future<Map<String, dynamic>> call(
      String verb, Map<String, dynamic> params) async {
    if (_disposed) {
      throw OrgSupportTransportException('call after dispose: $verb');
    }
    final Process process = await _ensureStarted();
    final int id = _nextId++;
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final String request = jsonEncode(<String, dynamic>{
      'id': id,
      'verb': verb,
      'params': params,
    });
    process.stdin.writeln(request);
    return completer.future;
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _failAllPending('disposed');
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _process?.kill();
    _process = null;
  }
}

/// In-memory fake [OrgSupport] for tests. Configure canned results per
/// verb via [respond] (or [respondWith] for dynamic responses), and read
/// back invocation history via [calls].
class OrgSupportFake extends OrgSupport {
  final Map<String, Map<String, dynamic>> _cannedResults =
      <String, Map<String, dynamic>>{};
  final Map<String, String> _cannedErrors = <String, String>{};
  final Map<String, Map<String, dynamic> Function(Map<String, dynamic>)>
      _dynamicResponses =
      <String, Map<String, dynamic> Function(Map<String, dynamic>)>{};

  /// Recorded `(verb, params)` calls, in invocation order.
  final List<({String verb, Map<String, dynamic> params})> calls =
      <({String verb, Map<String, dynamic> params})>[];

  bool disposed = false;

  /// Registers a canned successful [result] for [verb].
  void respond(String verb, Map<String, dynamic> result) {
    _cannedResults[verb] = result;
    _cannedErrors.remove(verb);
    _dynamicResponses.remove(verb);
  }

  /// Registers a canned error response for [verb]; calling it throws
  /// [OrgSupportException] with [message].
  void respondError(String verb, String message) {
    _cannedErrors[verb] = message;
    _cannedResults.remove(verb);
    _dynamicResponses.remove(verb);
  }

  /// Registers a dynamic responder for [verb], invoked with the call's
  /// params to compute the result.
  void respondWith(
    String verb,
    Map<String, dynamic> Function(Map<String, dynamic> params) responder,
  ) {
    _dynamicResponses[verb] = responder;
    _cannedResults.remove(verb);
    _cannedErrors.remove(verb);
  }

  @override
  Future<Map<String, dynamic>> call(
      String verb, Map<String, dynamic> params) async {
    calls.add((verb: verb, params: params));
    final String? error = _cannedErrors[verb];
    if (error != null) {
      throw OrgSupportException(verb, error);
    }
    final Map<String, dynamic> Function(Map<String, dynamic>)? dynamicFn =
        _dynamicResponses[verb];
    if (dynamicFn != null) {
      return dynamicFn(params);
    }
    final Map<String, dynamic>? result = _cannedResults[verb];
    if (result == null) {
      throw OrgSupportException(verb, 'no canned response registered');
    }
    return result;
  }

  @override
  void dispose() {
    disposed = true;
  }
}
