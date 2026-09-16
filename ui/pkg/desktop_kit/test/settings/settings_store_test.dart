// Tests for SettingsStore: path injection, load contract, write-then-read
// round-trip, debounce coalescence, and savedAt stamping.
library;

import 'dart:convert';
import 'dart:io';

import 'package:desktop_kit/desktop_kit_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmpDir;
  late SettingsStore store;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('settings_store_test_');
    store = SettingsStore(appId: 'test_app', overridePath: tmpDir.path);
  });

  tearDown(() async {
    await tmpDir.delete(recursive: true);
  });

  group('load()', () {
    test('returns {} when config file does not exist', () async {
      final result = await store.load();
      expect(result, isEmpty);
    });

    test('returns {} for an empty file', () async {
      final file = File('${tmpDir.path}/config.json');
      await file.writeAsString('');
      final result = await store.load();
      expect(result, isEmpty);
    });

    test('returns {} for corrupt JSON — never throws', () async {
      final file = File('${tmpDir.path}/config.json');
      await file.writeAsString('NOT VALID JSON }{');
      final result = await store.load();
      expect(result, isEmpty);
    });

    test('returns {} when JSON root is not a map', () async {
      final file = File('${tmpDir.path}/config.json');
      await file.writeAsString('[1, 2, 3]');
      final result = await store.load();
      expect(result, isEmpty);
    });
  });

  group('flush() / round-trip', () {
    test('write-then-load round-trip preserves data', () async {
      const data = <String, dynamic>{
        'theme': 'dark',
        'fontSize': 14,
        'enabled': true,
      };
      await store.flush(data);
      final loaded = await store.load();
      expect(loaded['theme'], 'dark');
      expect(loaded['fontSize'], 14);
      expect(loaded['enabled'], true);
    });

    test('flush creates parent directories', () async {
      // Use a nested overridePath that does not yet exist.
      final nested = Directory('${tmpDir.path}/a/b/c');
      final nestedStore = SettingsStore(
        appId: 'nested',
        overridePath: nested.path,
      );
      await nestedStore.flush(<String, dynamic>{'k': 'v'});
      final loaded = await nestedStore.load();
      expect(loaded['k'], 'v');
    });

    test('flush writes pretty-printed JSON', () async {
      await store.flush(<String, dynamic>{'key': 'value'});
      final file = File('${tmpDir.path}/config.json');
      final raw = await file.readAsString();
      // Expect indented format produced by JsonEncoder.withIndent.
      expect(raw, contains('\n'));
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['key'], 'value');
    });
  });

  group('scheduleSave() debounce', () {
    test('multiple scheduleSave calls within window produce one write',
        () async {
      var writeCount = 0;
      // Watch the config file for modifications via savedAt notifier.
      final writes = <DateTime>[];
      store.savedAt.addListener(() {
        final ts = store.savedAt.value;
        if (ts != null) writes.add(ts);
      });

      // Fire three saves in rapid succession.
      store.scheduleSave(<String, dynamic>{'burst': 1});
      store.scheduleSave(<String, dynamic>{'burst': 2});
      store.scheduleSave(<String, dynamic>{'burst': 3});

      // Flush to ensure the pending debounced timer fires.
      await store.flush(<String, dynamic>{'burst': 3});

      // The flush itself counts as one write; scheduleSave's timer was
      // cancelled by flush, so we get exactly 1 savedAt emission.
      writeCount = writes.length;
      expect(writeCount, 1);

      // And the file contains the last data.
      final loaded = await store.load();
      expect(loaded['burst'], 3);
    });
  });

  group('savedAt', () {
    test('starts as null', () {
      expect(store.savedAt.value, isNull);
    });

    test('is stamped after flush()', () async {
      final before = DateTime.now();
      await store.flush(<String, dynamic>{'x': 1});
      final ts = store.savedAt.value;
      expect(ts, isNotNull);
      expect(ts!.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
    });

    test('is updated on each successive flush()', () async {
      await store.flush(<String, dynamic>{'a': 1});
      final first = store.savedAt.value;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.flush(<String, dynamic>{'b': 2});
      final second = store.savedAt.value;
      expect(second, isNotNull);
      expect(second!.isAtSameMomentAs(first!) || second.isAfter(first), isTrue);
    });
  });

  group('fileName override', () {
    test('uses custom fileName when specified', () async {
      final customStore = SettingsStore(
        appId: 'test_app',
        fileName: 'prefs.json',
        overridePath: tmpDir.path,
      );
      await customStore.flush(<String, dynamic>{'mode': 'light'});
      final file = File('${tmpDir.path}/prefs.json');
      expect(file.existsSync(), isTrue);
      final loaded = await customStore.load();
      expect(loaded['mode'], 'light');
    });
  });
}
