/// Browser subprocess seam — there are none.
///
/// [hostExecutableExists] returns false rather than throwing, because that is
/// the answer callers are already structured to handle: `PrimarySelection`
/// probes for `xclip`, gets false, and reports itself unsupported with an
/// install hint. Making the probe throw would turn a graceful degrade into a
/// crash on a code path that was already correct.
///
/// [runHostProcess] does throw, because reaching it means a caller skipped the
/// probe and genuinely assumed a process host.
library;

import 'host_process.dart';

/// Always throws [HostProcessUnsupported]; browsers cannot spawn processes.
Future<HostProcessResult> runHostProcess(
  String exe,
  List<String> args, {
  String? stdin,
}) async =>
    throw HostProcessUnsupported(exe);

/// Always false — no executable is reachable from a browser.
Future<bool> hostExecutableExists(String exe) async => false;
