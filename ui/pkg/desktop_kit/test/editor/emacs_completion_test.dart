import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CompletionModel.matches', () {
    test('returns candidates starting with prefix, in original order', () {
      final model = CompletionModel(['find-file', 'find-name-dired', 'grep']);
      expect(model.matches('find-'), ['find-file', 'find-name-dired']);
    });

    test('returns empty list when no candidate matches', () {
      final model = CompletionModel(['find-file', 'grep']);
      expect(model.matches('zzz'), isEmpty);
    });

    test('empty prefix matches every candidate in original order', () {
      final model = CompletionModel(['b', 'a', 'c']);
      expect(model.matches(''), ['b', 'a', 'c']);
    });
  });

  group('CompletionModel.complete — common-prefix extension', () {
    test('extends prefix to the longest common completion', () {
      final model = CompletionModel([
        'find-file',
        'find-file-other-window',
        'find-function',
      ]);
      // Common completion among the three is "find-f".
      expect(model.complete('find-'), 'find-f');
    });

    test(
      'extension stops at the point candidates diverge',
      () {
        final model = CompletionModel(['switch-to-buffer', 'switch-window']);
        expect(model.complete('switch-'), 'switch-');
      },
    );
  });

  group('CompletionModel.complete — unique completion', () {
    test('returns the full candidate when exactly one match exists', () {
      final model = CompletionModel(['find-file', 'grep', 'occur']);
      expect(model.complete('find-'), 'find-file');
    });
  });

  group('CompletionModel.complete — no match', () {
    test('returns the prefix unchanged when nothing matches', () {
      final model = CompletionModel(['find-file', 'grep']);
      expect(model.complete('zzz'), 'zzz');
    });

    test('no-match leaves an empty cycle set', () {
      final model = CompletionModel(['find-file']);
      model.complete('zzz');
      expect(model.cycleMatches, isEmpty);
      expect(model.cycle(), isNull);
    });
  });

  group('CompletionModel cycling', () {
    test('TAB TAB walks matches in order and wraps around', () {
      final model = CompletionModel(['aa', 'ab', 'ac']);
      model.complete('a');
      expect(model.cycle(), 'aa');
      expect(model.cycle(), 'ab');
      expect(model.cycle(), 'ac');
      expect(model.cycle(), 'aa'); // wraps
    });

    test('cyclePrevious walks backwards and wraps', () {
      final model = CompletionModel(['aa', 'ab', 'ac']);
      model.complete('a');
      // Cycle position starts "before" the first match, so the first
      // cyclePrevious() steps one further back (wrapping) to the
      // second-to-last match, then continues walking backwards.
      expect(model.cyclePrevious(), 'ab');
      expect(model.cyclePrevious(), 'aa');
      expect(model.cyclePrevious(), 'ac'); // wraps to the last match
      expect(model.cyclePrevious(), 'ab'); // wraps again
    });

    test('a fresh complete() call resets the cycle position', () {
      final model = CompletionModel(['aa', 'ab', 'ba', 'bb']);
      model.complete('a');
      expect(model.cycle(), 'aa');
      expect(model.cycle(), 'ab');

      // Editing the minibuffer to a new prefix restarts the cycle.
      model.complete('b');
      expect(model.cycleMatches, ['ba', 'bb']);
      expect(model.cycle(), 'ba');
    });

    test('resetCycle clears cycle state explicitly', () {
      final model = CompletionModel(['aa', 'ab']);
      model.complete('a');
      model.cycle();
      model.resetCycle();
      expect(model.activeCyclePrefix, isNull);
      expect(model.cycleMatches, isEmpty);
      expect(model.cycle(), isNull);
    });
  });

  group('CompletionModel case-insensitive option', () {
    test('matches ignore case when caseInsensitive is true', () {
      final model = CompletionModel([
        'Find-File',
        'Find-Function',
      ], caseInsensitive: true);
      expect(model.matches('find-'), ['Find-File', 'Find-Function']);
    });

    test('complete() common-prefix computation ignores case', () {
      final model = CompletionModel([
        'Find-File',
        'find-function',
      ], caseInsensitive: true);
      // Case-insensitive common prefix is "find-f" length-wise; returned
      // text is sliced from the first candidate's original casing.
      expect(model.complete('find-'), 'Find-F');
    });

    test('case-sensitive (default) matching excludes differently-cased', () {
      final model = CompletionModel(['Find-File', 'find-function']);
      expect(model.matches('find-'), ['find-function']);
      expect(model.matches('Find-'), ['Find-File']);
    });
  });
}
