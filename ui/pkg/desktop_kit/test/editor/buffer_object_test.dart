// Buffer IDENTITY and LIVENESS — the two invariants every later phase of the
// buffer-object migration rests on.
//
// Buffers used to be snapshots: `switchToBuffer` copied text and caret out of
// the departing buffer and into the arriving one. Anything else that wanted to
// be buffer-local (the mark, undo stacks, fold state) therefore had nowhere to
// live, because there was no object with a lifetime longer than a switch.
//
// Now `_buffers` holds live `Buffer` objects and the model's text/caret are
// views onto the current one. These tests pin that: the object survives
// switching and renaming, and reads of a non-current buffer see its real state
// rather than a stale copy. If either breaks, moving the mark or undo onto
// `Buffer` in a later phase corrupts data instead of failing loudly.
library;

import 'package:desktop_kit/src/editor/emacs_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buffer identity', () {
    test('switching away and back returns the SAME object', () {
      final EmacsBuffer b = EmacsBuffer(text: 'scratch body');
      final String scratch = b.currentBuffer;
      final Buffer original = b.current;

      b.newBuffer('notes');
      expect(b.current, isNot(same(original)));

      b.switchToBuffer(scratch);
      expect(b.current, same(original),
          reason: 'a switch must point at the existing buffer, not rebuild it '
              '— per-buffer state hangs off this identity');
    });

    test('renaming re-keys the same object rather than constructing a new one',
        () {
      final EmacsBuffer b = EmacsBuffer(text: 'hello');
      final Buffer before = b.current;

      b.renameBuffer('README.md');

      expect(b.currentBuffer, 'README.md');
      expect(b.current, same(before),
          reason: 'rename changes a name, not a document — rebuilding here '
              'would silently drop everything buffer-local');
      expect(b.current.text, 'hello');
    });

    test('a uniquified rename still preserves identity', () {
      final EmacsBuffer b = EmacsBuffer(text: 'first');
      b.newBuffer('README.md');
      b.switchToBuffer(b.bufferNames.first);
      final Buffer before = b.current;

      b.renameBuffer('README.md'); // collides -> README.md<2>

      expect(b.currentBuffer, 'README.md<2>');
      expect(b.current, same(before));
      expect(b.current.text, 'first');
    });
  });

  group('liveness — no snapshot to go stale', () {
    test('edits to the current buffer are visible through its name', () {
      // Text and caret are views onto the current Buffer, so there is no
      // window in which the map disagrees with the model.
      final EmacsBuffer b = EmacsBuffer(text: 'ab', caret: 2);
      final String name = b.currentBuffer;

      b.insert('c');

      expect(b.textForBuffer(name), 'abc');
      expect(b.caretForBuffer(name), b.caret);
      expect(b.bufferNamed(name)!.text, 'abc');
    });

    test('a background buffer reports its real contents, not a stale copy', () {
      // The buffers differ in length AND line count on purpose: equal-shaped
      // fixtures let a stale read pass by coincidence.
      final EmacsBuffer b = EmacsBuffer(text: 'S');
      final String scratch = b.currentBuffer;
      b.newBuffer('notes');
      b.insert('one\ntwo\nthree');
      b.switchToBuffer(scratch);

      b.appendToNamed('notes', '\nfour');

      expect(b.textForBuffer('notes'), 'one\ntwo\nthree\nfour');
      final snap = b.bufferSnapshots().firstWhere((s) => s.name == 'notes');
      expect(snap.lineCount, 4,
          reason: 'the buffer list must count the real buffer, not a snapshot');
      expect(snap.current, isFalse);
    });

    test('switching preserves each buffer\'s own text and caret', () {
      final EmacsBuffer b = EmacsBuffer(text: 'scratch');
      final String scratch = b.currentBuffer;
      b.caret = 3;

      b.newBuffer('notes');
      b.insert('notes body here');
      final int notesCaret = b.caret;

      b.switchToBuffer(scratch);
      expect(b.text, 'scratch');
      expect(b.caret, 3, reason: 'the caret is buffer-local');

      b.switchToBuffer('notes');
      expect(b.text, 'notes body here');
      expect(b.caret, notesCaret);
    });
  });

  group('appendToNamed — always end, caret forced (the documented contract)',
      () {
    test('lands after a caret sitting earlier in the buffer, and moves it', () {
      // A caret NOT already at the end (e.g. a user had positioned it inside
      // already-arrived output) still gets forced to the new end — this is
      // the exact behaviour the doc now names explicitly as the reason a
      // shell/REPL host needs appendToNamedAt instead.
      final EmacsBuffer b = EmacsBuffer(text: 'one\ntwo\n', caret: 4);

      b.appendToNamed(b.currentBuffer, 'three\n');

      expect(b.text, 'one\ntwo\nthree\n');
      expect(b.caret, b.text.length,
          reason: 'appendToNamed always forces the caret to the new end');
    });

    test('bypasses undo — the append cannot be undone', () {
      final EmacsBuffer b = EmacsBuffer(text: 'seed');
      final Buffer target = b.bufferNamed(b.currentBuffer)!;

      b.appendToNamed(b.currentBuffer, ' more');

      expect(target.undo, isEmpty);
    });
  });

  group('appendToNamedAt — comint-style splice at a caller-supplied mark', () {
    test('inserts at position, not at the end', () {
      final EmacsBuffer b = EmacsBuffer(text: 'scratch body');
      b.newBuffer('log'); // creates 'log' and switches to it
      b.insert('existing');

      b.appendToNamedAt('log', 0, 'HEAD ');

      expect(b.textForBuffer('log'), 'HEAD existing',
          reason: 'spliced at position 0, not appended after "existing"');
    });

    test(
        'a caret at/after the mark shifts by chunk.length — pending input '
        'keeps the same characters instead of being stranded', () {
      // Mirrors the real incident: a user has typed "ec" of "echo hi" at a
      // shell prompt "$ " (mark = 2, right after the prompt). Async output
      // ("job done\n") arrives and must land BEFORE "ec", not after it.
      final EmacsBuffer b = EmacsBuffer(text: r'$ ec', caret: 4);
      const int mark = 2; // start of the pending input, after the prompt

      b.appendToNamedAt(b.currentBuffer, mark, 'job done\n');

      expect(b.text, r'$ job done' '\n' r'ec');
      expect(b.caret, 4 + 'job done\n'.length,
          reason: 'the caret follows "ec" — it moved by exactly the '
              'inserted length, so it still points at the same two '
              'characters the user typed');

      // Continuing to type — a real edit, via the public insert() API — now
      // completes the ORIGINAL word in one place, unlike appendToNamed's
      // behaviour of stranding "ec" above the new output (see the
      // appendToNamed group above for that contrast).
      b.insert('ho hi');

      expect(b.text, r'$ job done' '\n' 'echo hi');
    });

    test('a caret before the mark is left untouched', () {
      final EmacsBuffer b = EmacsBuffer(text: 'abcXYZ', caret: 1);

      b.appendToNamedAt(b.currentBuffer, 3, '---');

      expect(b.text, 'abc---XYZ');
      expect(b.caret, 1,
          reason: 'nothing was inserted before the caret, so its absolute '
              'offset — and the character it points at — is unchanged');
    });

    test('position is clamped into [0, text.length]', () {
      final EmacsBuffer high = EmacsBuffer(text: 'abc');
      high.appendToNamedAt(high.currentBuffer, 999, 'Z');
      expect(high.text, 'abcZ');

      final EmacsBuffer low = EmacsBuffer(text: 'abc');
      low.appendToNamedAt(low.currentBuffer, -5, 'Z');
      expect(low.text, 'Zabc');
    });

    test('empty chunk is a no-op', () {
      final EmacsBuffer b = EmacsBuffer(text: 'abc', caret: 1);
      b.appendToNamedAt(b.currentBuffer, 0, '');
      expect(b.text, 'abc');
      expect(b.caret, 1);
    });

    test('unknown buffer name reports status and does not throw', () {
      final EmacsBuffer b = EmacsBuffer(text: 'abc');
      b.appendToNamedAt('no-such-buffer', 0, 'x');
      expect(b.status, 'No such buffer: no-such-buffer');
    });

    test('sets modified on the target buffer, current or not', () {
      final EmacsBuffer b = EmacsBuffer(text: 'scratch');
      final String scratch = b.currentBuffer;
      b.newBuffer('log');
      b.switchToBuffer(scratch);

      b.appendToNamedAt('log', 0, 'x');

      expect(b.bufferNamed('log')!.modified, isTrue);
    });

    test('bypasses undo — the splice cannot be undone', () {
      final EmacsBuffer b = EmacsBuffer(text: 'seed');
      final Buffer target = b.bufferNamed(b.currentBuffer)!;

      b.appendToNamedAt(b.currentBuffer, 0, 'more ');

      expect(target.undo, isEmpty);
    });

    test('a background buffer is spliced without becoming current', () {
      final EmacsBuffer b = EmacsBuffer(text: 'scratch');
      final String scratch = b.currentBuffer;
      b.newBuffer('shell');
      b.insert(r'$ ');
      b.switchToBuffer(scratch);

      b.appendToNamedAt('shell', 2, 'output\n');

      expect(b.currentBuffer, scratch, reason: 'splicing must not switch');
      expect(b.textForBuffer('shell'), r'$ output' '\n');
    });
  });
}
