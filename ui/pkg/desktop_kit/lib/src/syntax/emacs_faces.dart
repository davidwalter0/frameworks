// Demo-grade, regex-based syntax highlighting for the Emacs-kit example:
// maps a small set of harvested Emacs face names to non-overlapping spans
// over a text buffer, and maps face names onto kit ColorScheme slots for
// theme seeding. No Flutter dependency.
library;

/// The languages [SyntaxFaces.spans] knows how to tag.
///
/// [none] is the identity: it never produces a span, which is what a plain
/// text buffer (or a buffer whose mode has no highlighter) should render as.
enum SyntaxLanguage { none, elisp, go, org, yaml }

/// One highlighted span: `[start, end)` offsets into the source text tagged
/// with the Emacs face name that applies there (e.g.
/// `font-lock-comment-face`).
class FaceSpan {
  const FaceSpan(this.start, this.end, this.face);
  final int start;
  final int end;
  final String face;
}

/// Regex-based, demo-grade syntax highlighting.
///
/// [spans] returns non-overlapping, start-sorted spans naming real Emacs face
/// names for the requested [SyntaxLanguage]. Overlaps are resolved by
/// precedence — comment > string > everything else — so a keyword inside a
/// string or a comment is not tagged as a keyword.
class SyntaxFaces {
  SyntaxFaces._();

  // ---------------------------------------------------------------- elisp

  static final RegExp _elispCommentRe = RegExp(r';.*$', multiLine: true);
  static final RegExp _elispStringRe = RegExp(r'"[^"]*"');
  static final RegExp _elispKeywordRe = RegExp(
    r'\b(defun|if|let|let\*|lambda|cond|when|unless|progn|setq|'
    r'class|final|const|void|return|import|library|static|new)\b',
  );
  // Matched separately from the generic "(ident" form below so that
  // "(defun name ...)" tags `name` — not the literal word "defun" that
  // immediately follows the opening paren.
  static final RegExp _elispDefunNameRe =
      RegExp(r'\bdefun\s+([A-Za-z_][\w\-/!?*]*)');
  static final RegExp _elispParenNameRe = RegExp(r'\(([A-Za-z_][\w\-/!?*]*)');

  // ------------------------------------------------------------------- go

  static final RegExp _goLineCommentRe = RegExp(r'//.*$', multiLine: true);
  static final RegExp _goBlockCommentRe = RegExp(r'/\*[\s\S]*?\*/');
  static final RegExp _goStringRe = RegExp(r'"[^"\n]*"');
  static final RegExp _goRawStringRe = RegExp(r'`[^`]*`');
  static final RegExp _goKeywordRe = RegExp(
    r'\b(func|var|const|type|struct|interface|map|chan|go|defer|'
    r'if|else|for|range|return|package|import|switch|case|default|select)\b',
  );
  static final RegExp _goTypeRe = RegExp(
    r'\b(int|int64|string|bool|error|byte|rune|float64|any)\b',
  );
  static final RegExp _goFuncNameRe = RegExp(r'\bfunc\s+([A-Za-z_]\w*)');

  // ------------------------------------------------------------------ org

  // A `#` line comment, but never a `#+keyword` line (those are org syntax,
  // and `#+begin_`/`#+end_` in particular belong to `org-block`).
  static final RegExp _orgCommentRe = RegExp(r'^#(?!\+).*$', multiLine: true);
  static final RegExp _orgBlockRe = RegExp(
    r'^#\+begin_[\s\S]*?^#\+end_.*$',
    multiLine: true,
    caseSensitive: false,
  );
  // The '#+begin_*'/'#+end_*' delimiter lines themselves read as org-meta-line
  // (Emacs dims block scaffolding while keeping header args legible) — matched
  // BEFORE `_orgBlockRe` below so it claims just those lines, leaving the body
  // tagged 'org-block'. NOTE: this only dims the delimiter; true concealment
  // (rendering "src bash" instead of "#+begin_src bash") would shrink the
  // line and break the length-preservation invariant every offset map here
  // relies on — that stays a future display-transform, not a face.
  static final RegExp _orgMetaLineRe = RegExp(
    r'^\s*#\+(?:begin|end)_\S+.*$',
    multiLine: true,
    caseSensitive: false,
  );

