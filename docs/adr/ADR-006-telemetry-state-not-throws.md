# ADR-006: Explicit TelemetryState instead of throws for recoverable telemetry failure

**Status:** Accepted
**Date:** 2026-09-28

## Context

The original collectors represented errors with the same empty values as healthy states,
producing false messages such as "No listeners" or "VPN Off". A monitor that cannot
distinguish "truly zero listeners" from "the listener scan failed" is actively misleading
for a security-relevant display.

`MonitoringModels.swift` models every telemetry field as `TelemetryState<Value>` with four
cases: `.loading`, `.available(value, sampledAt:)`, `.stale(value, sampledAt:, error:)`
and `.unavailable(TelemetryError)`. Collectors return `Result<Value, TelemetryError>`
rather than throwing. `TelemetryState.recordingFailure(_:)` keeps the last known-good
value and its original `sampledAt` when transitioning from `available` or `stale`; only
`loading` and `unavailable`, which hold no value, collapse to `unavailable`. That is what
lets the UI show "last updated 12 s ago, now delayed" instead of blanking a row.

## Decision

Represent every recoverable telemetry failure as an explicit `TelemetryState` case
(`Result<Value, TelemetryError>` at the collector boundary), never as a thrown error.
Reserve `throws` for genuine I/O and subprocess boundaries: the `lsof` subprocess, the AI
CLI subprocesses, `UNUserNotificationCenter` and `SMAppService`.

## Consequences

Easier:

- Every render site pattern-matches the four cases explicitly; there is no path for a
  forgotten `catch` to swallow an error and fall through to a plausible default.
- Collector failures are uniform at the type level, so the UI needs one freshness and
  error presentation for all of them.

Harder:

- New collectors must follow the `Result`/`TelemetryState` convention instead of the more
  familiar `throws`/`try` idiom.
- Real I/O boundaries still need `throws`, so the codebase carries two error-propagation
  styles rather than one.
