# ADR-010: Group processes by executable path, never by display name/basename

**Status:** Accepted
**Date:** 2026-09-28

## Context

A "node ×200" row once looked alarming enough to investigate. The investigation found the
row was correct: the two `node` rows on screen were two different executable paths, one
runtime installed by the user and one bundled inside another application, each with its
own set of short-lived helper processes. Grouping by basename would have merged them into
one misleading aggregate.

`Snapshot.swift` collects one record per observed PID, resolves its executable path, and
builds `ProcessGroup`s (`ProcessOverview`) keyed by `ProcessGroupID.executablePath(path)`
for identical, non-empty paths. A process whose path cannot be resolved forms its own
group keyed by `ProcessGroupID.unresolved(instanceID)` rather than being merged with
another path-less process that happens to display the same name.

## Decision

Group processes in the top-processes lists strictly by identical executable path, never by
display name or basename. A process with no resolvable path gets its own unmerged group.

## Consequences

Easier:

- Two different programs that share a filename are never conflated into one row.
- Group membership is exactly the set of identities a Quit action may signal (ADR-009),
  so a group action can never reach a same-named process from a different binary.
- `ProcessGroupingTests` asserts grouping purely from path equality.

Harder:

- A user may still misread "node ×200" as one runaway program rather than many
  legitimate helpers sharing a binary; the count is truthful but needs explanation.
- SysBar deliberately does not disambiguate further (parent PID, working directory) to
  make large counts more legible, because that would hide real executable-path
  distinctions.