  /// `org-level-N` heading regexes, N = 1..9: exactly N stars then a space
  /// (`{n}` cannot over-match — an extra star fails the following-space test).
  static final List<RegExp> _orgLevelRes = <RegExp>[
    for (int n = 1; n <= 9; n++) RegExp('^\\*{$n} .*\$', multiLine: true),
  ];
  static final RegExp _orgLinkRe = RegExp(r'\[\[.*?\]\]');
  static final RegExp _orgVerbatimRe = RegExp(r'=[^=\n]+=');
  static final RegExp _orgCodeRe = RegExp(r'~[^~\n]+~');
  static final RegExp _orgTodoRe = RegExp(r'\bTODO\b');
  static final RegExp _orgDoneRe = RegExp(r'\bDONE\b');
  // A table row: after leading whitespace, a line starting with '|' (both
  // data rows and `|---+---|`-style separator rows) — mirrors
  // `org_table.dart`'s `isTableLine`.
  static final RegExp _orgTableRe = RegExp(r'^\s*\|.*$', multiLine: true);

  // ----------------------------------------------------------------- yaml

  static final RegExp _yamlCommentRe = RegExp(r'#.*$', multiLine: true);
  static final RegExp _yamlDoubleQuoteRe = RegExp(r'"[^"\n]*"');
  static final RegExp _yamlSingleQuoteRe = RegExp("'[^'\n]*'");
  // A key at line start, up to (but not including) its colon. The colon is
  // matched by a zero-width lookahead so group 1 ends the match — see
  // [_matchGroup1].
  static final RegExp _yamlKeyRe = RegExp(
    r'^[ \t]*-?[ \t]*([A-Za-z_][\w.\-]*)(?=[ \t]*:)',
    multiLine: true,
  );
  static final RegExp _yamlConstRe = RegExp(r'\b(true|false|null|yes|no)\b');
  static final RegExp _yamlNumberRe = RegExp(r'\b\d+(?:\.\d+)?\b');

  /// Non-overlapping, start-sorted [FaceSpan]s naming Emacs face names for
  /// [lang] over [text].
  ///
  /// Spans never overlap and are sorted by [FaceSpan.start]. Overlaps are
  /// resolved by precedence: comment > string > everything else.
  static List<FaceSpan> spans(String text, SyntaxLanguage lang) {
    if (text.isEmpty || lang == SyntaxLanguage.none) {
      return <FaceSpan>[];
    }

    // Candidate spans grouped by precedence, highest first.
    final List<List<FaceSpan>> byPrecedence;
    switch (lang) {
      case SyntaxLanguage.none:
        return <FaceSpan>[];
      case SyntaxLanguage.elisp:
        byPrecedence = _elispCandidates(text);
      case SyntaxLanguage.go:
        byPrecedence = _goCandidates(text);
      case SyntaxLanguage.org:
        byPrecedence = _orgCandidates(text);
      case SyntaxLanguage.yaml:
        byPrecedence = _yamlCandidates(text);
    }
    return _merge(text, byPrecedence);
  }

  static List<List<FaceSpan>> _elispCandidates(String text) {
    return <List<FaceSpan>>[
      _matchAll(text, _elispCommentRe, 'font-lock-comment-face'),
      _matchAll(text, _elispStringRe, 'font-lock-string-face'),
      _matchAll(text, _elispKeywordRe, 'font-lock-keyword-face'),
      <FaceSpan>[
        ..._matchGroup1(
            text, _elispDefunNameRe, 'font-lock-function-name-face'),
        ..._matchGroup1(
            text, _elispParenNameRe, 'font-lock-function-name-face'),
      ],
    ];
  }

