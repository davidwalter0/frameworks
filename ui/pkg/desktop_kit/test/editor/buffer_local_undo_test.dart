// Undo/redo become buffer-local, like text, caret, mark and lastYankRange
// before them.
//
// This is the riskiest step of the buffer-object migration. An undo
// [_Snapshot] is `(text, caret)` with NO buffer identity attached — the
// snapshot itself cannot say which buffer it came from. Before this change
// that was safe because `switchToBuffer` discarded both stacks on every
// switch: a mis-attributed snapshot was simply gone before it could ever be
// replayed against the wrong buffer. Now that the stacks persist per buffer
// (see `Buffer.undo` / `Buffer.redo` in emacs_buffer.dart), a bug that reads
// from or writes to the wrong buffer's stack no longer throws — it silently
// REPLACES that buffer's live text with content that has nothing to do with
// it. These tests exist to catch exactly that class of failure, so the
// fixtures deliberately use buffers of different length AND different line
// count: same-shaped fixtures let a wrong-buffer offset or a wrong-buffer
// snapshot look plausible and pass anyway.
library;

import 'package:desktop_kit/src/editor/emacs_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('undo/redo survive a buffer switch and stay per-buffer', () {
    test(
        'undo in A after switching through B reverts only A\'s edit, '
        'with the caret landing back where A\'s edit started', () {
      final EmacsBuffer b = EmacsBuffer(text: 'SCRATCH-SINGLE-LINE-BODY');
      final String scratch = b.currentBuffer;
      final String aOriginal = b.text;
      final int aOriginalCaret = b.caret; // 0

      b.caret = b.text.length;
      final int aCaretBeforeEdit = b.caret;
      b.insert('-EDITED-A');
      final String aAfterEdit = b.text;

      b.newBuffer('notes');
      // Different length AND different line count from scratch's body.
      b.insert('n1\nn2\nn3');
      final String bBeforeEdit = b.text;
      b.insert('-more-B-text-here');
      final String bAfterEdit = b.text;

      b.switchToBuffer(scratch);
      expect(b.text, aAfterEdit,
          reason: 'switching away and back must show A live, unedited by '
              'anything that happened in B');

      expect(b.execute('undo'), isTrue);
      expect(b.text, aOriginal,
          reason: "undo in A must revert A's own edit, not a snapshot "
              'that belongs to B');
      expect(b.caret, aCaretBeforeEdit,
          reason: 'the caret must land where A\'s edit started, not '
              'wherever B\'s caret happened to be');

      // A is now fully unwound; B must still show its own, untouched edit.
      b.switchToBuffer('notes');
      expect(b.text, bAfterEdit,
          reason: "undoing in A must never have touched B's text");
      expect(aOriginalCaret, 0); // sanity on the fixture itself.
      expect(bBeforeEdit, isNot(aOriginal));
    });

    test('undo in B after editing both buffers reverts only B\'s edit', () {
      final EmacsBuffer b = EmacsBuffer(text: 'ONE-LINE-SCRATCH-TEXT-HERE');
      final String scratch = b.currentBuffer;
      b.caret = b.text.length;
      b.insert('-A-edit-1');
      final String aAfterEdit = b.text;

      b.newBuffer('notes');
      b.insert('n1\nn2\nn3\nn4'); // different length + line count than A
      final String bBeforeEdit = b.text;
      b.insert('-B-edit-1');

      // B is current: undo must act on B only.
      expect(b.execute('undo'), isTrue);
      expect(b.text, bBeforeEdit,
          reason: "undo, dispatched while B is current, must revert B's "
              'own last edit');

      b.switchToBuffer(scratch);
      expect(b.text, aAfterEdit,
          reason: 'A must be untouched by an undo executed while B was '
              'current');
    });
  });

  group('the kill ring is global but undo is local', () {
    test(
        'kill in A, yank in B: each buffer undoes its own history '
        'independently of the shared kill ring', () {
      final EmacsBuffer b = EmacsBuffer(text: 'KILL-ME-FROM-A-REMAINDER');
      final String scratch = b.currentBuffer;
      b.caret = 0;
      expect(b.execute('setMark'), isTrue);
      b.caret = 7; // region = 'KILL-ME'
      expect(b.execute('killRegion'), isTrue);
      final String aAfterKill = b.text;
      expect(aAfterKill, '-FROM-A-REMAINDER');

      b.newBuffer('notes');
      b.insert('n1\nn2\nn3'); // different shape from A's remainder text
      final String bBeforeYank = b.text;
      expect(b.execute('yank'), isTrue);
      final String bAfterYank = b.text;
      expect(bAfterYank, isNot(bBeforeYank));
      expect(bAfterYank.contains('KILL-ME'), isTrue,
          reason: 'the kill ring is GLOBAL — B can yank what A killed');

      // Undo in B reverts only B's yank; the global kill ring is untouched
      // as an object, but each buffer's undo stack is its own.
      expect(b.execute('undo'), isTrue);
      expect(b.text, bBeforeYank,
          reason: "undo in B must revert B's own yank only");

      b.switchToBuffer(scratch);
      expect(b.text, aAfterKill,
          reason: 'switching back to A must show A live and unaffected '
              'by anything undone in B');
      expect(b.execute('undo'), isTrue);
      expect(b.text, 'KILL-ME-FROM-A-REMAINDER',
          reason: "undo in A must revert A's own kill, independent of "
              "B's separate undo history");
    });
  });

  group('killBufferNamed releases the killed buffer\'s stacks', () {
    test(
        'the Buffer object\'s own undo/redo lists are cleared, not just the '
        'map entry pointing at it', () {
      final EmacsBuffer b = EmacsBuffer(text: 'SCRATCH-BODY-ONE-LINE');
      b.newBuffer('notes');
      b.insert('n1\nn2\nn3\nn4\nn5'); // multi-line, distinct from scratch
      b.insert('-edit-1');
      b.insert('-edit-2');

      // Capture the LIVE object before killing it. This is the point of the
      // test: `_buffers.remove(name)` alone would already make
      // `undoDepthForBuffer('notes')` report null (the map entry is gone),
      // which would pass even if the stacks on the object itself were left
      // full — proving nothing about whether killBufferNamed released them
      // explicitly. Holding a reference from BEFORE the kill lets the test
      // see the object's own state afterward, independent of the map.
      final Buffer notes = b.bufferNamed('notes')!;
      expect(notes.undo, isNotEmpty);

      // 'notes' is current, so killBufferNamed must switch away first, then
      // kill and release its stacks.
      b.killBufferNamed('notes');

      expect(b.bufferNames.contains('notes'), isFalse);
      expect(notes.undo, isEmpty,
          reason: 'killBufferNamed must clear the killed buffer\'s own undo '
              'stack explicitly, not rely on nothing else holding a '
              'reference to release it');
      expect(notes.redo, isEmpty);
      expect(b.undoDepthForBuffer('notes'), isNull);
      expect(b.redoDepthForBuffer('notes'), isNull);
    });
  });

  group('the per-buffer undo depth cap', () {
    test(
        'pushing past the cap trims the oldest snapshots, keeping the '
        'newest', () {
      // Must track `_maxUndoDepth` in emacs_buffer.dart — bump both together
      // if the default ever changes.
      const int cap = 200;
      const int pushes = cap + 50;

      final EmacsBuffer b = EmacsBuffer(text: 'X');
      final String scratch = b.currentBuffer;
      for (var i = 0; i < pushes; i++) {
        b.insert('a');
      }

      final int? depth = b.undoDepthForBuffer(scratch);
      expect(depth, cap,
          reason: 'the stack must be trimmed down to the cap, not left to '
              'grow with every push');

      // Undo exactly `depth` times: this must exhaust the stack (proving no
      // MORE than `cap` snapshots survived) while landing on a text that is
      // NOT the original — proving the oldest snapshots (which alone could
      // reach back to 'X') were the ones trimmed, not the newest.
      for (var i = 0; i < depth!; i++) {
        expect(b.execute('undo'), isTrue,
            reason: 'expected $depth retained snapshots to still be '
                'poppable (failed at step $i)');
      }
      expect(b.canUndo, isFalse,
          reason: 'exactly $cap snapshots were retained; the stack must '
              'now be empty');
      expect(b.text, isNot('X'),
          reason: 'the snapshot capturing the ORIGINAL pre-edit text was '
              'the oldest, and must have been trimmed by the cap — '
              'reaching it would mean the cap kept the wrong end');
    });
  });

  group('redo is buffer-local too', () {
    test('redoing in one buffer never touches another buffer\'s redo stack',
        () {
      final EmacsBuffer b = EmacsBuffer(text: 'SCRATCH-ONE-LINE-BODY-TEXT');
      final String scratch = b.currentBuffer;
      b.insert('-A-edit');
      final String aAfterEdit = b.text;
      expect(b.execute('undo'), isTrue);
      final String aAfterUndo = b.text;
      expect(b.canRedo, isTrue);

      b.newBuffer('notes');
      b.insert('n1\nn2\nn3\nn4\nn5'); // different length + line count than A
      final String bAfterEdit = b.text;
      expect(b.execute('undo'), isTrue);
      expect(b.canRedo, isTrue);

      // Redo in B (current) must only replay B's own redo entry.
      expect(b.execute('redo'), isTrue);
      expect(b.text, bAfterEdit, reason: "redo in B must restore B's own edit");

      b.switchToBuffer(scratch);
      expect(b.text, aAfterUndo,
          reason: 'A must still sit at its own undone state — redoing in '
              "B must not have consumed or touched A's redo stack");
      expect(b.canRedo, isTrue,
          reason: "A's redo entry must still be there after B redid "
              'independently');
      expect(b.execute('redo'), isTrue);
      expect(b.text, aAfterEdit,
          reason: "A's own redo must still work after B's independent "
              'redo');
    });
  });
}
