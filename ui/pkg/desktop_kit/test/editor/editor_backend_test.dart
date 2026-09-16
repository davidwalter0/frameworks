// Tests for the [EditorBackend] seam and [EmacsBuffer.executeAsync] — using
// an in-memory FAKE backend, never a real subprocess. What a REAL backend
// (textloom's GoElispBackend, over a persistent elispd subprocess) does with an
// actual elisp evaluator is a different, out-of-process concern; this file
// pins the CONTRACT [EmacsBuffer] holds any backend to: which intents ever
// reach it, how its result is applied, and — the sharp edge — exactly how
// undo/redo stay coherent when some commands go through a backend and
// others do not.
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal, deterministic stand-in for a real backend. Applies elisp-like
/// semantics ONLY for the handful of behaviours these tests need (kill/yank
/// append-merge via [lastCommand], a small bounded undo list) — it is a test
/// double, not a second implementation of the real evaluator.
class FakeBackend implements EditorBackend {
  FakeBackend(this._supported);

  final Set<String> _supported;

  /// Every request this backend was asked to run, in order — so a test can
  /// assert exactly what [EmacsBuffer] sent (in particular [lastCommand]
  /// threading, which is the subtlest part of the contract).
  final List<EditorBackendRequest> calls = <EditorBackendRequest>[];

  /// When set, the NEXT [run] call returns this instead of computing a
  /// result — how tests exercise the `ok: false` fallback path.
  EditorBackendResult? nextResult;

  String _kill = '';
  final List<String> _undo = <String>[]; // whole-text snapshots, oldest last

  @override
  bool supports(String intentId) => _supported.contains(intentId);

  @override
  Future<EditorBackendResult> run(
      String intentId, EditorBackendRequest request) async {
    calls.add(request);
    final EditorBackendResult? forced = nextResult;
    if (forced != null) {
      nextResult = null;
      return forced;
    }

    switch (intentId) {
      case 'moveForwardChar':
        final int p = (request.point + 1).clamp(0, request.text.length);
        return EditorBackendResult(
            ok: true, point: p, status: 'Forward char (fake)');
      case 'moveLineStart':
        return const EditorBackendResult(
            ok: true, point: 0, status: 'Beginning of line (fake)');
      case 'killLine':
        // Mirrors real kill-line's documented shape (see the elisp
        // runtime's killring.go): to end of line, NOT including the
        // newline — except when point is already at an empty line, where
        // it kills exactly the newline.
        final String rest = request.text.substring(request.point);
        final int nl = rest.indexOf('\n');
        final int end = nl == 0
            ? request.point + 1 // empty line: kill just the newline
            : (nl < 0 ? request.text.length : request.point + nl);
        if (end == request.point)
          return const EditorBackendResult(ok: false); // nothing to kill
        final String killed = request.text.substring(request.point, end);
        _kill = request.lastCommand == 'kill-region' ? '$_kill$killed' : killed;
        _undo.add(request.text);
        final String newText = request.text.substring(0, request.point) +
            request.text.substring(end);
        return EditorBackendResult(
          ok: true,
          text: newText,
          point: request.point,
          thisCommand: 'kill-region',
          status: 'Killed line (fake)',
        );
      case 'yank':
        if (_kill.isEmpty) return const EditorBackendResult(ok: false);
        _undo.add(request.text);
        final String newText = request.text.substring(0, request.point) +
            _kill +
            request.text.substring(request.point);
        return EditorBackendResult(
          ok: true,
          text: newText,
          point: request.point + _kill.length,
          markSet: true,
          markValue: request.point,
          thisCommand: 'yank',
          status: 'Yank (fake)',
        );
      case 'undo':
        if (_undo.isEmpty) return const EditorBackendResult(ok: false);
        final String prev = _undo.removeLast();
        return EditorBackendResult(
            ok: true,
            text: prev,
            point: 0,
            thisCommand: 'undo',
            status: 'Undo (fake)');
    }
    return const EditorBackendResult(ok: false);
  }
}

