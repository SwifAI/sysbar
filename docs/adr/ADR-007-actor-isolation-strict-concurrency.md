# ADR-007: Actor isolation plus strict concurrency, warnings-as-errors

**Status:** Accepted
**Date:** 2026-09-28

## Context

SysBar runs several genuinely concurrent collectors (CPU, process and network sampling,
the `lsof` subprocess, the AI CLI subprocesses) alongside a `@MainActor` UI coordinator.
Each collector keeps mutable baseline state (previous CPU ticks, previous network byte
counters) that must never be raced by overlapping scheduler ticks.

The codebase isolates that state behind actors (`CPUSampler`, `ProcessSampler`,
`NetworkSampler` in `SystemAPIs.swift`; `ProcessActionService` in `ProcessActions.swift`;
`SignatureCache`, `ClaudeCodeProvider` and `CodexBriefProvider` in `AIProviders.swift`),
pins UI and coordination to `@MainActor` (`AppDelegate`, `StatusItemController`,
`SystemMonitor`, `AppServicesModel`, `AttentionModel`), and scopes each unavoidable
legacy-API escape to the file that needs it with `@preconcurrency import`:
`Darwin.vm_kernel_page_size` in `KernelPageSize.swift`, `SystemConfiguration` in
`SystemAPIs.swift`, and `UserNotifications` in `AppServices.swift` and `App.swift`. The
`UserNotifications` import was added on 2026-09-29 after the `macos-15` CI leg (Swift
6.1.2, macOS 15 SDK) rejected a non-`Sendable` `UNNotificationSettings` result that Swift
6.3 and later accept; that SDK does not annotate the UserNotifications types as `Sendable`.

The few `@unchecked Sendable` types (`LsofOutputBuffer` in `SystemAPIs.swift`;
`BoundedProcessRunner` and its private `ProcessBox`, `ProcessCancellation` and
`CappedDataBuffer` in `BoundedProcessRunner.swift`) are each justified by an explicit
`NSLock` or single-owner handoff.

CI runs `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
as a required gate on every push and pull request, on both matrix images.

## Decision

Isolate every collector or service with per-instance mutable state behind an `actor`, pin
UI and coordination state to `@MainActor`, pass only `Sendable` values across actor
boundaries, scope every `@preconcurrency import` to the file that needs it, and enforce
`-strict-concurrency=complete -warnings-as-errors` as a required CI gate.

## Consequences

Easier:

- Data races on collector baseline state are caught at compile time, not in production or
  in a flaky test.
- Every `@unchecked Sendable` type is a deliberate, explained exception.
- CI fails immediately on any new concurrency warning, so the discipline cannot erode.
- The matrix proved its worth: the strict gate caught a Swift 6.1.2-only failure that the
  newer local toolchain could not see.

Harder:

- Every new collector, service or cross-actor value must be designed for `Sendable` from
  the start (for example `SummarySample`'s four independently `Result`-typed fields).
- Contributors unfamiliar with the actor model face a steeper on-ramp than a
  `DispatchQueue`/lock codebase presents.
- The `@preconcurrency` imports are narrow, permanent exceptions. In Swift 5 language mode
  the `UserNotifications` one suppresses `Sendable` diagnostics for those types across the
  importing file, so a genuine race there would not be caught at compile time. Acceptable
  because the file only calls UserNotifications through the `@MainActor`
  `UserNotificationService`; revisit when Apple annotates the framework or the package
  moves to Swift 6 language mode (ADR-017).
