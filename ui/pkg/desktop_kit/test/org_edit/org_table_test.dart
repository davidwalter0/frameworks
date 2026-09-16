import 'package:desktop_kit/desktop_kit_org_edit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isTableLine / isSeparatorLine', () {
    test('detects table rows with and without leading indent', () {
      expect(isTableLine('| a | b |'), isTrue);
      expect(isTableLine('  | a | b |'), isTrue);
      expect(isTableLine('not a table'), isFalse);
      expect(isTableLine(''), isFalse);
    });

    test('detects separator rows', () {
      expect(isSeparatorLine('|---+---|'), isTrue);
      expect(isSeparatorLine('|-----+-----|'), isTrue);
      expect(isSeparatorLine('| a | b |'), isFalse);
      expect(isSeparatorLine('not a table'), isFalse);
    });
  });

  group('alignTable — ragged column widths', () {
    test('pads every cell to the widest cell in its column', () {
      const String text = '| a | bb |\n'
          '| ccc | d |\n';
      final int caret = text.indexOf('a');
      final OrgEdit result = alignTable(text, caret);
      expect(
        result.text,
        '| a   | bb |\n'
        '| ccc | d  |\n',
      );
    });

    test('redraws a separator row to match recomputed widths', () {
      const String text = '| a | bb |\n'
          '|---+---|\n'
          '| ccc | d |\n';
      const int caret = 0;
      final OrgEdit result = alignTable(text, caret);
      expect(
        result.text,
        '| a   | bb |\n'
        '|-----+----|\n'
        '| ccc | d  |\n',
      );
    });

    test('handles a three-column ragged table', () {
      const String text = '| x | yy | z |\n'
          '| aaaa | b | ccccc |\n';
      final OrgEdit result = alignTable(text, 0);
      expect(
        result.text,
        '| x    | yy | z     |\n'
        '| aaaa | b  | ccccc |\n',
      );
    });

    test('is a no-op when the caret is not on a table line', () {
      const String text = 'plain text\nnot a table either\n';
      final OrgEdit result = alignTable(text, 3);
      expect(result.text, text);
      expect(result.caret, 3);
    });
  });

  group('alignTable — unicode cell content (ASCII-width limitation)', () {
    // NOTE: widths here are computed via String.length (code-unit count),
    // NOT display width. A CJK character like '中' has length 1 in Dart
    // (single UTF-16 code unit) but occupies 2 terminal display columns in
    // most monospace renderers, so a table mixing CJK and ASCII content
    // will align by code-unit count and can look visually ragged when
    // rendered — this module does not implement East-Asian-width-aware
    // padding (see the file-level doc comment in org_table.dart).
    test('pads CJK cell content by code-unit length, not display width', () {
      const String text = '| a | bb |\n'
          '| 中 | d |\n';
      final OrgEdit result = alignTable(text, 0);
      // '中' has String.length == 1, so column 0's width is max(1, 1) = 1,
      // matching the ASCII 'a' cell exactly (even though visually '中' is
      // twice as wide as 'a' in most fonts).
      expect(
        result.text,
        '| a | bb |\n'
        '| 中 | d  |\n',
      );
    });
  });

  group('alignTable — caret tracking', () {
    test('keeps the caret at the same offset within its cell after padding',
        () {
      // Caret sits after the 'c' in 'ccc' — offset 2 into that cell.
      const String text = '| a | bb |\n'
          '| ccc | d |\n';
      final int caretLine1Start = text.indexOf('| ccc');
      final int caret = caretLine1Start + '| cc'.length; // between c and c
      final OrgEdit result = alignTable(text, caret);
      // Cell 'ccc' is already at its natural width (3), so the row is
      // unchanged; the caret should land at the same logical spot.
      final int newLineStart = result.text.indexOf('| ccc');
      final int offsetInCell = result.caret - newLineStart - '| '.length;
      expect(offsetInCell, 2);
    });

    test('shifts the caret correctly when its own cell is NOT the widest', () {
      // Table: col0 max width 3 ('ccc'), caret on row0's short cell 'a'.
      const String text = '| a | bb |\n'
          '| ccc | d |\n';
      final int caret = text.indexOf('a') + 1; // after 'a'
      final OrgEdit result = alignTable(text, caret);
      const int newLineStart = 0; // first line still starts at 0
      final int offsetInCell = result.caret - newLineStart - '| '.length;
      expect(offsetInCell, 1); // still right after the single 'a' char
      expect(result.text.substring(0, 5), '| a  ');
    });
  });

  group('nextCell (TAB)', () {
    test('moves to the next cell on the same row', () {
      const String text = '| a | bb |\n'
          '| ccc | d |\n';
      final int caret = text.indexOf('a');
      final OrgEdit result = nextCell(text, caret);
      final int expectedCol = result.text.split('\n')[0].indexOf('bb');
      expect(result.caret, expectedCol);
    });

    test('wraps to the first cell of the next row', () {
      const String text = '| a | bb |\n'
          '| ccc | d |\n';
      final int caret = text.indexOf('bb');
      final OrgEdit result = nextCell(text, caret);
      final List<String> lines = result.text.split('\n');
      final int row1Start = lines[0].length + 1;
      final int expectedCol = row1Start + lines[1].indexOf('ccc');
      expect(result.caret, expectedCol);
    });

    test('skips a separator row when moving down', () {
      const String text = '| a | bb |\n'
          '|---+---|\n'
          '| ccc | d |\n';
      final int caret = text.indexOf('bb');
      final OrgEdit result = nextCell(text, caret);
      final List<String> lines = result.text.split('\n');
      final int row2Start = lines[0].length + 1 + lines[1].length + 1;
      final int expectedCol = row2Start + lines[2].indexOf('ccc');
      expect(result.caret, expectedCol);
    });

    test('appends a fresh empty row on the last cell of the last row', () {
      const String text = '| a | bb |\n'
          '| ccc | d |\n';
      final int caret = text.indexOf('d');
      final OrgEdit result = nextCell(text, caret);
      final List<String> lines = result.text.split('\n');
      expect(lines.length, 4); // 2 original rows + new row + trailing ''
      expect(lines[2], '|     |    |'); // new empty row, widths 3 and 2
      final int row2Start = lines[0].length + 1 + lines[1].length + 1;
      // Caret should land right in the first cell of the new row (right
      // after '| ').
      expect(result.caret, row2Start + 2);
    });
  });

  group('prevCell (Shift-TAB)', () {
    test('moves to the previous cell on the same row', () {
      const String text = '| a | bb |\n'
          '| ccc | d |\n';
      final int caret = text.indexOf('bb');
      final OrgEdit result = prevCell(text, caret);
      final int expectedCol = result.text.split('\n')[0].indexOf('a');
      expect(result.caret, expectedCol);
    });

    test('wraps to the last cell of the previous row', () {
      const String text = '| a | bb |\n'
          '| ccc | d |\n';
      final int caret = text.indexOf('ccc');
      final OrgEdit result = prevCell(text, caret);
      final int expectedCol = result.text.split('\n')[0].indexOf('bb');
      expect(result.caret, expectedCol);
    });

    test('skips a separator row when moving up', () {
      const String text = '| a | bb |\n'
          '|---+---|\n'
          '| ccc | d |\n';
      final int caret = text.indexOf('ccc');
      final OrgEdit result = prevCell(text, caret);
      final int expectedCol = result.text.split('\n')[0].indexOf('bb');
      expect(result.caret, expectedCol);
    });

    test('is a no-op at the table\'s first cell', () {
      const String text = '| a | bb |\n'
          '| ccc | d |\n';
      final int caret = text.indexOf('a');
      final OrgEdit result = prevCell(text, caret);
      final int expectedCol = result.text.split('\n')[0].indexOf('a');
      expect(result.caret, expectedCol);
    });
  });

  group('newRowBelow', () {
    test('inserts a fresh empty row right after the caret\'s row', () {
      const String text = '| a | bb |\n'
          '| ccc | d |\n';
      final int caret = text.indexOf('a');
      final OrgEdit result = newRowBelow(text, caret);
      final List<String> lines = result.text.split('\n');
      expect(lines.length, 4); // original 2 rows + new row + trailing ''
      expect(lines[1], '|     |    |');
      expect(lines[2], '| ccc | d  |');
      // Caret lands in the new row's first cell.
      final int row1Start = lines[0].length + 1;
      expect(result.caret, row1Start + 2);
    });

    test('is a no-op when the caret is not on a table line', () {
      const String text = 'plain text\n';
      final OrgEdit result = newRowBelow(text, 3);
      expect(result.text, text);
      expect(result.caret, 3);
    });
  });

  group('tableLineRange', () {
    test('finds the contiguous table range around the caret line', () {
      final List<String> lines = <String>[
        'preamble',
        '| a | b |',
        '|---+---|',
        '| c | d |',
        'postamble',
      ];
      final ({int start, int end}) range = tableLineRange(lines, 2);
      expect(range.start, 1);
      expect(range.end, 4);
    });

    test('returns an empty range off a table line', () {
      final List<String> lines = <String>['not a table'];
      final ({int start, int end}) range = tableLineRange(lines, 0);
      expect(range.start, 0);
      expect(range.end, 0);
    });
  });
}
