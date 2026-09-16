// Pure (Flutter-free) candidate computation for swiper — an ivy/swiper-style
// live line search over the buffer. Given the buffer text and the current
// minibuffer input, it returns the lines that match (one candidate per line)
// plus every in-buffer match for highlighting. Kept pure so it is trivially
// unit-testable and reusable: the editor widget renders the candidate rows, the
// buffer model drives selection/preview — this file only decides WHAT matches.
//
// Matching semantics: the input is treated as a regexp, and a PARTIAL or
// invalid pattern — a trailing '[' or an unclosed group mid-typing — must
// never crash or blank the list: it falls back to a literal substring search
// of the raw input until the pattern compiles again. Case-folding mirrors
// [Search]/[RegexSearch]: an all-lower-case input matches case-insensitively.
library;

import 'emacs_search.dart';

/// One swiper candidate: a buffer line that matches the current input.
class SwiperLine {
  /// Create a [SwiperLine].
  const SwiperLine({
    required this.line,
    required this.lineStart,
    required this.text,
    this.match,
  });

  /// 0-based index of this line in the buffer.
  final int line;

  /// Buffer offset of this line's first character.
  final int lineStart;

  /// The line's text, without its trailing newline.
  final String text;

  /// The first match on this line, in BUFFER coordinates — the position the
  /// caret previews/commits to. Null only when the input is empty (every line
  /// is listed, with nothing to highlight).
  final SearchHit? match;

  @override
  bool operator ==(Object other) =>
      other is SwiperLine &&
      other.line == line &&
      other.lineStart == lineStart &&
      other.text == text &&
      other.match == match;

  @override
  int get hashCode => Object.hash(line, lineStart, text, match);

  @override
  String toString() => 'SwiperLine($line, "$text", $match)';
}

/// The outcome of [computeSwiper]: the candidate [lines] (one per matching
/// line) and every match [hits] across the whole buffer, so a host can highlight
/// all matches while previewing the selected one as the current hit.
class SwiperResult {
  /// Create a [SwiperResult].
  const SwiperResult(this.lines, this.hits);

  /// The matching lines, ascending by line number.
  final List<SwiperLine> lines;

  /// Every match in the buffer, ascending — the input to searchHits rendering.
  final List<SearchHit> hits;
}

/// Filter the buffer [text] by [input], returning its matching lines and all
/// matches. Empty [input] lists every line (swiper's default). See the library
/// comment for the regex / partial-regex / literal-fallback semantics.
SwiperResult computeSwiper(String text, String input) {
  // Enumerate lines with their buffer start offsets. This matches the editor's
  // own line model — a trailing '\n' yields a final empty line — so candidate
  // line numbers agree with the gutter.
  final List<({int line, int start, int end})> lines =
      <({int line, int start, int end})>[];
  int start = 0;
  int lineNo = 0;
  for (int i = 0; i <= text.length; i++) {
    if (i == text.length || text[i] == '\n') {
      lines.add((line: lineNo, start: start, end: i));
      lineNo++;
      start = i + 1;
    }
  }

  // Empty input lists every line, with no match to preview.
  if (input.isEmpty) {
    return SwiperResult(
      <SwiperLine>[
        for (final ({int line, int start, int end}) l in lines)
          SwiperLine(
            line: l.line,
            lineStart: l.start,
            text: text.substring(l.start, l.end),
          ),
      ],
      const <SearchHit>[],
    );
  }

  // Regex first; fall back to a literal substring search when the pattern will
  // not compile (partial/invalid while typing) so the list never crashes/blanks.
  //
  // `ok`, not `regex != null`: under an engine that is not Dart's RegExp there
  // is no RegExp to hand back, and reading the null as "did not compile" would
  // route EVERY pattern to the literal fallback — a silent loss of regexp
  // swiper, on exactly the platforms that just gained a better engine.
  final RegexCompileResult compiled = RegexSearch.compile(input);
  final List<SearchHit> hits = compiled.ok
      ? RegexSearch.matches(text, input)
      : Search.matches(text, input);

  // Bucket matches into their lines. Both lists are ascending, so a single
  // cursor over [hits] suffices: for each line, skip matches that ended before
  // it, then take the first match that starts within it (extra intra-line
  // matches are skipped by the next line's advance).
  final List<SwiperLine> out = <SwiperLine>[];
  int h = 0;
  for (final ({int line, int start, int end}) l in lines) {
    while (h < hits.length && hits[h].start < l.start) {
      h++;
    }
    if (h < hits.length && hits[h].start >= l.start && hits[h].start < l.end) {
      out.add(SwiperLine(
        line: l.line,
        lineStart: l.start,
        text: text.substring(l.start, l.end),
        match: hits[h],
      ));
    }
  }
  return SwiperResult(out, hits);
}
