# ADR-001: Zero third-party dependencies

**Status:** Accepted
**Date:** 2026-09-28

## Context

SysBar is a small, always-running menu-bar utility. Every third-party Swift package it
linked would add supply-chain surface (an unaudited transitive dependency inside a process
that can, opt-in, launch a network-capable AI CLI), binary size, and an obligation to track
upstream releases for a project with no dedicated security team.

`Package.swift` declares one `.executableTarget` and one `.testTarget`, both with no
package dependencies. Every collector, the listener scanner, process actions and the OS
service wrappers are written directly against Darwin, Mach, BSD, AppKit, Foundation and
IOKit APIs rather than a convenience wrapper package.

## Decision

Add no third-party Swift package to the SysBar target or its test target. Every capability
is implemented against Apple system frameworks or a fixed-path subprocess
(`/usr/sbin/lsof`, and the opt-in `claude`/`codex` CLIs), never a linked library.

Where a native API was judged too fragile, the project preferred a stable system tool
over a package: listener enumeration uses `lsof` rather than parsing kernel socket
structures (ADR-008).

## Consequences

Easier:

- No dependency-resolution step in CI or `build.sh`; `swift build` never touches a
  package registry.
- No transitive-vulnerability surface to audit, which matters most for the two
  security-sensitive integrations (the `lsof` scan and the AI CLI boundary).
- The release binary stays small by construction; there is no unused library code to
  `-dead_strip`.
- Every API call site can be audited against Apple's own documentation.

Harder:

- Everything a package might have provided (JSON-schema validation, process management,
  notification scheduling) is hand-written and hand-tested against Darwin APIs.
- Contributors need Darwin/Mach/BSD API literacy rather than familiarity with a popular
  package's API surface.
- Test doubles are hand-written too (ADR-016).
