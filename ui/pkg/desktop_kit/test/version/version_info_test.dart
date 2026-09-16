// Tests for VersionInfo: displayString combinations, fromMap defensive defaults.
library;

import 'package:desktop_kit/desktop_kit_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VersionInfo.displayString', () {
    test('all fields — version commit date', () {
      const info = VersionInfo(
        version: '1.2.3',
        commit: 'abc1234',
        date: '2024-01-15',
      );
      expect(info.displayString, '1.2.3 (abc1234) built 2024-01-15');
    });

    test('version + commit only', () {
      const info = VersionInfo(version: '1.2.3', commit: 'abc1234');
      expect(info.displayString, '1.2.3 (abc1234)');
    });

    test('version + date only', () {
      const info = VersionInfo(version: '1.2.3', date: '2024-01-15');
      expect(info.displayString, '1.2.3 built 2024-01-15');
    });

    test('version only', () {
      const info = VersionInfo(version: '1.2.3');
      expect(info.displayString, '1.2.3');
    });

    test('all empty fields → empty string', () {
      const info = VersionInfo();
      expect(info.displayString, '');
    });

    test('commit only', () {
      const info = VersionInfo(commit: 'abc1234');
      expect(info.displayString, '(abc1234)');
    });

    test('date only', () {
      const info = VersionInfo(date: '2024-01-15');
      expect(info.displayString, 'built 2024-01-15');
    });

    test('toString() delegates to displayString', () {
      const info = VersionInfo(version: '2.0.0', commit: 'dead');
      expect(info.toString(), info.displayString);
    });
  });

  group('VersionInfo.fromMap', () {
    test('all fields present', () {
      final info = VersionInfo.fromMap(<String, dynamic>{
        'version': '1.0.0',
        'commit': 'cafebabe',
        'date': '2024-06-01',
      });
      expect(info.version, '1.0.0');
      expect(info.commit, 'cafebabe');
      expect(info.date, '2024-06-01');
    });

    test('missing fields default to empty string', () {
      final info = VersionInfo.fromMap(<String, dynamic>{});
      expect(info.version, '');
      expect(info.commit, '');
      expect(info.date, '');
    });

    test('non-string values fall back to empty string', () {
      final info = VersionInfo.fromMap(<String, dynamic>{
        'version': 123,
        'commit': null,
        'date': <String>[],
      });
      expect(info.version, '');
      expect(info.commit, '');
      expect(info.date, '');
    });

    test('extra unknown keys are ignored', () {
      final info = VersionInfo.fromMap(<String, dynamic>{
        'version': '0.1.0',
        'unknown_key': 'value',
        'another': 42,
      });
      expect(info.version, '0.1.0');
      expect(info.commit, '');
      expect(info.date, '');
    });

    test('const constructor works', () {
      const info = VersionInfo(
        version: '3.0.0',
        commit: 'feedface',
        date: '2025-01-01',
      );
      expect(info.displayString, '3.0.0 (feedface) built 2025-01-01');
    });
  });
}
