// Org support: a Dart client for the `orgsupport` Go binary (tools/orgsupport),
// which owns org parsing verbs the Dart side does not reimplement — document
// `structure` (headings + `#+begin_src` blocks with their language and content
// line ranges), `tangle`, and babel execution.
//
// Promoted out of the example app so any host can use it: the client is pure
// `dart:async`/`dart:convert`/`dart:io` with no app coupling, and both the
// gallery example and the eedit editor consume it from here rather than each
// carrying a copy.
//
// Opt-in, like the anthy/kana bridges: it is deliberately NOT re-exported from
// `desktop_kit.dart`, since it presumes an external binary on the host.
library desktop_kit_org;

export 'src/org/org_support_client.dart';
