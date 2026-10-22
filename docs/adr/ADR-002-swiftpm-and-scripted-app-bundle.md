# ADR-002: SwiftPM manifest plus a scripted app bundle (no Xcode project)

**Status:** Accepted
**Date:** 2026-09-28

## Context

SysBar must ship as a signed `LSUIElement` `.app` bundle (icon, `Info.plist`, localization
resources, code signature). An `.xcodeproj` would provide that through build phases, at
the cost of an opaque, merge-conflict-prone project file and a CI that needs a specific
Xcode scheme.

`Package.swift` is the only build manifest: one `.executableTarget` with resource rules
and release `-Osize`/`-dead_strip` settings. `build.sh` is a hand-written Bash script that
runs `swift build -c release --arch arm64`, writes a dSYM and strips the executable,
copies the SwiftPM-generated `SysBar_SysBar.bundle` into `Contents/Resources`, generates
`AppIcon.icns` (`tools/makeicon.swift` plus `sips`/`iconutil`), writes `Info.plist` and
`PkgInfo`, code-signs, verifies the signature, checks the release size budgets (ADR-018),
and optionally installs into `~/Applications`. CI (`.github/workflows/ci.yml`) runs
`swift test`, the strict-concurrency build and `./build.sh` on a `macos-15`/`macos-26`
matrix; there is no `xcodebuild` step anywhere.

## Decision

Build and package SysBar with SwiftPM plus `build.sh`, for both local development and CI.
Do not add an Xcode project or workspace.

## Consequences

Easier:

- The whole build is reproducible from the command line and readable top to bottom:
  icon generation, `Info.plist` fields, signing identity selection, the size budgets and
  the `--install` termination safety check are ordinary Bash.
- CI needs only a Swift toolchain, not a configured Xcode scheme.
- No project-file merge conflicts.

Harder:

- No Xcode GUI project browser, Interface Builder, or built-in asset-catalog/String
  Catalog compilation; icon generation and localization-resource copying are reimplemented
  in Bash (see ADR-014 for the localization side).
- `swift run -c release SysBar` produces a bare executable, not the bundle, so
  notification delivery and login-item registration silently no-op there (both need a real
  bundle identity). `./build.sh` is required to exercise those paths.
- Opening `Package.swift` in Xcode does not produce the same signed artifact as
  `./build.sh`; contributors must know this.
