import 'package:desktop_kit/desktop_kit_charts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('niceCeil', () {
    test('rounds up to 1/2/5 x a power of ten', () {
      expect(niceCeil(0), 1);
      expect(niceCeil(-5), 1);
      expect(niceCeil(0.7), 1);
      expect(niceCeil(1.4), 2);
      expect(niceCeil(3), 5);
      expect(niceCeil(7), 10);
      expect(niceCeil(42), 50);
      expect(niceCeil(420), 500);
    });
  });

  group('formatAxisTick', () {
    test('a span of a day or less formats as HH:mm', () {
      final DateTime t = DateTime(2026, 7, 18, 9, 5);
      expect(formatAxisTick(t, const Duration(hours: 6)), '09:05');
      expect(formatAxisTick(t, const Duration(days: 1)), '09:05');
    });

    test('a span over a day formats as MM/DD', () {
      final DateTime t = DateTime(2026, 7, 8, 9, 5);
      expect(formatAxisTick(t, const Duration(days: 2)), '07/08');
    });
  });

  group('formatTooltipTime', () {
    test('always includes date and time', () {
      final DateTime t = DateTime(2026, 7, 8, 9, 5, 3);
      expect(formatTooltipTime(t), '2026-07-08 09:05:03');
    });
  });

  group('formatOrdinalTick', () {
    test('formats the rounded integer', () {
      expect(formatOrdinalTick(12), '12');
      expect(formatOrdinalTick(12.4), '12');
      expect(formatOrdinalTick(12.6), '13');
      expect(formatOrdinalTick(0), '0');
    });
  });
}
