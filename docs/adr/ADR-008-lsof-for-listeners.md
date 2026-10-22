# ADR-008: Use /usr/sbin/lsof for listener enumeration instead of parsing kernel socket structures

**Status:** Accepted
**Date:** 2026-09-28

## Context

SysBar needs an inventory of listening TCP and UDP sockets to show LAN exposure. macOS has
no supported public API for enumerating all listening sockets system-wide. The closest
native primitive, `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`, requires iterating every PID and
reading the kernel's socket-info struct layout directly, and that layout has been brittle
across SDKs.

`ProcessLsofCommandRunner` (`SystemAPIs.swift`) runs `/usr/sbin/lsof` with a fixed,
literal argument vector (`-iTCP -sTCP:LISTEN -iUDP -P -n -FpcnP`), a 5-second timeout and
a 4 MiB output cap (ADR-020), drains stdout concurrently with waiting for exit, and
`PortsAPI` parses the structured `-F` field output. The argument list is never built from
user or generated input.

## Decision

Enumerate listening sockets by running the fixed-path system utility `/usr/sbin/lsof`
with a fixed argument vector, rather than reading kernel socket structures through
`proc_pidfdinfo`.

## Consequences

Easier:

- `lsof`'s `-F` output format is stable and documented; SysBar does not track undocumented
  kernel struct changes across macOS releases.
- `/usr/sbin/lsof` ships with every supported macOS version, so nothing is bundled or
  version-pinned.

Harder:

- This is the only subprocess in the core telemetry path, and it is a real trust
  boundary: child-process output is untrusted, `lsof` has a Darwin-specific exit-status
  quirk for empty results, and the runner must bound time, memory and reaping itself.
- Each listener scan pays process-spawn and pipe-drain overhead rather than a direct
  syscall, which is why scans run on a slower cadence than the summary tick.
- `lsof` reports no process start time or executable path, so a listener row cannot carry
  a trustworthy process identity on its own (ADR-019, ADR-023).
