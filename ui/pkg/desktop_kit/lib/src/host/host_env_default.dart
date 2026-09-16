/// Resolves the platform [HostEnv] by conditional import, and exposes the
/// process-wide instance.
///
/// | Condition | Environment |
/// |---|---|
/// | `dart.library.io` | the real process environment |
/// | `dart.library.js_interop` | empty — no variables, no home, no processes |
/// | neither | empty stub |
library;

import 'package:meta/meta.dart';

import 'host_env.dart';
import 'host_env_stub.dart'
    if (dart.library.io) 'host_env_io.dart'
    if (dart.library.js_interop) 'host_env_web.dart' as impl;

export 'host_env.dart';

HostEnv? _override;
HostEnv? _cached;

/// The host environment for this process.
///
/// Resolved once and cached. Tests can replace it via [debugSetHostEnv].
HostEnv get hostEnv => _override ?? (_cached ??= impl.createHostEnv());

/// Replaces [hostEnv] for the duration of a test; pass null to restore the
/// real environment.
@visibleForTesting
void debugSetHostEnv(HostEnv? env) => _override = env;
