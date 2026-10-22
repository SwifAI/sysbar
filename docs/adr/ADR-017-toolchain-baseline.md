# ADR-017: Toolchain baseline: Swift 6.0 / Xcode 16 compiler floor

**Status:** Accepted
**Date:** 2026-09-28

## Context

The README once stated "Swift 5.10+ and Xcode 15.3+" and `Package.swift` declares
`swift-tools-version: 5.9`. Both understate the real floor. `SystemMonitor.swift`
declares `final class SystemMonitor: @preconcurrency ObservableObject`: a `@preconcurrency`
attribute on a conformance, the feature from SE-0423 that first shipped in Swift 6.0 /
Xcode 16. It is not the file-scoped `@preconcurrency import` (available since Swift 5.6)
used elsewhere, there is no `#if compiler(>=6.0)` fallback around it, and the source
simply does not compile on an earlier compiler.

`swift-tools-version` cannot express a compiler floor at all. It selects which manifest
DSL SwiftPM parses and a few tools-version-gated defaults, not which language features
the compiler accepts in the package's sources. The manifest number (5.9) and the compiler
floor (6.0) had quietly diverged.

Raising the manifest to `swift-tools-version: 6.0` would make SwiftPM refuse older
toolchains upfront, but it also switches the package to Swift 6 language mode by default.
That mode differs from the current CI gate (`-strict-concurrency=complete` under Swift 5
mode) in ways not yet verified against SysBar's source: SE-0423's runtime isolation checks
at `@preconcurrency` conformances, several upcoming features enabled by default, and the
test target (which CI builds without any strictness flag) being compiled under Swift 6
mode for the first time. Pinning `swiftLanguageModes: [.v5]` would avoid that, but is
itself only available once the manifest says 6.0, so this is a real migration, not a
documentation change.

## Decision

Keep `Package.swift` at `swift-tools-version: 5.9` (the manifest uses only long-stable
declarative APIs) and stop treating that number as a compiler floor. State the real floor
in the README's requirements, "Swift 6.0+ and Xcode 16+", and in `CLAUDE.md`, and pin it
with `BuildMetadataTests.testReadmeStatesSwift6AndXcode16FloorInsteadOfStaleSwift510Floor`.

Rejected for now: raising `swift-tools-version` to 6.0. Revisit once a tools-6.0,
`swiftLanguageModes: [.v5]`-pinned build has been verified on both CI images.

## Consequences

Easier:

- The README states the number that actually determines whether `git clone && ./build.sh`
  succeeds, and a test keeps it from going stale.

Harder:

- `Package.swift` remains an unreliable minimum-toolchain indicator for this project.
  Anyone reading the manifest programmatically (`swift package tools-version`, a package
  index) sees 5.9 and may assume an older toolchain suffices; only the README and the test
  carry the accurate floor.

Update 2026-09-29: the CI matrix now builds with Apple Swift 6.1.2 (Xcode 16.4) on
`macos-15` and Swift 6.3.3 on `macos-26`. The 6.1.2 leg initially failed the
strict-concurrency gate on UserNotifications `Sendable` diagnostics and passed after
`@preconcurrency import UserNotifications` was added (ADR-007). Swift 6.1.2 is therefore
the oldest observed toolchain, one minor above the documented floor; the exact 6.0.0
toolchain and Swift 6 language mode remain unexercised.