  static List<List<FaceSpan>> _goCandidates(String text) {
    return <List<FaceSpan>>[
      <FaceSpan>[
        ..._matchAll(text, _goLineCommentRe, 'font-lock-comment-face'),
        ..._matchAll(text, _goBlockCommentRe, 'font-lock-comment-face'),
      ],
      <FaceSpan>[
        ..._matchAll(text, _goStringRe, 'font-lock-string-face'),
        ..._matchAll(text, _goRawStringRe, 'font-lock-string-face'),
      ],
      _matchAll(text, _goKeywordRe, 'font-lock-keyword-face'),
      _matchAll(text, _goTypeRe, 'font-lock-type-face'),
      _matchGroup1(text, _goFuncNameRe, 'font-lock-function-name-face'),
    ];
  }

  static List<List<FaceSpan>> _orgCandidates(String text) {
    return <List<FaceSpan>>[
      _matchAll(text, _orgCommentRe, 'font-lock-comment-face'),
      _matchAll(text, _orgMetaLineRe, 'org-meta-line'),
      _matchAll(text, _orgBlockRe, 'org-block'),
      // Above the heading faces: a `TODO`/`DONE` keyword sits *inside* a
      // headline, and Emacs paints it `org-todo`/`org-done` rather than the
      // surrounding `org-level-N`. The heading span splits around it.
      _matchAll(text, _orgTodoRe, 'org-todo'),
      _matchAll(text, _orgDoneRe, 'org-done'),
      // Deepest level first, so a `***` line is level-3, never level-1.
      for (int n = 9; n >= 1; n--)
        _matchAll(text, _orgLevelRes[n - 1], 'org-level-$n'),
      _matchAll(text, _orgLinkRe, 'org-link'),
      <FaceSpan>[
        ..._matchAll(text, _orgVerbatimRe, 'org-code'),
        ..._matchAll(text, _orgCodeRe, 'org-code'),
      ],
      // Lowest precedence: a table row never overlaps a heading/comment/
      // block, but sits below them so those still win if they somehow did.
      _matchAll(text, _orgTableRe, 'org-table'),
    ];
  }

  static List<List<FaceSpan>> _yamlCandidates(String text) {
    return <List<FaceSpan>>[
      _matchAll(text, _yamlCommentRe, 'font-lock-comment-face'),
      <FaceSpan>[
        ..._matchAll(text, _yamlDoubleQuoteRe, 'font-lock-string-face'),
        ..._matchAll(text, _yamlSingleQuoteRe, 'font-lock-string-face'),
      ],
      _matchGroup1(text, _yamlKeyRe, 'font-lock-variable-name-face'),
      <FaceSpan>[
        ..._matchAll(text, _yamlConstRe, 'font-lock-constant-face'),
        ..._matchAll(text, _yamlNumberRe, 'font-lock-constant-face'),
      ],
    ];
  }

  /// Flattens [byPrecedence] (highest-precedence group first) into a single
  /// non-overlapping, start-sorted span list.
  ///
  /// Offsets claimed by a higher-precedence group are never re-tagged; a
  /// lower-precedence candidate that straddles claimed territory is split
  /// into its unclaimed runs (or dropped when fully covered). That is what
  /// keeps `if` inside `"an if string"` from being tagged as a keyword.
  static List<FaceSpan> _merge(String text, List<List<FaceSpan>> byPrecedence) {
    final List<bool> claimed = List<bool>.filled(text.length, false);
    final List<FaceSpan> result = <FaceSpan>[];

    for (final List<FaceSpan> candidates in byPrecedence) {
      for (final FaceSpan span in candidates) {
        final int end = span.end;
        int i = span.start;
        while (i < end) {
          if (claimed[i]) {
            i++;
            continue;
          }
          final int runStart = i;
          while (i < end && !claimed[i]) {
            claimed[i] = true;
            i++;
          }
          result.add(FaceSpan(runStart, i, span.face));
        }
      }
    }

    result.sort((a, b) => a.start.compareTo(b.start));
    return _coalesce(result);
  }

