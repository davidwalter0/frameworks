/// Host abstraction — what the platform underneath the app can and cannot do,
/// and how to ask it.
///
/// Import this when writing code that must behave differently on a desktop, a
/// browser talking to a local backend, and a browser on its own. The three
/// pieces:
///
/// - [HostCapabilities] / [HostCapability] / [CapabilityStatus] — the declared
///   capability manifest. Read it to decide what to enable, and to *explain*
///   what you disabled. This is the contract that keeps platform divergence
///   visible instead of turning it into silent no-ops.
/// - [HostEnv] — environment variables, path separator, home directory, and
///   whether the host has processes at all.
/// - [HostProcessResult] / `runHostProcess` / `hostExecutableExists` — the
///   subprocess seam, free of `dart:io` types.
library;

export 'src/host/capabilities.dart';
export 'src/host/host_env_default.dart';
export 'src/host/host_process_default.dart';
