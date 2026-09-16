// M-: (eval-expression): the tiny evaluator's semantics.
import 'package:desktop_kit/desktop_kit_elisp_eval.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('evalElisp', () {
    const ElispEnv env = ElispEnv(
      point: 3,
      pointMax: 6,
      bufferSize: 5,
      bufferName: 'notes.org',
      line: 2,
      column: 1,
    );

    test('arithmetic, integer division, comparison', () {
      expect(evalElisp('(+ 1 2 3)', env), '6');
      expect(evalElisp('(- 10 4 1)', env), '5');
      expect(evalElisp('(/ 7 2)', env), '3'); // integer division
      expect(evalElisp('(* 2 3.5)', env), '7');
      expect(evalElisp('(< 1 2)', env), 't');
      expect(evalElisp('(> 1 2)', env), 'nil');
      expect(evalElisp('(1+ 41)', env), '42');
    });

    test('strings, quote, lists', () {
      expect(evalElisp('(concat "a" "b")', env), '"ab"');
      expect(evalElisp('(upcase "hi")', env), '"HI"');
      expect(evalElisp('(length "abc")', env), '3');
      expect(evalElisp("'(1 2 3)", env), '(1 2 3)');
      expect(evalElisp('(car (list 1 2))', env), '1');
      expect(evalElisp('(format "p=%d %s" 4 "x")', env), '"p=4 x"');
    });

    test('special forms', () {
      expect(evalElisp('(if (> 2 1) "yes" "no")', env), '"yes"');
      expect(evalElisp('(and 1 2 nil 3)', env), 'nil');
      expect(evalElisp('(or nil 7)', env), '7');
      expect(evalElisp('(progn 1 2 3)', env), '3');
      expect(evalElisp('(when (> 2 1) 1 2)', env), '2');
      expect(evalElisp('(when (< 2 1) 1 2)', env), 'nil');
      expect(evalElisp('(unless (< 2 1) 1 2)', env), '2');
      expect(evalElisp('(unless (> 2 1) 1 2)', env), 'nil');
    });

    test('system-type and config-time conditionals', () {
      const ElispEnv linux = ElispEnv();
      const ElispEnv darwin = ElispEnv(systemType: 'darwin');
      expect(
        evalElisp("(when (eq system-type 'gnu/linux) 1)", linux),
        '1',
      );
      expect(
        evalElisp("(when (eq system-type 'gnu/linux) 1)", darwin),
        'nil',
      );
      expect(evalElisp("(eq system-type 'darwin)", darwin), 't');
    });

    test('eq, member, string predicates', () {
      expect(evalElisp('(eq 1 1)', env), 't');
      expect(evalElisp('(eq 1 2)', env), 'nil');
      expect(evalElisp("(eq 'foo 'foo)", env), 't');
      expect(evalElisp('(member 2 (list 1 2 3))', env), '(2 3)');
      expect(evalElisp('(member 9 (list 1 2 3))', env), 'nil');
      expect(evalElisp('(string= "a" "a")', env), 't');
      expect(evalElisp('(string= "a" "b")', env), 'nil');
      expect(evalElisp('(string-prefix-p "/ssh:" "/ssh:host")', env), 't');
      expect(evalElisp('(string-prefix-p "/ssh:" "/tmp")', env), 'nil');
      expect(evalElisp('(string-suffix-p ".org" "notes.org")', env), 't');
      expect(evalElisp('(string-suffix-p ".org" "notes.el")', env), 'nil');
    });

    test('getenv reads the seeded env map', () {
      const ElispEnv withEnv =
          ElispEnv(env: <String, String>{'HOME': '/home/user'});
      expect(evalElisp('(getenv "HOME")', withEnv), '"/home/user"');
      expect(evalElisp('(getenv "NOPE")', withEnv), 'nil');
      expect(evalElisp('(getenv "HOME")', env), 'nil');
    });

    test('buffer introspection reads the env', () {
      expect(evalElisp('(point)', env), '3');
      expect(evalElisp('(point-max)', env), '6');
      expect(evalElisp('(buffer-size)', env), '5');
      expect(evalElisp('(buffer-name)', env), '"notes.org"');
      expect(evalElisp('(line-number-at-pos)', env), '2');
      expect(evalElisp('(current-column)', env), '1');
    });

    test('honest errors', () {
      expect(
        () => evalElisp('(frobnicate 1)', env),
        throwsA(predicate((Object? e) =>
            e is ElispEvalException &&
            e.message == 'void-function: frobnicate')),
      );
      expect(
        () => evalElisp('(/ 1 0)', env),
        throwsA(predicate((Object? e) =>
            e is ElispEvalException && e.message == 'arith-error')),
      );
      expect(
        () => evalElisp('(setq x 1)', env),
        throwsA(isA<ElispEvalException>()),
      );
    });
  });

  group('resolveConfigConditional', () {
    const ElispEnv env = ElispEnv();

    test('when + eq system-type resolves under the seeded platform', () {
      final settings = resolveConfigConditional(
        "(when (eq system-type 'gnu/linux) (setq tab-width 4))",
        env,
      );
      expect(settings, hasLength(1));
      expect(settings.single.name, 'tab-width');
      expect(settings.single.value, 4);
      expect(settings.single.raw, '4');
    });

    test('when does not resolve on a non-matching platform', () {
      const ElispEnv macEnv = ElispEnv(systemType: 'darwin');
      expect(
        resolveConfigConditional(
          "(when (eq system-type 'gnu/linux) (setq tab-width 4))",
          macEnv,
        ),
        isEmpty,
      );
    });

    test('unless is the mirror of when', () {
      expect(
        resolveConfigConditional(
          "(unless (eq system-type 'darwin) (setq tab-width 4))",
          env,
        ),
        hasLength(1),
      );
      expect(
        resolveConfigConditional(
          "(unless (eq system-type 'gnu/linux) (setq tab-width 4))",
          env,
        ),
        isEmpty,
      );
    });

    test('multiple setq pairs and multiple guarded body forms', () {
      final settings = resolveConfigConditional(
        "(when (eq system-type 'gnu/linux) "
        '(setq tab-width 4 fill-column 80) '
        '(setq-default indent-tabs-mode nil))',
        env,
      );
      expect(settings.map((s) => s.name),
          ['tab-width', 'fill-column', 'indent-tabs-mode']);
      expect(settings[0].value, 4);
      expect(settings[1].value, 80);
      expect(settings[2].value, null); // nil
      expect(settings[2].raw, 'nil');
    });

    test('setq value forms are evaluated, not just copied', () {
      final settings = resolveConfigConditional(
        "(when (eq system-type 'gnu/linux) (setq fill-column (+ 70 10)))",
        env,
      );
      expect(settings.single.value, 80);
    });

    test('getenv-guarded conditional', () {
      const ElispEnv withEnv = ElispEnv(env: <String, String>{'DISPLAY': ':0'});
      expect(
        resolveConfigConditional(
          '(when (getenv "DISPLAY") (setq tab-width 2))',
          withEnv,
        ),
        hasLength(1),
      );
      expect(
        resolveConfigConditional(
          '(when (getenv "DISPLAY") (setq tab-width 2))',
          env,
        ),
        isEmpty,
      );
    });

    test('non-conditional / non-setq bodies resolve to nothing', () {
      expect(resolveConfigConditional('(setq tab-width 4)', env), isEmpty);
      expect(
        resolveConfigConditional(
          "(when (eq system-type 'gnu/linux) (message \"hi\"))",
          env,
        ),
        isEmpty,
      );
      expect(resolveConfigConditional('not even valid (', env), isEmpty);
      expect(resolveConfigConditional('', env), isEmpty);
    });

    test('an unsupported guard treats the conditional as not applying', () {
      expect(
        resolveConfigConditional(
          '(when (frobnicate) (setq tab-width 4))',
          env,
        ),
        isEmpty,
      );
    });
  });
}
