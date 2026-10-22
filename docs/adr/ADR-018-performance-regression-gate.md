# ADR-018: Performance regression gate: deterministic CI proxies instead of live CPU sampling

**Status:** Accepted
**Date:** 2026-09-28

## Context

SysBar's energy and footprint goals (closed-popover throttling, a small binary and memory
footprint) had no automated gate. The only evidence was a one-time manual measurement on
2026-08-08: 3.58 s to 0.06 s of CPU time over a 30-second closed-popover sample, a
physical footprint of about 17 MiB against a 45 MiB reference, a 1.7 MiB arm64 executable
and a 2.2 MiB signed bundle. Nothing re-checked those numbers on later commits; a
regression such as a continuously animated view or a popover-closed background task
would be caught only if someone remembered to measure again.

CI runs on GitHub-hosted `macos-15`/`macos-26` runners, which are virtualized, shared and
not guaranteed idle or consistently clocked. A CPU-time or energy measurement taken there
would reflect neighbor load and image variance as much as SysBar's own code, and
`powermetrics` needs privileges a standard job does not have. Such a gate would produce
environment-driven red builds and train people to retry CI blindly.

## Decision

Three complementary gates:

1. A deterministic release-size budget in `build.sh`: `EXECUTABLE_SIZE_BUDGET_BYTES`
   (4 MiB) and `BUNDLE_SIZE_BUDGET_BYTES` (5 MiB), literal constants with no environment
   override, measured in exact bytes after `codesign --verify --strict` and before
   `--install`. Exceeding either exits with status 3. `build.sh` is already the third
   required CI step, so this runs on every push on both matrix images. The 2026-10-16
   baseline (stripped executable) is 1,659,984 bytes and 2,268,247 bytes, leaving more than
   half of each budget free. `BuildMetadataTests` runs the check's Bash against synthetic fixtures
   (pass at exactly the budget, over budget, unmeasurable) and pins the
   `-Osize`/`-dead_strip`/`-dead_strip_dylibs` flags in `Package.swift`, because a size
   budget alone cannot detect a reverted `-Osize` (reverting it measured smaller, not
   larger, on the current toolchain).
2. The existing `MonitorSchedulingTests` and `SystemMonitorPublicationTests` suites as the
   structural proxy for the energy half: they prove the panel-open/closed gating and
   coalescing rules have not regressed, even though they measure no CPU-seconds.
3. A manual pre-release CPU and footprint check, written up as the README's "Release
   checklist": run an isolated, re-signed copy with the popover closed, require at most
   0.30 CPU-seconds over 30 seconds and a physical footprint (including peak) under
   45 MiB, and record the results in the release's CHANGELOG entry. The 1.2.0 entry
   records 0.10 CPU-seconds and an 18.0 MB footprint (22.7 MB peak).

Rejected: automating live CPU or energy sampling in CI, for the runner-variance reasons
above.

## Consequences

Easier:

- A binary-size regression (a large resource, disabled dead-stripping, a reverted
  `-Osize`) is caught on every push with no flakiness.
- The scheduling suite that already existed is now explicitly the cadence-correctness
  proof, not an implicit one.
- The next release has a concrete, repeatable measurement procedure instead of relying on
  memory.

Harder:

- The automated gate measures no CPU time or energy. A runtime regression that adds no
  code size passes it and is caught only by the manual check, which depends on a human
  performing it before each release.
- The budgets are judgment calls with headroom chosen for the current codebase. They need
  deliberate re-tuning as legitimate features add size (the comment above them in
  `build.sh` describes how), or they will either never fire or fail on honest growth.
