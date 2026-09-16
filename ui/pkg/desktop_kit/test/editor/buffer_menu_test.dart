// Pure rendering + line->name addressing for the in-buffer `*Buffer List*`
// (Emacs list-buffers). No Flutter, no widget — the inverse pair
// renderBufferMenu / bufferMenuNameAt must agree on where each row lands.
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('renderBufferMenu', () {
    test('emits the header then one line per row; current row marked with .',
        () {
      const List<BufferMenuRow> rows = <BufferMenuRow>[
        (name: 'scratch.org', current: true, lineCount: 12, byteCount: 384),
        (name: '*shell*', current: false, lineCount: 3, byteCount: 91),
      ];
      final List<String> lines = renderBufferMenu(rows).split('\n');

      expect(lines.length, kBufferMenuHeaderLines + rows.length);
      expect(lines[0], contains('Buffer'));
      expect(lines[0], contains('Lines'));
      expect(lines[0], contains('Bytes'));
      // The current buffer's row starts with the '.' marker; others a space.
      expect(lines[kBufferMenuHeaderLines + 0], startsWith('.'));
      expect(lines[kBufferMenuHeaderLines + 0], contains('scratch.org'));
      expect(lines[kBufferMenuHeaderLines + 0], contains('12'));
      expect(lines[kBufferMenuHeaderLines + 0], contains('384'),
          reason: 'the byte count is rendered in the Bytes column');
      expect(lines[kBufferMenuHeaderLines + 1], startsWith(' '));
      expect(lines[kBufferMenuHeaderLines + 1], contains('*shell*'));
      expect(lines[kBufferMenuHeaderLines + 1], contains('3'));
      expect(lines[kBufferMenuHeaderLines + 1], contains('91'));
    });

    test('no rows -> header only', () {
      final List<String> lines =
          renderBufferMenu(const <BufferMenuRow>[]).split('\n');
      expect(lines.length, kBufferMenuHeaderLines);
    });

    test('a long name overflows the column rather than truncating', () {
      const String long = '*a-very-long-buffer-name-well-past-the-column*';
      final String text = renderBufferMenu(
        const <BufferMenuRow>[
          (name: long, current: false, lineCount: 1, byteCount: 7)
        ],
      );
      expect(text, contains(long)); // never clipped
    });
  });

  group('bufferMenuNameAt (inverse of the row layout)', () {
    const List<BufferMenuRow> rows = <BufferMenuRow>[
      (name: 'a.org', current: true, lineCount: 1, byteCount: 5),
      (name: 'b.org', current: false, lineCount: 2, byteCount: 15),
      (name: 'c.org', current: false, lineCount: 3, byteCount: 25),
    ];

    test('header lines address no row', () {
      expect(bufferMenuNameAt(rows, 0), isNull);
      expect(bufferMenuNameAt(rows, kBufferMenuHeaderLines - 1), isNull);
    });

    test('entry lines address rows in render order', () {
      expect(bufferMenuNameAt(rows, kBufferMenuHeaderLines + 0), 'a.org');
      expect(bufferMenuNameAt(rows, kBufferMenuHeaderLines + 1), 'b.org');
      expect(bufferMenuNameAt(rows, kBufferMenuHeaderLines + 2), 'c.org');
    });

    test('a line past the last row addresses nothing', () {
      expect(bufferMenuNameAt(rows, kBufferMenuHeaderLines + 3), isNull);
      expect(bufferMenuNameAt(rows, 999), isNull);
    });

    test('empty rows: every line addresses nothing', () {
      expect(bufferMenuNameAt(const <BufferMenuRow>[], 0), isNull);
      expect(bufferMenuNameAt(const <BufferMenuRow>[], 2), isNull);
    });
  });
}