void main() {
  group('executeAsync — no backend installed', () {
    test('behaves exactly like execute for every intent', () async {
      final b = EmacsBuffer(text: 'abc', caret: 0);
      final bool viaAsync = await b.executeAsync('moveForwardChar');
      expect(viaAsync, isTrue);
      expect(b.caret, 1);
      expect(b.status, 'Forward char'); // the Dart-native status, unchanged
    });
  });

  group('executeAsync — backend installed but does not support this id', () {
    test('falls through to execute unchanged', () async {
      final b = EmacsBuffer(text: 'abc\ndef', caret: 0);
      b.editorBackend = FakeBackend(<String>{'moveForwardChar'});
      final bool handled = await b.executeAsync('moveLineEnd');
      expect(handled, isTrue);
      expect(b.caret, 3); // Dart-native moveLineEnd ran, not the backend
    });
  });

  group('executeAsync — backend-routed motion', () {
    test('applies point, breaks kill sequence, pushes NO undo', () async {
      final b = EmacsBuffer(text: 'abc', caret: 0);
      final backend = FakeBackend(<String>{'moveForwardChar'});
      b.editorBackend = backend;
      final bool handled = await b.executeAsync('moveForwardChar');
      expect(handled, isTrue);
      expect(b.caret, 1);
      expect(b.canUndo, isFalse, reason: 'a pure motion must not be undoable');
      expect(backend.calls, hasLength(1));
      expect(backend.calls.single.lastCommand, isEmpty,
          reason: 'nothing preceded it via this backend');
    });
  });

  group('executeAsync — backend-routed edit', () {
    test('kill-line mutates text/caret and IS undoable via Dart-native undo',
        () async {
      final b = EmacsBuffer(text: 'abc\ndef\n', caret: 0);
      b.editorBackend = FakeBackend(<String>{'killLine'});
      final bool handled = await b.executeAsync('killLine');
      expect(handled, isTrue);
      expect(b.text, '\ndef\n');
      expect(b.status, 'Killed line (fake)');
      expect(b.canUndo, isTrue);
      // 'undo' is NOT in this backend's supported set, so it runs Dart's
      // OWN _undoOp — proving the backend-routed edit pushed a real,
      // Dart-visible undo snapshot.
      final bool undone = b.execute('undo');
      expect(undone, isTrue);
      expect(b.text, 'abc\ndef\n');
    });

    test(
        'lastCommand threads kill-region across two consecutive kills, matching append-merge',
        () async {
      final b = EmacsBuffer(text: 'abc\ndef\nghi\n', caret: 0);
      final backend = FakeBackend(<String>{'killLine'});
      b.editorBackend = backend;
      await b.executeAsync('killLine');
      await b.executeAsync('killLine');
      expect(backend.calls, hasLength(2));
      expect(backend.calls[0].lastCommand, isEmpty);
      expect(backend.calls[1].lastCommand, 'kill-region',
          reason: 'the FIRST kill\'s thisCommand must be echoed back');
    });

    test('a non-backend intent in between resets lastCommand to empty',
        () async {
      final b = EmacsBuffer(text: 'abc\ndef\nghi\n', caret: 0);
      final backend = FakeBackend(<String>{'killLine'});
      b.editorBackend = backend;
      await b.executeAsync('killLine');
      await b.executeAsync('moveLineEnd'); // not in the backend's supported set
      await b.executeAsync('killLine');
      expect(backend.calls, hasLength(2));
      expect(backend.calls[1].lastCommand, isEmpty,
          reason: 'the intervening Dart-native motion must break the chain');
    });
  });

  group('executeAsync — undo/redo lockstep (the cross-cutting case)', () {
    test(
        'kill, kill, yank, then three backend-routed undos land exactly back at the start',
        () async {
      const original = 'abc\ndef\nghi\n';
      final b = EmacsBuffer(text: original, caret: 0);
      b.editorBackend = FakeBackend(<String>{'killLine', 'yank', 'undo'});

      await b.executeAsync('killLine'); // "abc" killed -> "\ndef\nghi\n"
      await b.executeAsync('killLine'); // "\n" appended -> "def\nghi\n"
      await b.executeAsync('yank'); // re-inserts "abc\n" -> "abc\ndef\nghi\n"
      expect(b.text, original);

      expect(await b.executeAsync('undo'), isTrue); // undoes the yank
      expect(b.text, 'def\nghi\n');
      expect(await b.executeAsync('undo'), isTrue); // undoes the 2nd kill
      expect(b.text, '\ndef\nghi\n');
      expect(await b.executeAsync('undo'), isTrue); // undoes the 1st kill
      expect(b.text, original);
      expect(b.canUndo, isFalse);
    });

    test('redo (Dart-native, NOT backend-routed) replays a backend-undone edit',
        () async {
      final b = EmacsBuffer(text: 'abc\ndef\n', caret: 0);
      b.editorBackend = FakeBackend(<String>{'killLine', 'undo'});
      await b.executeAsync('killLine'); // -> "\ndef\n"
      expect(b.text, '\ndef\n');
      await b.executeAsync('undo'); // backend undo -> "abc\ndef\n"
      expect(b.text, 'abc\ndef\n');
      // redo is never routed to any backend in this arm's slice; it must
      // still work, reading the SAME _undo/_redo stacks the backend undo
      // just kept in lockstep.
      final bool redone = b.execute('redo');
      expect(redone, isTrue);
      expect(b.text, '\ndef\n');
    });

    test(
        'undo falls back to Dart-native history once the backend has none left',
        () async {
      final b = EmacsBuffer(text: 'abc', caret: 3);
      // A Dart-native edit BEFORE any backend is installed.
      b.execute('deleteWordBackward'); // "abc" -> "" (Dart-native undo entry)
      expect(b.text, '');
      b.editorBackend =
          FakeBackend(<String>{'undo'}); // backend has NOTHING to undo
      final bool handled = await b.executeAsync('undo');
      expect(handled, isTrue,
          reason:
              'must fall back to the Dart-native undo, not report unhandled');
      expect(b.text, 'abc',
          reason: 'the pre-backend Dart edit must still be reachable');
    });
  });

  group('executeAsync — backend failure falls back to the Dart-native path',
      () {
    test(
        'yank with an empty backend kill ring falls back to the (also empty) Dart yank, cleanly',
        () async {
      final b = EmacsBuffer(text: 'abc', caret: 0);
      b.editorBackend = FakeBackend(<String>{'yank'});
      final bool handled = await b.executeAsync('yank');
      // _dispatch('yank') itself returns true even with an empty ring (it
      // inserts the empty string and still reports "Yank" — an existing
      // Dart-native quirk this fallback inherits unchanged, not something
      // this seam introduces).
      expect(handled, isTrue);
      expect(b.text, 'abc', reason: 'nothing to yank on either side');
      expect(b.status, 'Yank');
    });

    test('an explicit ok:false result (not just "unsupported") also falls back',
        () async {
      final b = EmacsBuffer(text: 'abc', caret: 1);
      final backend = FakeBackend(<String>{'moveForwardChar'});
      backend.nextResult = const EditorBackendResult(ok: false);
      b.editorBackend = backend;
      final bool handled = await b.executeAsync('moveForwardChar');
      expect(handled, isTrue); // Dart's own moveForwardChar still ran
      expect(b.caret, 2);
      expect(backend.calls, hasLength(1),
          reason: 'the backend WAS asked, and declined');
    });
  });

  group('executeAsync — numeric prefix argument repeats through the backend',
      () {
    test('C-u killLine calls the backend four times (bare C-u = 4)', () async {
      final b = EmacsBuffer(text: 'a\nb\nc\nd\ne\n', caret: 0);
      final backend = FakeBackend(<String>{'killLine'});
      b.editorBackend = backend;
      b.universalArgument(); // C-u, no digits -> pendingArg = 4
      final bool handled = await b.executeAsync('killLine');
      expect(handled, isTrue);
      expect(backend.calls, hasLength(4));
      // Each real line takes TWO kill-lines to fully remove (content, then
      // the newline it left behind at the now-empty line) — standard Emacs
      // kill-line behaviour. Four kills therefore fully remove exactly two
      // lines ("a\n", "b\n"), leaving "c\nd\ne\n".
      expect(b.text, 'c\nd\ne\n');
      expect(b.status, contains('(x4)'),
          reason: 'mirrors execute()\'s own "(x\$arg)" suffix');
    });
  });
}
