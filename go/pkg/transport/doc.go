// Package transport is the form-independent plumbing contract shared by this
// family's Go daemons and their Flutter clients.
//
// # Why this package exists
//
// The family is eleven Go-daemon + Flutter-client pairs. A census measured what
// each side shares for backend integration and what each side wrote for itself:
//
//	shared   154 lines   (the kit's host_process seam)
//	forked 6,379 lines   across 7 apps
//
// That is the worst shared-to-forked ratio of any capability in the codebase —
// worse than settings, worse than chrome. The category was invisible to the
// first census because recurring shapes were derived from a WIDGET-name filter,
// and a backend client is not a widget.
//
// The load-bearing observation is what those 6,379 lines actually are. They are
// not encoding. They are connect, reconnect, backoff, health, cancellation and
// lifecycle — which is why a gomobile MethodChannel and a D-Bus proxy differ
// completely in form and have *identical* plumbing problems.
//
// # Standardize FUNCTION, not FORM
//
// Standardization and decoupling CONFLICT when you standardize on form: one wire
// format everywhere means every consumer takes that dependency, so a JSON-RPC-
// over-stdio sidecar drags in protobuf and a mobile bridge drags in a session
// bus. That is precisely the coupling that stranded six consumers of the kit on
// a single version.
//
// They ALIGN when you standardize on function. "Every client reconnects with the
// same policy and reports health the same way" costs no shared dependency,
// because reconnect semantics are encoding-independent.
//
// So this package owns function and knows nothing about form. Everything
// form-specific lives behind [Wire]: a stdio JSON-RPC adapter, a gRPC adapter, a
// D-Bus proxy adapter and a MethodChannel adapter all satisfy the same
// interface, and no consumer takes a dependency it does not need. No single
// transport covers every function this family needs, so any "standardize on one
// transport" answer is wrong on function grounds before cost is considered.
//
// # Parallel dispatch is first-class, and why that is not obvious
//
// Concurrent in-flight request/response is in this contract from v1. It needs no
// isolates on the Dart side: an event loop is single-threaded but
// *asynchronous*, so while a request waits on I/O the caller is free.
//
// The measured argument is head-of-line blocking. Stdio JSON-RPC is a single
// byte stream, so one large response — a directory listing, a render result, a
// lexicon dump — stalls every message queued behind it on that pipe. Four
// consumers in this family speak JSON-RPC over stdio today.
//
// Do not confuse this with decode cost. Across the family only 6 of 544 Dart
// files use isolates, so essentially every payload is deserialized on the UI
// isolate, and no amount of wire multiplexing fixes a large decode janking a
// frame. These are different problems: dispatch is about *waiting*, decode is
// about *CPU*. This package solves the first. Decode placement is deliberately
// out of scope until someone profiles frame time, which nobody has — the
// 6-of-544 figure is a risk, not an observed defect, and it is recorded as such.
//
// # Backpressure is not optional here
//
// Because dispatch is parallel, a concurrency policy is part of the contract
// rather than per-app: max in-flight, and what happens on overflow. Family-wide,
// backpressure is effectively absent — an unbounded queue is the default almost
// everywhere, which converts a slow consumer into unbounded memory growth
// instead of into a signal. [Policy] makes the choice explicit and
// [ErrOverflow] makes it observable.
package transport
