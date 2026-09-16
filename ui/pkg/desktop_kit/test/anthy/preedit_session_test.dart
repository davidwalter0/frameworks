import 'dart:async';

import 'package:desktop_kit/desktop_kit_anthy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted fake `anthy-agent --egg`: any hiragana → 1 segment, candidates
/// ['日本','二本'] (best 日本). Same fixture family as the controller tests.
class _ScriptedAnthy implements AnthyProcess {
  late final StreamController<String> _out = StreamController<String>.broadcast(
    onListen: () => scheduleMicrotask(
      () => _emit('Anthy (Version fake) [] : Nice to meet you.'),
    ),
  );

  void _emit(String line) {
    if (!_out.isClosed) _out.add(line);
  }

  @override
  Stream<String> get lines => _out.stream;

  @override
  void send(String line) {
    final resp = switch (line.split(' ').first) {
      'NEW-CONTEXT' => <String>['+OK 1'],
      'CONVERT' => <String>['+DATA 0 0 1', '2 日本 にほん', ''],
      'GET-CANDIDATES' => <String>['+DATA 1 2', '日本', '二本', ''],
      'SELECT-CANDIDATE' => <String>['+OK'],
      'COMMIT' => <String>['+OK'],
      'RELEASE-CONTEXT' => <String>['+OK'],
      _ => <String>['-ERR unexpected: $line'],
    };
    scheduleMicrotask(() => resp.forEach(_emit));
  }

  @override
  Future<void> kill() async {
    if (!_out.isClosed) await _out.close();
  }
}

/// A [PreeditHost] over a mutable (text, caret), applying each splice with the
/// exact semantics of `EmacsBuffer.replaceBeforeCaret` (delete N before the
/// caret, insert, caret after the inserted text). Records the splice stream.
class _FakeHost implements PreeditHost {
  _FakeHost([this._text = '', int? caret]) : _caret = caret ?? _text.length;

  String _text;
  int _caret;
  final List<PreeditSplice> splices = <PreeditSplice>[];

  @override
  String get text => _text;

  @override
  int get caret => _caret;

  @override
  void applyPreeditSplice(PreeditSplice splice) {
    splices.add(splice);
    final int start = (_caret - splice.deleteBefore).clamp(0, _text.length);
    _text = _text.substring(0, start) + splice.insert + _text.substring(_caret);
    _caret = start + splice.insert.length;
  }

  @override
  String readRegion(PreeditRegion region) {
    final int start = region.start.clamp(0, _text.length);
    final int end = (region.start + region.length).clamp(start, _text.length);
    return _text.substring(start, end);
  }

  /// Simulate an external edit that moves the region out from under the session:
  /// insert [s] at [at], shifting the caret when the edit is at/before it.
  void externalInsert(int at, String s) {
    _text = _text.substring(0, at) + s + _text.substring(at);
    if (at <= _caret) _caret += s.length;
  }
}

