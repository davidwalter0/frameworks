// The buffer model's report-only classification and the historical tty
// control-code translations (C-j/C-m -> newline, C-i -> tab).
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('report-only classification', () {
    test('names the non-buffer actions, not the editing ones', () {
      expect(EmacsBuffer.reportOnlyIntents, contains('save'));
      expect(EmacsBuffer.reportOnlyIntents, contains('help'));
      // recenter now drives the widget's viewport (scrolls the caret line to
      // centre), so it is no longer a report-only intent.
      expect(EmacsBuffer.reportOnlyIntents, isNot(contains('recenter')));
      expect(EmacsBuffer.reportOnlyIntents, isNot(contains('killLine')));
      expect(EmacsBuffer.reportOnlyIntents, isNot(contains('newline')));
      expect(EmacsBuffer.reportOnlyIntents, isNot(contains('insertTab')));
    });

    test('a report-only intent is handled but leaves the text unchanged', () {
      final b = EmacsBuffer(text: 'hello', caret: 0);
      expect(b.execute('save'), isTrue);
      expect(b.text, 'hello');
      expect(b.status, isNotEmpty);
    });
  });

  group('terminal / whitespace translations', () {
    test('newline inserts a line feed at the caret and advances it', () {
      final b = EmacsBuffer(text: 'ab', caret: 1);
      expect(b.execute('newline'), isTrue);
      expect(b.text, 'a\nb');
      expect(b.caret, 2);
    });

    test('insertTab inserts a tab at the caret and advances it', () {
      final b = EmacsBuffer(text: 'ab', caret: 1);
      expect(b.execute('insertTab'), isTrue);
      expect(b.text, 'a\tb');
      expect(b.caret, 2);
    });

    test('a translation edit can be undone', () {
      final b = EmacsBuffer(text: 'ab', caret: 1);
      b.execute('newline');
      b.execute('undo');
      expect(b.text, 'ab');
    });
  });
}
