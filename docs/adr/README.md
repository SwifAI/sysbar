# Architecture Decision Records

This directory records the significant architectural decisions behind SysBar: the
problem each one solved, the forces at play, what was decided, and the trade-offs
accepted. Code comments cite them by number (for example "ADR-018"). To add one, copy the
format of any file here (`# ADR-NNN: Title`, Status and Date, then Context, Decision and
Consequences), take the next free number, start with status Proposed, and change it to
Accepted once the decision is agreed and implemented. A decision that replaces an earlier
one marks the old record "Superseded by ADR-NNN" rather than deleting it.

| ADR | Title | Status | Date |
|---|---|---|---|
| [ADR-001](ADR-001-zero-third-party-dependencies.md) | Zero third-party dependencies | Accepted | 2026-09-28 |
| [ADR-002](ADR-002-swiftpm-and-scripted-app-bundle.md) | SwiftPM manifest plus a scripted app bundle (no Xcode project) | Accepted | 2026-09-28 |
| [ADR-003](ADR-003-appkit-status-item-popover.md) | AppKit NSStatusItem + NSPopover instead of SwiftUI MenuBarExtra | Accepted | 2026-09-28 |
| [ADR-004](ADR-004-status-panel-model-split.md) | Split StatusSummaryModel / PanelDetailModel publication | Accepted | 2026-09-28 |
| [ADR-005](ADR-005-monotonic-pure-scheduler.md) | Monotonic-instant, pure scheduling state machine | Accepted | 2026-09-28 |
| [ADR-006](ADR-006-telemetry-state-not-throws.md) | Explicit TelemetryState instead of throws for recoverable telemetry failure | Accepted | 2026-09-28 |
| [ADR-007](ADR-007-actor-isolation-strict-concurrency.md) | Actor isolation plus strict concurrency, warnings-as-errors | Accepted | 2026-09-28 |
| [ADR-008](ADR-008-lsof-for-listeners.md) | Use /usr/sbin/lsof for listener enumeration | Accepted | 2026-09-28 |
| [ADR-009](ADR-009-identity-bound-process-signaling.md) | Identity-bound process signaling with pre-signal revalidation | Accepted | 2026-09-28 |
| [ADR-010](ADR-010-group-by-executable-path.md) | Group processes by executable path, never by basename | Accepted | 2026-09-28 |
| [ADR-011](ADR-011-path-gated-apple-daemon-allowlist.md) | Path-gated Apple-daemon allowlist plus ephemeral-port dedupe | Accepted | 2026-09-28 |
| [ADR-012](ADR-012-opt-in-notifications.md) | Opt-in notification authorization, double-gated delivery | Accepted | 2026-09-28 |
| [ADR-013](ADR-013-codex-health-brief-boundary.md) | Opt-in, signature-validated, sandboxed Codex CLI boundary for health explanations | Superseded by ADR-022 | 2026-09-28 |
| [ADR-014](ADR-014-string-catalog-plus-runtime-tables.md) | String Catalog authoring, checked-in runtime tables | Accepted | 2026-09-28 |
| [ADR-015](ADR-015-signing-adhoc-default-developer-id-optin.md) | Ad-hoc signing by default, Developer ID signing opt-in | Accepted | 2026-09-28 |
| [ADR-016](ADR-016-xctest-protocol-seams.md) | XCTest only, fakes at protocol/closure seams, no mocking library | Accepted | 2026-09-28 |
| [ADR-017](ADR-017-toolchain-baseline.md) | Toolchain baseline: Swift 6.0 / Xcode 16 compiler floor | Accepted | 2026-09-28 |
| [ADR-018](ADR-018-performance-regression-gate.md) | Performance regression gate: deterministic CI proxies | Accepted | 2026-09-28 |
| [ADR-019](ADR-019-listener-row-actions-policy.md) | Keep listener rows fail-closed; pin the production wiring (amended by ADR-023) | Accepted | 2026-09-28 |
| [ADR-020](ADR-020-bound-lsof-output.md) | Cap lsof stdout accumulation | Accepted | 2026-09-28 |
| [ADR-021](ADR-021-coordinator-text-formatting-layering.md) | Move PortDisplayText to the Model layer; drop SystemMonitor's unused SwiftUI import | Accepted | 2026-09-28 |
| [ADR-022](ADR-022-closed-action-catalog.md) | The AI picks, SysBar executes: closed action catalog | Accepted | 2026-10-16 |
| [ADR-023](ADR-023-click-time-revalidated-listener-stop.md) | Stop a command-line listener only after a click-time re-proof (amends ADR-019) | Accepted | 2026-10-16 |
