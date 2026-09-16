// bury-buffer: send a buffer to the end of the buffer list without killing
// it. The only app-side alternative to a package-level primitive was
// killBufferNamed + newBuffer, which is a brand-new Buffer object and so
// silently drops undo/redo (and everything else buffer-local) — exactly the
// kill+recreate this method exists to avoid. These tests pin down: ordering
// (the whole point — bufferNames/bufferSnapshots derive from map iteration
// order), the ring-order switch-away target when the buried buffer is
// current (including the wrap-around case), and — the one that actually
// proves this isn't kill+recreate — that text, caret, undo/redo, mark and
// defaultDirectory/visitedFile all survive a round trip through being
// buried, via the SAME Buffer object (identity-checked, not just
// value-checked).
library;

import 'package:desktop_kit/src/editor/emacs_buffer.dart';
import 'package:desktop_kit/src/keymap/mark_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EmacsBuffer.buryBuffer — ordering', () {
    test(
        'moves the named buffer to the end of the list, preserving the '
        'relative order of every other buffer', () {
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      b.newBuffer('alpha');
      b.newBuffer('beta');
      b.newBuffer('gamma');
      b.switchToBuffer('*scratch*'); // current buffer is NOT the one buried
      expect(b.bufferNames,
          <String>['*scratch*', '*shell*', 'alpha', 'beta', 'gamma']);

      b.buryBuffer('alpha');

      expect(b.bufferNames,
          <String>['*scratch*', '*shell*', 'beta', 'gamma', 'alpha']);
      expect(b.currentBuffer, '*scratch*',
          reason: 'burying a buffer that is not current must not move the '
              'selection');
    });

    test('burying the already-last buffer is a no-op on order', () {
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      b.newBuffer('alpha');
      b.switchToBuffer('*scratch*');
      expect(b.bufferNames, <String>['*scratch*', '*shell*', 'alpha']);

      b.buryBuffer('alpha');

      expect(b.bufferNames, <String>['*scratch*', '*shell*', 'alpha']);
    });
  });

  group('EmacsBuffer.buryBuffer — switching away from the current buffer', () {
    test('switches to the next buffer in ring order', () {
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      b.newBuffer('alpha');
      b.newBuffer('beta');
      b.switchToBuffer('alpha');
      expect(b.bufferNames, <String>['*scratch*', '*shell*', 'alpha', 'beta']);

      b.buryBuffer('alpha');

      expect(b.currentBuffer, 'beta',
          reason: 'ring-order successor of alpha, matching the target '
              'killBufferNamed switches to when the KILLED buffer is '
              'current');
      expect(b.bufferNames, <String>['*scratch*', '*shell*', 'beta', 'alpha']);
    });

    test(
        'wraps around to the first buffer when the buried current buffer '
        'is last in ring order', () {
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      b.newBuffer('alpha'); // current; list = [*scratch*, *shell*, alpha]

      b.buryBuffer('alpha');

      expect(b.currentBuffer, '*scratch*',
          reason: 'ring order wraps past the end back to the first buffer');
      expect(b.bufferNames, <String>['*scratch*', '*shell*', 'alpha']);
    });

    test('burying a buffer that is not current never changes the selection',
        () {
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      b.newBuffer('alpha');
      b.switchToBuffer('*shell*');

      b.buryBuffer('alpha');

      expect(b.currentBuffer, '*shell*');
    });
  });

  group('EmacsBuffer.buryBuffer — state preservation (not kill+recreate)', () {
    test(
        'text, caret, undo/redo depth, mark/region and '
        'defaultDirectory/visitedFile all survive being buried and '
        'switched back to, via the SAME Buffer object', () {
      final EmacsBuffer b = EmacsBuffer(text: 'SCRATCH-BODY');
      b.newBuffer('notes');
      b.insert('n1\nn2\nn3'); // distinct shape from scratch's body
      b.insert('-edit-1');
      b.insert('-edit-2');
      // Leaves an undo entry AND a redo entry — proves both stacks, not
      // just one, survive the round trip.
      expect(b.execute('undo'), isTrue);

      b.caret = 3;
      expect(b.execute('setMark'), isTrue);
      b.caret = 6;

      b.setDefaultDirectoryForBuffer('notes', '/tmp/notes-dir');
      b.setVisitedFileForBuffer('notes', '/tmp/notes-dir/notes.org');

      final String expectedText = b.text;
      final int expectedCaret = b.caret;
      final int expectedUndoDepth = b.undoDepthForBuffer('notes')!;
      final int expectedRedoDepth = b.redoDepthForBuffer('notes')!;
      final Region? expectedRegion = b.region;
      expect(expectedRedoDepth, greaterThan(0),
          reason: 'sanity check on the fixture: the undo above must leave '
              'a redo entry to prove redo (not just undo) survives');
      expect(expectedRegion, isNotNull,
          reason: 'sanity check on the fixture: the mark must actually be '
              'set for the region assertion below to mean anything');

      // Captured BEFORE burying — proves the SAME object survives.
      // killBufferNamed + newBuffer would hand back a brand-new Buffer with
      // none of the state above; only identity, not value equality, can
      // rule that out.
      final Buffer liveNotes = b.bufferNamed('notes')!;

      // 'notes' is current, so burying it switches away first.
      b.buryBuffer('notes');
      expect(b.currentBuffer, isNot('notes'));
      expect(b.bufferNames.last, 'notes',
          reason: 'the buried buffer must be at the end of the list');
      expect(identical(b.bufferNamed('notes'), liveNotes), isTrue,
          reason: 'buryBuffer must reuse the SAME Buffer object — a new '
              'object here would mean this silently became kill+recreate');

      b.switchToBuffer('notes');
      expect(b.text, expectedText,
          reason: 'text must be untouched by being buried');
      expect(b.caret, expectedCaret,
          reason: 'caret position must be untouched by being buried');
      expect(b.undoDepthForBuffer('notes'), expectedUndoDepth,
          reason: 'undo history must survive burying, unlike kill+recreate');
      expect(b.redoDepthForBuffer('notes'), expectedRedoDepth,
          reason: 'redo history must survive too');
      expect(b.region, expectedRegion,
          reason: 'the mark/region must survive burying');
      expect(b.defaultDirectoryForBuffer('notes'), '/tmp/notes-dir');
      expect(b.visitedFileForBuffer('notes'), '/tmp/notes-dir/notes.org');

      // Undo/redo must still actually WORK after the round trip, not just
      // report a nonzero depth.
      expect(b.execute('redo'), isTrue);
      expect(b.execute('undo'), isTrue);
      expect(b.execute('undo'), isTrue);
    });
  });

  group(
      'EmacsBuffer.buryBuffer — refusals are no-ops with a status, never '
      'a throw', () {
    test('an unknown buffer name is a no-op', () {
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      final List<String> namesBefore = List<String>.from(b.bufferNames);
      final String currentBefore = b.currentBuffer;

      b.buryBuffer('does-not-exist');

      expect(b.bufferNames, namesBefore);
      expect(b.currentBuffer, currentBefore);
      expect(b.status, contains('No such buffer'));
    });

    test('refuses to bury the sole remaining buffer', () {
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      b.killBufferNamed('*shell*'); // leaves exactly one buffer
      expect(b.bufferNames, <String>['*scratch*']);

      b.buryBuffer('*scratch*');

      expect(b.bufferNames, <String>['*scratch*']);
      expect(b.currentBuffer, '*scratch*');
      expect(b.status, contains('Cannot bury the sole remaining buffer'));
    });

    test(
        'an unknown name is reported as such even with a single buffer — '
        'the existence check wins over the sole-buffer refusal', () {
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      b.killBufferNamed('*shell*');
      expect(b.bufferNames, <String>['*scratch*']);

      b.buryBuffer('ghost');

      expect(b.status, contains('No such buffer: ghost'));
    });
  });
}
