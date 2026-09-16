// Major mode, default-directory, the modified flag, the visited file path
// and search hits are buffer-local, like text/caret/mark/lastYankRange
// before them.
//
// Major mode is deliberately untyped ([Object]?) on the model — see
// [Buffer.mode]'s doc: which modes exist (org / dired / shell / a listing)
// is application vocabulary, and `desktop_kit` is shared UI components
// consumed by more than one host app, so the kit cannot import a host's mode
// enum. These fixtures store plain strings standing in for a real mode
// value; the seam behaves identically either way, since the model never
// inspects what it stores.
//
// searchHitsForBuffer / searchIndexForBuffer expose the HITS only — the
// isearch prompt and the typed query stay genuinely session-wide (there is
// exactly one minibuffer), so they are not part of this migration.
library;

import 'package:desktop_kit/src/editor/emacs_buffer.dart';
import 'package:desktop_kit/src/editor/emacs_search.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two buffers of different length AND line count, current = *scratch*.
/// Equal-shaped fixtures would let a value read from the wrong buffer look
/// plausible.
EmacsBuffer _two() {
  final EmacsBuffer b = EmacsBuffer(text: 'SCRATCH-ONE-LINE');
  b.newBuffer('notes');
  b.insert('n1\nn2\nn3\nn4\nn5');
  b.switchToBuffer(b.bufferNames.first);
  return b;
}