  /// Joins abutting spans that carry the same face — e.g. a `//` line comment
  /// that a block comment picked up the tail of — so the output isn't
  /// fragmented at boundaries the reader can't see.
  static List<FaceSpan> _coalesce(List<FaceSpan> sorted) {
    final List<FaceSpan> out = <FaceSpan>[];
    for (final FaceSpan span in sorted) {
      if (out.isNotEmpty &&
          out.last.end == span.start &&
          out.last.face == span.face) {
        out[out.length - 1] = FaceSpan(out.last.start, span.end, span.face);
        continue;
      }
      out.add(span);
    }
    return out;
  }

  static List<FaceSpan> _matchAll(String text, RegExp re, String face) {
    final List<FaceSpan> out = <FaceSpan>[];
    for (final RegExpMatch m in re.allMatches(text)) {
      if (m.start >= m.end) {
        continue;
      }
      out.add(FaceSpan(m.start, m.end, face));
    }
    return out;
  }

  /// Like [_matchAll] but spans the regex's first capture group instead of
  /// the whole match (used for "identifier after a trigger" patterns).
  ///
  /// `RegExpMatch` exposes offsets only for the whole match, so this relies on
  /// the caller's patterns anchoring group 1 at the *end* of the match —
  /// either literally, or via a zero-width lookahead for the trailing
  /// context (see [_yamlKeyRe]) — which makes the group's end the match's end
  /// and its start derivable from the group's length.
  static List<FaceSpan> _matchGroup1(String text, RegExp re, String face) {
    final List<FaceSpan> out = <FaceSpan>[];
    for (final RegExpMatch m in re.allMatches(text)) {
      final String? group = m.group(1);
      if (group == null || group.isEmpty) {
        continue;
      }
      final int end = m.end;
      final int start = end - group.length;
      if (start < m.start) {
        continue;
      }
      out.add(FaceSpan(start, end, face));
    }
    return out;
  }
}

/// Maps an Emacs face name onto a kit `ColorScheme` slot name (`'primary'`,
/// `'secondary'`, `'tertiary'`, `'surface'`, `'onSurface'`, ...) for theme
/// seeding. Returns `null` when the face is unmapped.
String? faceToThemeSlot(String faceName) {
  // All nine heading levels, cycling the three accent slots down the tree.
  if (faceName.startsWith('org-level-')) {
    final int? n = int.tryParse(faceName.substring('org-level-'.length));
    if (n != null && n >= 1) {
      return const <String>['primary', 'secondary', 'tertiary'][(n - 1) % 3];
    }
  }
  switch (faceName) {
    case 'default':
      return 'onSurface';
    case 'region':
      return 'primary';
    case 'font-lock-keyword-face':
      return 'primary';
    case 'font-lock-string-face':
      return 'tertiary';
    case 'font-lock-comment-face':
      return 'onSurfaceVariant';
    case 'font-lock-function-name-face':
      return 'secondary';
    case 'font-lock-type-face':
      return 'tertiary';
    case 'font-lock-variable-name-face':
      return 'secondary';
    case 'font-lock-constant-face':
      return 'tertiary';
    case 'org-block':
      return 'onSurfaceVariant';
    case 'org-meta-line':
      return 'onSurfaceVariant';
    case 'org-code':
      return 'tertiary';
    case 'org-link':
      return 'primary';
    case 'org-todo':
      return 'error';
    case 'org-done':
      return 'onSurfaceVariant';
    case 'org-table':
      return 'onSurfaceVariant';
    case 'cursor':
      return 'error';
    default:
      return null;
  }
}