void main() {
  PreeditSession over(_FakeHost host) =>
      PreeditSession.overEgg(host, AnthyEgg(_ScriptedAnthy()));

  group('PreeditSession — one region, host-applied splices', () {
    test('compose grows a SINGLE region from the first keystroke', () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('に');
      expect(host.text, 'に');
      expect(s.state.phase, PreeditPhase.composing);
      expect(s.state.region.start, 0);
      expect(s.state.region.text, 'に');

      s.feedKana('ほん');
      expect(host.text, 'にほん');
      expect(s.state.region.start, 0,
          reason: 'same region, grown — not a new one');
      expect(s.state.region.text, 'にほん');
      expect(host.caret, 3);
    });

    test('convert replaces the region in place; commit finalises and exits',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('にほん');
      await s.space(); // → 日本
      expect(host.text, '日本');
      expect(s.state.phase, PreeditPhase.converting);
      expect(s.state.region.text, '日本');

      final out = await s.commit();
      expect(out.committed, '日本');
      expect(host.text, '日本'); // committed text stays; region cleared
      expect(s.state.phase, PreeditPhase.idle);
      expect(s.state.region.isEmpty, isTrue);
      expect(host.splices.last.kind, PreeditSpliceKind.commit,
          reason: 'the host records a self-insert for a commit, not a compose');
    });

    test('splices land only at the region — surrounding text is untouched',
        () async {
      final host = _FakeHost('[]', 1); // caret between the brackets
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('にほん');
      expect(host.text, '[にほん]');
      await s.space();
      final out = await s.commit();
      expect(out.committed, '日本');
      expect(host.text, '[日本]', reason: 'brackets preserved on both sides');
    });

    test('Enter commits AND exits even without a conversion (composing)',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('にほん');
      final out = await s.commit(); // Enter while still composing
      expect(out.committed, 'にほん');
      expect(host.text, 'にほん'); // no stray newline
      expect(s.state.phase, PreeditPhase.idle);
      expect(s.state.region.isEmpty, isTrue);
    });

    test('Esc is two-stage: converting reverts to the reading, 2nd Esc drops',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('にほん');
      await s.space(); // 日本, converting
      expect(host.text, '日本');

      final r1 = await s.cancel(); // stage 1
      expect(r1.committed, isNull);
      expect(r1.reverted, isNull,
          reason: 'still active — nothing abandoned yet');
      expect(s.state.phase, PreeditPhase.composing);
      expect(host.text, 'にほん',
          reason: 'reverted to the reading, region intact');

      final r2 = await s.cancel(); // stage 2 → discard
      expect(r2.reverted, 'にほん');
      expect(host.text, '', reason: 'abandoned; region cleared');
      expect(s.state.phase, PreeditPhase.idle);
    });

    test('Shift+K flips the composing kana in place; Space still converts',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('にほん');
      s.toggleScript(); // → katakana, shown in the region
      expect(host.text, 'ニホン');
      expect(s.state.phase, PreeditPhase.composing);
      expect(s.state.region.text, 'ニホン');

      await s.space(); // converts the PRESERVED reading, not the katakana
      expect(host.text, '日本');
      expect(s.state.phase, PreeditPhase.converting);
    });

    test('discard clears the region and returns the reading', () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('にほん');
      await s.space();
      final out = await s.discard();
      expect(out.reverted, 'にほん');
      expect(host.text, '');
      expect(s.state.phase, PreeditPhase.idle);
      expect(host.splices.last.kind, PreeditSpliceKind.cancel);
    });

    test('backspace drops a kana; emptying the preedit returns to idle',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('に');
      s.backspace();
      expect(host.text, '');
      expect(s.state.phase, PreeditPhase.idle);
      expect(s.state.region.isEmpty, isTrue);
    });
  });

  group('PreeditSession — stale-region surrender', () {
    test('re-anchors at the caret after an external edit; no corruption',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('にほん'); // region [0,3)
      expect(host.text, 'にほん');

      // Something else edits the buffer: prepend 'X'. The caret moves to 4, so
      // the tracked region [0,3) no longer ends at the caret.
      host.externalInsert(0, 'X');
      expect(host.text, 'Xにほん');
      expect(host.caret, 4);

      // The next input must NOT delete 3 chars before the moved caret (which
      // would clobber 'ほん') and must NOT re-insert the whole stale reading.
      s.feedKana('ご');
      expect(host.text, 'Xにほんご',
          reason: 'ご is appended cleanly at the caret; nothing duplicated');
      expect(s.state.region.text, 'ご');
      expect(s.state.region.start, 4);
    });

    test('a stale commit becomes a no-op rather than corrupting the buffer',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('にほん');
      await s.space(); // 日本
      host.externalInsert(0, 'X'); // buffer moves underneath
      expect(host.text, 'X日本');

      final out = await s.commit();
      expect(out.committed, isNull, reason: 'guard dropped the stale preedit');
      expect(host.text, 'X日本', reason: 'no splice into the moved buffer');
      expect(s.state.phase, PreeditPhase.idle);
    });
  });

  group('PreeditSession — raw romaji feed (increment 2)', () {
    test('feed builds kana with a live tail; Space flushes then converts',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      for (final String c in <String>['n', 'i', 'h', 'o']) {
        s.feed(c);
      }
      expect(host.text, 'にほ');
      expect(s.state.phase, PreeditPhase.composing);
      expect(s.state.region.pendingRomajiLength, 0);

      s.feed('n'); // a lone n stays pending — part of the region, not yet kana
      expect(host.text, 'にほn');
      expect(s.state.region.text, 'にほn');
      expect(s.state.region.pendingRomajiLength, 1,
          reason:
              'the trailing romaji is highlighted but flagged un-finalised');

      await s.space(); // flush n→ん, then convert にほん
      expect(host.text, '日本');
      expect(s.state.phase, PreeditPhase.converting);
      expect(s.state.region.pendingRomajiLength, 0);

      final out = await s.commit();
      expect(out.committed, '日本');
      expect(host.text, '日本');
    });

    test('a lone pending romaji reports composing even before any kana',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      final bool consumed = s.feed('k'); // no kana yet — just a pending tail
      expect(consumed, isTrue);
      expect(host.text, 'k');
      expect(s.state.phase, PreeditPhase.composing);
      expect(s.state.region.pendingRomajiLength, 1);
    });

    test('backspace trims the romaji tail before touching finalised kana',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feed('n');
      s.feed('i'); // に
      s.feed('s'); // + pending 's'
      expect(host.text, 'にs');

      s.backspace(); // drops the pending 's' only
      expect(host.text, 'に');
      expect(s.state.region.pendingRomajiLength, 0);

      s.backspace(); // now drops the kana に → idle
      expect(host.text, '');
      expect(s.state.phase, PreeditPhase.idle);
    });

    test('a non-letter finalises the tail and is not consumed', () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feed('k'); // pending 'k'
      final bool consumed = s.feed('1'); // a digit is not romaji
      expect(consumed, isFalse,
          reason: 'the caller must insert the digit itself');
      expect(s.state.region.pendingRomajiLength, 0,
          reason: 'the pending tail was finalised, not left dangling');
    });

    test('Shift+K flips the fed kana; the reading survives for conversion',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      for (final String c in <String>['n', 'i', 'h', 'o']) {
        s.feed(c);
      }
      expect(host.text, 'にほ');

      s.toggleScript(); // にほ → ニホ, in place
      expect(host.text, 'ニホ');
      expect(s.state.phase, PreeditPhase.composing);

      await s.space(); // converts the preserved にほ reading, not the katakana
      expect(s.state.phase, PreeditPhase.converting);
    });
  });

  group('PreeditSession.cancel — stage 0: drop the romaji tail', () {
    test('Esc with a pending tail discards the RAW letters, keeps the kana',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feed('n');
      s.feed('i');
      s.feed('h');
      s.feed('o');
      s.feed('n'); // にほ + pending 'n'
      expect(host.text, 'にほn');
      expect(s.state.region.pendingRomajiLength, 1);

      final PreeditOutcome out = await s.cancel();
      expect(out.committed, isNull);
      expect(out.reverted, isNull, reason: 'stage 0 is not terminal');
      expect(host.text, 'にほ',
          reason: 'the raw n is DISCARDED, never converted to ん');
      expect(s.state.phase, PreeditPhase.composing,
          reason: 'the group survives — only the tail went');
      expect(s.state.region.pendingRomajiLength, 0);
    });

    test('a second Esc (no tail left) then abandons the group', () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feed('n');
      s.feed('i');
      s.feed('s'); // に + pending 's'
      await s.cancel(); // stage 0 — drops the 's'
      expect(host.text, 'に');

      final PreeditOutcome out = await s.cancel(); // now abandons
      expect(out.reverted, 'に');
      expect(host.text, '');
      expect(s.state.phase, PreeditPhase.idle);
    });
  });

  group('PreeditSession.commitSync — synchronous choke-point commit', () {
    test('composing: splices the host with NO await in between', () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('にほん');
      expect(host.text, 'にほん');

      // The whole point: the splice must be visible on the very next statement,
      // with no await — a synchronous choke point runs its command right after.
      final PreeditOutcome? out = s.commitSync();
      expect(host.text, 'にほん', reason: 'committed text is already in place');
      expect(out?.committed, 'にほん');
      expect(s.state.phase, PreeditPhase.idle);
      expect(s.state.region.isEmpty, isTrue);
      expect(host.splices.last.kind, PreeditSpliceKind.commit);
    });

    test('flushes a pending romaji tail synchronously too', () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feed('n'); // a lone pending n, no kana yet
      expect(host.text, 'n');

      final PreeditOutcome? out = s.commitSync();
      expect(out?.committed, 'ん', reason: 'the tail flushed to ん on commit');
      expect(host.text, 'ん');
      expect(s.state.phase, PreeditPhase.idle);
    });

    test('converting: returns null and leaves the preedit intact to await',
        () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      s.feedKana('にほん');
      await s.space(); // → converting
      expect(host.text, '日本');

      final PreeditOutcome? out = s.commitSync();
      expect(out, isNull,
          reason: 'only a conversion must round-trip Anthy so it can learn');
      expect(s.state.phase, PreeditPhase.converting,
          reason: 'left intact so the caller can await commit()');
      expect(host.text, '日本');

      // The caller then awaits — and it still commits correctly.
      final PreeditOutcome done = await s.commit();
      expect(done.committed, '日本');
      expect(s.state.phase, PreeditPhase.idle);
    });

    test('idle: a no-op that reports nothing committed', () async {
      final host = _FakeHost();
      final s = over(host);
      addTearDown(s.dispose);

      final PreeditOutcome? out = s.commitSync();
      expect(out, isNotNull);
      expect(out?.committed, isNull);
      expect(host.text, '');
    });
  });
}