void main() {
  group('major mode is buffer-local', () {
    test('independent per buffer and survives a switch', () {
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      b.setModeForBuffer(scratch, 'org');
      b.setModeForBuffer('notes', 'fundamental');

      b.switchToBuffer('notes');
      b.switchToBuffer(scratch);

      expect(b.modeForBuffer(scratch), 'org');
      expect(b.modeForBuffer('notes'), 'fundamental');
    });

    test('setModeForBuffer on an unknown buffer is a no-op', () {
      final EmacsBuffer b = _two();
      b.setModeForBuffer('no-such-buffer', 'org');
      expect(b.modeForBuffer('no-such-buffer'), isNull);
    });
  });

  group('default directory is buffer-local', () {
    test('independent per buffer and survives a switch', () {
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      b.setDefaultDirectoryForBuffer(scratch, '/home/user/scratch');
      b.setDefaultDirectoryForBuffer('notes', '/home/user/notes');

      b.switchToBuffer('notes');
      b.switchToBuffer(scratch);

      expect(b.defaultDirectoryForBuffer(scratch), '/home/user/scratch');
      expect(b.defaultDirectoryForBuffer('notes'), '/home/user/notes');
    });
  });

  group('the visited file path is buffer-local', () {
    test('independent per buffer and survives a switch', () {
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      b.setVisitedFileForBuffer(scratch, '/tmp/scratch.org');
      b.setVisitedFileForBuffer('notes', '/tmp/notes.org');

      b.switchToBuffer('notes');
      b.switchToBuffer(scratch);

      expect(b.visitedFileForBuffer(scratch), '/tmp/scratch.org');
      expect(b.visitedFileForBuffer('notes'), '/tmp/notes.org');
    });
  });

  group('the modified flag is buffer-local', () {
    test('a freshly constructed buffer is not modified, even with seed text',
        () {
      final EmacsBuffer b = EmacsBuffer(text: 'SCRATCH-ONE-LINE');
      expect(b.modifiedForBuffer(b.currentBuffer), isFalse,
          reason: 'construction seeds text directly, bypassing the write '
              'path that sets the flag — matches Emacs: a freshly visited '
              'file is not modified');
    });

    test('editing one buffer does not mark another modified', () {
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      // notes received insert() during _two()'s setup, while IT was current;
      // scratch was only ever constructed.
      expect(b.modifiedForBuffer(scratch), isFalse);
      expect(b.modifiedForBuffer('notes'), isTrue);
    });

    test('editing the current buffer sets it', () {
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      b.insert('!');

      expect(b.modifiedForBuffer(scratch), isTrue);
    });

    test('survives a switch, and a host can clear it after a save', () {
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      b.insert('!');
      b.switchToBuffer('notes');
      b.switchToBuffer(scratch);
      expect(b.modifiedForBuffer(scratch), isTrue,
          reason: 'switching away and back must not clear it');

      b.setModifiedForBuffer(scratch, false);
      expect(b.modifiedForBuffer(scratch), isFalse);
    });
  });

  group('a new buffer gets sensible defaults', () {
    test('mode, directory, visited file are null; not modified; no hits', () {
      final EmacsBuffer b = _two();

      expect(b.modeForBuffer('notes'), isNull);
      expect(b.defaultDirectoryForBuffer('notes'), isNull);
      expect(b.visitedFileForBuffer('notes'), isNull);
      expect(b.searchHitsForBuffer('notes'), isEmpty);
      expect(b.searchIndexForBuffer('notes'), -1);
    });

    test('every *ForBuffer getter is null/empty for an unknown name', () {
      final EmacsBuffer b = _two();

      expect(b.modeForBuffer('no-such-buffer'), isNull);
      expect(b.defaultDirectoryForBuffer('no-such-buffer'), isNull);
      expect(b.visitedFileForBuffer('no-such-buffer'), isNull);
      expect(b.modifiedForBuffer('no-such-buffer'), isNull);
      expect(b.searchHitsForBuffer('no-such-buffer'), isEmpty);
      expect(b.searchIndexForBuffer('no-such-buffer'), -1);
    });
  });

  group('searchHitsForBuffer / searchIndexForBuffer', () {
    test('reports the hits recorded for the named buffer, not the current one',
        () {
      final EmacsBuffer b = EmacsBuffer(text: 'aXaXaXa');
      final String scratch = b.currentBuffer;
      b.newBuffer('notes');
      b.insert('bbb\nbXbXb\nccc');

      // 'notes' is current: search it for X (two hits: positions 5 and 7).
      // Leave the search OPEN rather than accepting/cancelling it —
      // promptAccept/promptCancel both close via _clearPrompt, which wipes
      // the hits of whichever buffer is current AT THAT MOMENT (real Emacs
      // isearch-done behaviour), so the buffer-local snapshot this test
      // wants is only observable before that happens.
      b.execute('isearchForward');
      b.promptChar('X');
      expect(b.searchHits.length, 2);

      // Switch away without closing the search. The switch still resets
      // session state (including the now-stale prompt), but that reset
      // targets the ARRIVING buffer (scratch, whose hits are already
      // empty) — notes' hits, set before the switch, are untouched by it.
      b.switchToBuffer(scratch);

      // scratch has never been searched: empty, NOT notes' leftover hits —
      // the failure this pins is a stale/shared search highlight bleeding
      // into a buffer that was never searched, the search twin of the mark
      // bleeding across buffers that buffer_local_mark_test.dart pins.
      expect(b.searchHitsForBuffer(scratch), isEmpty);
      expect(b.searchIndexForBuffer(scratch), -1);

      // notes keeps what it found while it was current, readable without
      // switching back to it — this is what lets an inactive split window
      // paint ITS buffer's highlights.
      expect(b.searchHitsForBuffer('notes').length, 2);
    });
  });

  group('renaming preserves all buffer-local state', () {
    test(
        'mode, directory, visited path, modified and search hits all '
        'survive a rename', () {
      final EmacsBuffer b = EmacsBuffer(text: 'aXbXc');
      final String original = b.currentBuffer;

      b.setModeForBuffer(original, 'org');
      b.setDefaultDirectoryForBuffer(original, '/tmp/dir');
      b.setVisitedFileForBuffer(original, '/tmp/dir/file.org');
      b.insert('!'); // marks it modified
      b.execute('isearchForward');
      b.promptChar('X'); // left OPEN — see the note in the search group above
      final List<SearchHit> hitsBefore = b.searchHitsForBuffer(original);
      expect(hitsBefore, isNotEmpty);

      b.renameBuffer('renamed.org');
      final String renamed = b.currentBuffer;
      expect(renamed, 'renamed.org');

      expect(b.modeForBuffer(renamed), 'org');
      expect(b.defaultDirectoryForBuffer(renamed), '/tmp/dir');
      expect(b.visitedFileForBuffer(renamed), '/tmp/dir/file.org');
      expect(b.modifiedForBuffer(renamed), isTrue);
      expect(b.searchHitsForBuffer(renamed).length, hitsBefore.length);

      // The old name is simply gone — re-keyed, not copied.
      expect(b.modeForBuffer(original), isNull);
    });
  });
}
