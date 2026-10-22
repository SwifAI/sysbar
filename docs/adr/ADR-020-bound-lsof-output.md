# ADR-020: Cap lsof stdout accumulation

**Status:** Accepted
**Date:** 2026-09-28

## Context

The `lsof` runner originally read stdout with a single `readDataToEndOfFile()` call into an
`NSLock`-guarded `Data` box. The only bound on memory was the 5-second timeout: an
unusually large or adversarial `lsof` run could accumulate an arbitrarily large buffer
within that window before being discarded. A byte cap inside the box's `store` method
would not have helped, because `readDataToEndOfFile()` allocates the entire pipe contents
before `store` is ever called.

The codebase already had the right shape in its AI CLI runner: a drain loop that reads in
small chunks and appends each chunk to a size-capped accumulator, so the loop itself never
holds more than the cap plus one chunk.

## Decision

Make `ProcessLsofCommandRunner.run(timeout:)` drain stdout in `readChunkSize` (4,096-byte)
chunks through `FileHandle.read(upToCount:)` into `LsofOutputBuffer`, a capped,
lock-guarded accumulator with a `defaultOutputLimit` of 4 MiB, several orders of magnitude
above any real listener inventory on a personal Mac. The drain keeps reading and
discarding past the cap so the child can never block on a full pipe: the cap bounds
retained memory, the timeout still bounds time.

On overflow, throw `LsofCommandRunnerError.outputTooLarge`, which takes precedence over a
timeout and over the exit status, and let `PortsAPI.fetchResult` map it to a
`TelemetryError.collector` failure. The listening-ports field then transitions to
`.stale` or `.unavailable` through `TelemetryState.recordingFailure` (ADR-006), like any
other collector failure; never return a silently truncated or partially parsed result.
The fixed argument vector and the 5-second timeout are unchanged.

Rejected: leaving stdout bounded only by the timeout. A timeout bounds time, not memory,
and the pattern to close the gap already existed in the same codebase.

The same chunked-throwing-read technique is used by `BoundedProcessRunner` for the AI
CLIs, whose `CappedDataBuffer` enforces the same cap-while-draining shape.

## Consequences

Easier:

- The listener scan's worst-case memory exposure is a fixed constant.
- The failure mode needs no new concept in the UI; it is one more `.collector` error.

Harder:

- A second way for the ports pipeline to fail (a scan over budget) must be shown
  truthfully even when the host is healthy; the ports section goes stale.
- The 4 MiB figure is a judgment call with no measured maximum behind it. It is a fixed
  literal, to be revisited on real user reports rather than made configurable.
