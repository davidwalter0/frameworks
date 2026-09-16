import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseGnomeFontName', () {
    test('strips surrounding quotes + trailing point size', () {
      expect(parseGnomeFontName("'Cantarell 11'"), 'Cantarell');
    });
    test('keeps a weight word but drops the size', () {
      expect(parseGnomeFontName("'Cantarell Bold 11'"), 'Cantarell Bold');
    });
    test('value with no trailing size is returned unchanged', () {
      expect(parseGnomeFontName('Ubuntu'), 'Ubuntu');
    });
    test('handles a decimal point size', () {
      expect(parseGnomeFontName("'Noto Sans 10.5'"), 'Noto Sans');
    });
    test('empty / blank → null', () {
      expect(parseGnomeFontName(''), isNull);
      expect(parseGnomeFontName("''"), isNull);
    });
  });
}
