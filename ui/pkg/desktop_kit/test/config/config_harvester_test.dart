// End-to-end tests for the declarative-config harvester.
import 'package:desktop_kit/desktop_kit_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const harvester = ConfigHarvester();

  group('keybindings', () {
    final seed = harvester.harvest(r'''
(global-set-key (kbd "C-x C-s") 'save-buffer)
(global-set-key (kbd "C-c a") #'org-agenda)
(define-key org-mode-map (kbd "C-c C-t") 'org-todo)
(keymap-global-set "C-c l" 'org-store-link)
''');

    test('harvests global and per-keymap bindings', () {
      expect(seed.bindings, hasLength(4));
      expect(seed.keymapNames, {'global', 'org-mode-map'});
    });

    test('global keymapTokens are sequence-token → command', () {
      final tokens = seed.keymapTokens();
      expect(
          tokens.values,
          containsAll(<String>[
            'save-buffer',
            'org-agenda',
            'org-store-link',
          ]));
      // Keyed by the kit's KeyChordSequence token so it slots into KeymapConfig.
      final saveBinding =
          seed.bindings.firstWhere((b) => b.command == 'save-buffer');
      expect(tokens[saveBinding.sequence.token], 'save-buffer');
      expect(saveBinding.sequence.label, 'Ctrl+X Ctrl+S');
    });

    test('define-key routes into its named keymap', () {
      final orgTokens = seed.keymapTokens(keymap: 'org-mode-map');
      expect(orgTokens.values, ['org-todo']);
    });

    test('no diagnostics for clean binding forms', () {
      expect(seed.diagnostics, isEmpty);
    });
  });

  group('faces', () {
    final seed = harvester.harvest(r'''
(set-face-attribute 'org-level-1 nil :foreground "#81A1C1" :weight 'bold)
(custom-set-faces
 '(font-lock-comment-face ((t (:foreground "#616E88" :slant italic)))))
''');

    test('set-face-attribute', () {
      final f = seed.faces.firstWhere((f) => f.name == 'org-level-1');
      expect(f.attributes['foreground'], '#81A1C1');
      expect(f.attributes['weight'], 'bold');
    });

    test('custom-set-faces (nested display spec)', () {
      final f =
          seed.faces.firstWhere((f) => f.name == 'font-lock-comment-face');
      expect(f.attributes['foreground'], '#616E88');
      expect(f.attributes['slant'], 'italic');
    });
  });

  group('settings', () {
    final seed = harvester.harvest(r'''
(setq tab-width 4 org-ellipsis " down ")
(custom-set-variables '(indent-tabs-mode nil))
''');

    test('setq pairs decode by type', () {
      final tab = seed.settings.firstWhere((s) => s.name == 'tab-width');
      expect(tab.value, 4);
      final ell = seed.settings.firstWhere((s) => s.name == 'org-ellipsis');
      expect(ell.value, ' down ');
    });

    test('nil decodes to false', () {
      final it = seed.settings.firstWhere((s) => s.name == 'indent-tabs-mode');
      expect(it.value, false);
    });
  });

  group('diagnostics (no silent drops)', () {
    final seed = harvester.harvest(r'''
(require 'org)
(defun my/foo () 1)
(advice-add 'save-buffer :before #'my/foo)
(global-set-key (kbd "H-x") 'hyper-cmd)
''');

    test('behavioural / unsupported forms are reported, not executed', () {
      expect(seed.bindings, isEmpty);
      final reasons = seed.diagnostics.map((d) => d.reason).join('\n');
      expect(reasons, contains('unhandled form require'));
      expect(reasons, contains('unhandled form defun'));
      expect(reasons, contains('unhandled form advice-add'));
      expect(reasons, contains('untranslatable key'));
    });
  });

  group('vector / char-literal / backslash key forms', () {
    final seed = harvester.harvest(r'''
(global-set-key [f9] 'recompile)
(global-set-key [tab] 'indent-for-tab-command)
(global-set-key [?\C-x ?\C-s] 'save-buffer)
(global-set-key "\C-x\C-s" 'save-some-buffers)
(global-set-key ?\C-s 'isearch-forward)
(global-set-key [?\H-x] 'hyper-vec)
''');

    // Reference sequence the kit already produces for the space-separated form.
    final cxcs = parseEmacsKey('C-x C-s');

    test('[f9] harvests to a single f9 binding', () {
      final b = seed.bindings.firstWhere((b) => b.command == 'recompile');
      expect(b.sequence.length, 1);
      expect(b.sequence.strokes.single.keyId, LogicalKeyboardKey.f9.keyId);
      final mods = b.sequence.strokes.single;
      expect(mods.control || mods.shift || mods.alt || mods.meta, isFalse);
    });

    test('[tab] harvests to the tab key', () {
      final b = seed.bindings
          .firstWhere((b) => b.command == 'indent-for-tab-command');
      expect(b.sequence.strokes.single.keyId, LogicalKeyboardKey.tab.keyId);
    });

    test('[?\\C-x ?\\C-s] vector harvests to the 2-stroke C-x C-s sequence',
        () {
      final b = seed.bindings.firstWhere((b) => b.command == 'save-buffer');
      expect(b.sequence.length, 2);
      expect(b.sequence.token, cxcs.token);
      expect(b.sequence.label, 'Ctrl+X Ctrl+S');
    });

    test('"\\C-x\\C-s" backslash string harvests to the same C-x C-s sequence',
        () {
      final b =
          seed.bindings.firstWhere((b) => b.command == 'save-some-buffers');
      expect(b.sequence.length, 2);
      expect(b.sequence.token, cxcs.token);
      expect(b.sequence.label, 'Ctrl+X Ctrl+S');
    });

    test('bare ?\\C-s char literal harvests to a single C-s stroke', () {
      final b = seed.bindings.firstWhere((b) => b.command == 'isearch-forward');
      expect(b.sequence.length, 1);
      final c = b.sequence.strokes.single;
      expect(c.keyId, LogicalKeyboardKey.keyS.keyId);
      expect(c.control, isTrue);
    });

    test('hyper in a vector stays a diagnostic (never a wrong binding)', () {
      expect(seed.bindings.any((b) => b.command == 'hyper-vec'), isFalse);
      final reasons = seed.diagnostics.map((d) => d.reason).join('\n');
      expect(reasons, contains('untranslatable vector key'));
    });
  });

  group('defface', () {
    final seed = harvester.harvest(r'''
(defface my/banner-face
  '((t (:foreground "#88C0D0" :weight bold)))
  "Face for the banner."
  :group 'my)
(defface my/quoted-attrs '((t :foreground "#BF616A" :slant italic)) "Doc.")
(defface my/broken 'nope "Doc.")
''');

    test('harvests the first display clause as real attributes', () {
      final f = seed.faces.firstWhere((f) => f.name == 'my/banner-face');
      expect(f.attributes['foreground'], '#88C0D0');
      expect(f.attributes['weight'], 'bold');
    });

    test('reads an unwrapped attribute plist, like custom-set-faces', () {
      final f = seed.faces.firstWhere((f) => f.name == 'my/quoted-attrs');
      expect(f.attributes['foreground'], '#BF616A');
      expect(f.attributes['slant'], 'italic');
    });

    test('a malformed spec stays a diagnostic, not a wrong face', () {
      expect(seed.faces.any((f) => f.name == 'my/broken'), isFalse);
      final reasons = seed.diagnostics.map((d) => d.reason).join('\n');
      expect(reasons, contains('my/broken'));
    });
  });

  group('hooks (reported as data, never executed)', () {
    final seed = harvester.harvest(r'''
(add-hook 'text-mode-hook 'visual-line-mode)
(add-hook 'org-mode-hook #'flyspell-mode)
(add-hook 'prog-mode-hook (lambda () (setq truncate-lines t)))
(add-hook 'bad-hook 42)
''');

    test('named handlers harvest with their hook', () {
      expect(seed.handlersFor('text-mode-hook'), ['visual-line-mode']);
      expect(seed.handlersFor('org-mode-hook'), ['flyspell-mode']);
      final h = seed.hooks.firstWhere((h) => h.hook == 'text-mode-hook');
      expect(h.isLambda, isFalse);
    });

    test('a lambda handler is recorded opaquely, its body not harvested', () {
      final h = seed.hooks.firstWhere((h) => h.hook == 'prog-mode-hook');
      expect(h.handler, '<lambda>');
      expect(h.isLambda, isTrue);
      // The lambda body's setq must NOT leak in as a setting.
      expect(seed.settings.any((s) => s.name == 'truncate-lines'), isFalse);
    });

    test('add-hook is no longer a bare diagnostic', () {
      final reasons = seed.diagnostics.map((d) => d.reason).join('\n');
      expect(reasons, isNot(contains('unhandled form add-hook')));
    });

    test('a non-symbol, non-lambda handler stays a diagnostic', () {
      expect(seed.hooks.any((h) => h.hook == 'bad-hook'), isFalse);
      final reasons = seed.diagnostics.map((d) => d.reason).join('\n');
      expect(reasons, contains('hook handler is not a symbol or lambda'));
    });

    test('hooks serialise into the seed JSON', () {
      final hooks = seed.toJson()['hooks'] as List;
      expect(hooks, hasLength(3));
      expect((hooks.first as Map)['hook'], 'text-mode-hook');
      expect((hooks.first as Map)['handler'], 'visual-line-mode');
    });
  });

  group('use-package', () {
    final seed = harvester.harvest(r'''
(use-package org
  :bind (("C-c a" . org-agenda)
         ("C-c l" . org-store-link))
  :custom (org-startup-indented t)
          (org-ellipsis " ▾")
  :config (setq org-hide-emphasis-markers t)
  :init (my/setup))
(use-package magit
  :bind ("C-x g" . magit-status))
''');

    test(':bind pairs harvest as global bindings', () {
      final tokens = seed.keymapTokens();
      expect(
          tokens.values,
          containsAll(
              <String>['org-agenda', 'org-store-link', 'magit-status']));
      final agenda = seed.bindings.firstWhere((b) => b.command == 'org-agenda');
      expect(agenda.keymap, 'global');
      expect(agenda.sequence.token, parseEmacsKey('C-c a').token);
      expect(agenda.rawKey, 'C-c a');
    });

    test('a single bare :bind pair harvests too', () {
      final b = seed.bindings.firstWhere((b) => b.command == 'magit-status');
      expect(b.sequence.token, parseEmacsKey('C-x g').token);
    });

    test(':custom pairs harvest as settings', () {
      final indented =
          seed.settings.firstWhere((s) => s.name == 'org-startup-indented');
      expect(indented.value, true);
      final ell = seed.settings.firstWhere((s) => s.name == 'org-ellipsis');
      expect(ell.value, ' ▾');
    });

    test('other keywords become a diagnostic naming the keyword', () {
      final reasons = seed.diagnostics.map((d) => d.reason).join('\n');
      expect(reasons, contains('use-package org: :config not harvested'));
      expect(reasons, contains('use-package org: :init not harvested'));
      // …and the :config body is never evaluated into a setting.
      expect(seed.settings.any((s) => s.name == 'org-hide-emphasis-markers'),
          isFalse);
    });
  });

  group('char-literal keys as a direct key argument', () {
    final seed = harvester.harvest(r'''
(global-set-key ?\C-x 'ctrl-x-cmd)
(global-set-key ?a 'self-insert)
(global-set-key ?\C-\M-x 'eval-defun)
(global-set-key ?\H-x 'hyper-cmd)
''');

    test('?\\C-x binds as a single C-x stroke', () {
      final b = seed.bindings.firstWhere((b) => b.command == 'ctrl-x-cmd');
      expect(b.sequence.length, 1);
      final c = b.sequence.strokes.single;
      expect(c.keyId, LogicalKeyboardKey.keyX.keyId);
      expect(c.control, isTrue);
      expect(b.rawKey, r'?\C-x');
    });

    test('a plain ?a char literal binds unmodified', () {
      final b = seed.bindings.firstWhere((b) => b.command == 'self-insert');
      final c = b.sequence.strokes.single;
      expect(c.keyId, LogicalKeyboardKey.keyA.keyId);
      expect(c.control || c.shift || c.alt || c.meta, isFalse);
    });

    test('stacked modifiers ?\\C-\\M-x carry both', () {
      final b = seed.bindings.firstWhere((b) => b.command == 'eval-defun');
      final c = b.sequence.strokes.single;
      expect(c.keyId, LogicalKeyboardKey.keyX.keyId);
      expect(c.control, isTrue);
      expect(c.alt, isTrue);
    });

    test('an untranslatable char literal stays a diagnostic', () {
      expect(seed.bindings.any((b) => b.command == 'hyper-cmd'), isFalse);
      final reasons = seed.diagnostics.map((d) => d.reason).join('\n');
      expect(reasons, contains('untranslatable char key'));
    });
  });

  group('robustness', () {
    test('a read error yields a single diagnostic, not a throw', () {
      final seed = harvester.harvest('(global-set-key (kbd "C-x"');
      expect(seed.bindings, isEmpty);
      expect(seed.diagnostics, hasLength(1));
      expect(seed.diagnostics.single.reason, startsWith('read error'));
    });

    test('the whole seed serialises to JSON', () {
      final seed = harvester.harvest(
        "(global-set-key (kbd \"C-x C-s\") 'save-buffer)",
      );
      final json = seed.toJson();
      expect(json['bindings'], hasLength(1));
      expect((json['bindings'] as List).first, isA<Map<String, dynamic>>());
    });
  });
}
