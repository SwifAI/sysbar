# ADR-005: Monotonic-instant, pure scheduling state machine

**Status:** Accepted
**Date:** 2026-09-28

## Context

Adaptive cadence (popover open or closed, alerts on or off, the attention watch) decides
when processes, ports and disk are collected and when overlapping requests are coalesced.
Using wall-clock `Date` for that arithmetic would expose scheduling to NTP adjustments,
sleep/wake clock jumps and daylight-saving transitions; a monotonic uptime clock is immune
to all three.

`MonitorScheduling.swift` imports only `Foundation` and contains no actor and no I/O.
`MonitorInstant` is an offset on a monotonic timeline; `SystemMonitor.currentInstant()` is
the one bridge that builds it from `ProcessInfo.processInfo.systemUptime`.
`MonitorInstant.duration(since:)` returns `nil` for a reversed comparison instead of a
negative duration. `MonitorScheduleState` rejects any instant older than the latest one it
accepted, with one deliberate exception: `invalidate(_:collectedAt:)` bypasses that check
so a discarded collection result can still roll back its own cadence reservation.
`CollectionGate` allows one active collection and coalesces further demand into one
repeat.

## Decision

Express all cadence and coalescing logic as pure, dependency-free, non-actor-isolated
value types keyed on a monotonic `MonitorInstant`, never `Date`.

## Consequences

Easier:

- `MonitorSchedulingTests` is the largest suite in the codebase because every cadence and
  coalescing edge case can be exercised deterministically with no fake seam, actor or
  real clock.
- Scheduling is immune to wall-clock adjustments that would otherwise cause flaky tests
  and production cadence bugs.

Harder:

- Every caller must source instants from `SystemMonitor.currentInstant()` rather than
  reading `systemUptime` or `Date()` directly, or the monotonic-ordering guarantee breaks
  silently.
- The `invalidate(_:collectedAt:)` asymmetry is a subtle invariant that must be preserved,
  not "fixed" into symmetry.
