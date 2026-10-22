# ADR-019: Keep listener rows fail-closed for process actions; pin the production wiring with a test

**Status:** Accepted (amended by ADR-023)
**Date:** 2026-09-28

## Context

`PortsAPI` (`SystemAPIs.swift`) has a fully tested identity-bracketed overload,
`fetchResult(runner:expectedIdentities:postValidationReader:timeout:)`, which attaches a
`ProcessIdentity` to a `ListenSocket` only when a post-`lsof` re-resolution of the owning
PID exactly matches the identity captured before `lsof` ran. `lsof` itself reports no
process start time or executable path, so a post-hoc lookup alone could bless a
replacement that reused the PID; the bracketed overload narrows that window to the
duration of the `lsof` run (up to 5 seconds) but does not close it.

The production ports collector deliberately uses the zero-argument `fetchResult()`
overload, so every shipped `ListenSocket` has `processIdentity == nil` and listener rows
never offer Quit or Force Quit. Until this decision, that guarantee rested on nobody
accidentally wiring the bracketed overload into `SystemMonitor.init`; no test would have
failed if someone had.

## Decision

Keep listener rows permanently fail-closed for process actions. Users act on a listening
process through the process list (Top CPU, Top Memory), whose identities come from direct
`ProcessSampler` reads with a materially narrower window (ADR-009).

Pin the production wiring through a real seam: `SystemMonitor.defaultPortsCollector` is
the named `static let` that `init` installs when no collector is injected, and
`ProcessActionTests` calls it (and a `SystemMonitor` built without an injected collector)
after opening a real loopback listening socket in the test process, then asserts that this
socket's parsed `ListenSocket.processIdentity` is `nil`. A test that reimplemented the
closure, or ran against an empty listener list, would pass vacuously and guard nothing.

Rejected: wiring the bracketed overload into the periodic collector so listener rows gain
their own Quit/Force Quit. It would add a second, structurally weaker identity path around
a variable-duration subprocess for a destructive action, when the same process is already
reachable in the process list.

## Consequences

Easier:

- The fail-closed guarantee is an explicit, CI-enforced invariant rather than an accident
  of what has not been wired yet.
- No new identity-resolution surface is added around the app's one subprocess-mediated
  collector.
- The bracketed overload stays available and tested for a future, narrower use.

Harder:

- A user who wants to act on an unfamiliar exposed listener must find the same process in
  the process list rather than acting from the row that alerted them. The port row's
  context menu is limited to non-destructive actions (copy port, address or `lsof` command;
  open a local web service).
- The dormant overload and its tests must be maintained for a capability the rows never
  expose.

Amendment 2026-10-16 (ADR-023): the new-listener attention card may offer a confirmed
"Stop" for a command-line listener, proved at click time with a fresh bracketed scan.
Listener rows and `defaultPortsCollector` stay exactly as pinned here.
