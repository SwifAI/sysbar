# ADR-009: Identity-bound process signaling with immediate pre-signal revalidation

**Status:** Accepted
**Date:** 2026-09-28

## Context

The original process actions signaled basename-grouped PIDs without revalidating identity
or confirming multi-process and force-kill actions. A PID recycled by the kernel between
the moment the user selects a row and the moment SysBar signals it could make SysBar kill
an unrelated, newly launched process.

`ProcessActions.swift` captures a `ProcessIdentity` (PID, exact start time, executable
path) at selection time. `ProcessIdentityResolver` reads BSD info, then the executable
path, then BSD info again, and fails if the two reads differ or the process is idle, a
zombie, or exiting. `ProcessActionService.perform` runs a whole-batch preflight first (any
unsafe or stale member aborts the entire batch with no signal sent), then re-resolves and
revalidates each identity immediately before its own `kill(2)`. PID `<= 1` and SysBar's
own PID are always rejected.

macOS has no `pidfd` equivalent, so there is necessarily a tiny kernel-level TOCTOU window
between the final BSD read and `kill(2)`. It is documented in the source and accepted.

## Decision

Bind every process action (Quit, Force Quit) to a captured `ProcessIdentity`, reject
PID `<= 1` and the self PID unconditionally, abort an entire batch on any preflight
failure, and re-resolve and revalidate each identity immediately before its own signal.
Accept the residual kernel-level TOCTOU window as platform-imposed rather than attempting
to eliminate it.

## Consequences

Easier:

- A recycled PID between selection and signal can never cause SysBar to kill the wrong
  process through any path this code controls.
- `ProcessActionTests` simulates identity changing mid-flight, zombie and idle states and
  PID reuse with a scripted `ProcessIdentityReading` fake, without spawning real
  processes.
- The accepted kernel window is documented where a reviewer would look.

Harder:

- Every action costs at least two identity resolutions per process (preflight and
  pre-signal) instead of a single `kill(2)`.
- `build.sh --install` has to apply the same "exact executable path, never process name"
  rule independently in Bash when it stops a running installed copy, because the Swift
  guarantee does not cover the installer.
