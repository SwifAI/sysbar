# AGENTS.md

Guidance for AI coding agents, and a quick map for anyone, working on this repository.
Human contributors should also read [CONTRIBUTING.md](CONTRIBUTING.md).

## Project summary

SysBar is a native macOS menu-bar system monitor: one `NSStatusItem` plus one transient
`NSPopover` hosting a SwiftUI view hierarchy. It surfaces CPU/memory/swap/disk health,
top processes, and listening ports (LAN exposure vs. loopback), with opt-in
notifications and an IOKit "keep awake" assertion. Target is macOS 13+ on Apple Silicon
(arm64) only. Development requires Swift 6.0+ and Xcode 16+, the same floor as README.
`Package.swift`'s `swift-tools-version: 5.9` is a manifest-schema choice, not a compiler
floor; Swift 6.0 is required by `SystemMonitor`'s SE-0423 `@preconcurrency` conformance
(ADR-017). There are zero third-party package dependencies — only system frameworks
(AppKit, SwiftUI, Combine, Foundation, Darwin, IOKit, ServiceManagement,
UserNotifications, SystemConfiguration, Security, Accessibility, QuartzCore,
UniformTypeIdentifiers). Licensed under MIT (`LICENSE`).

## Build, test, lint, format

There is no linter or formatter configured (no SwiftLint/SwiftFormat) — match the style
of surrounding code.

```bash
# Debug build
swift build

# Full test suite (XCTest, Tests/SysBarTests)
swift test

# Run a single test target/class/test (XCTest filter syntax)
swift test --filter SysBarTests.MonitorSchedulingTests
swift test --filter SysBarTests.MonitorSchedulingTests/testSomeSpecificBehavior

# CI concurrency gate — must pass with zero warnings before landing changes
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

# Bare release executable (dev only — no notifications, no login-item registration,
# since those require a real app bundle)
swift run -c release SysBar

# Full signed .app bundle (release, arm64, ad-hoc codesign by default; set
# SYSBAR_SIGN_IDENTITY for Developer ID signing). Produces build/SysBar.app.
./build.sh
open build/SysBar.app

# Build and install into ~/Applications, then launch it
./build.sh --install
```

`build.sh` also generates the app icon (`tools/makeicon.swift` + `sips`/`iconutil`),
writes `Info.plist` (bundle id `io.github.swifai.sysbar`, `LSUIElement=true`, version in the
script's `VERSION`/`BUILD_NUMBER` vars), copies the SwiftPM localization resource
bundle (`SysBar_SysBar.bundle`) into the app, and verifies the code signature. It then
enforces release size budgets (`EXECUTABLE_SIZE_BUDGET_BYTES` / `BUNDLE_SIZE_BUDGET_BYTES`
near the top of the script, exact bytes) and exits 3 if either is exceeded, before any
`--install` step (ADR-018). Raise a budget only deliberately, as the comment there
describes. README's "Release checklist" is the manual pre-release CPU/footprint check.

CI (`.github/workflows/ci.yml`, matrix `macos-15`/`macos-26`) runs, in order:
`swift test` -> strict-concurrency warnings-as-errors build -> `./build.sh`. Treat all
three as required gates before considering a change done.

## Architecture

Understanding SysBar requires following one pipeline across several files — no single
file tells the whole story:

**Collect -> Schedule -> Coordinate -> Model -> Render**

1. **Collect** (`SystemAPIs.swift`) — actors `CPUSampler`, `ProcessSampler`,
   `NetworkSampler`, plus disk enumeration and a bounded `/usr/sbin/lsof` subprocess
   scan for listening ports. This is the only file that shells out to a subprocess for
   telemetry; everything else uses native Darwin/Mach/BSD/Foundation/IOKit APIs
   directly (see the System APIs table in `README.md`).
2. **Schedule** (`MonitorScheduling.swift`) — pure, dependency-free logic: monotonic
   `MonitorInstant`, adaptive-cadence `MonitorScheduleState`, and `CollectionGate` to
   coalesce overlapping collection requests. No I/O, no actors — this is why it's the
   most heavily unit-tested file.
3. **Coordinate** (`SystemMonitor.swift`) — the `@MainActor` `ObservableObject`
   coordinator. Runs independent summary/process/slow (`lsof`) collection pipelines via
   `@Sendable async` collector closures, applies alert policy (Apple-daemon allowlist +
   cooldowns) to decide when to notify, and holds the `IOPMAssertion` for keep-awake.
   It publishes two separate models — `statusModel` (menu-bar summary) and
   `panelModel` (popover detail) — specifically so that popover-only work (process
   list, slow `lsof` scans) stops when the popover is closed, per the energy behavior
   documented in `README.md`.
4. **Model** (`MonitoringModels.swift`, `Snapshot.swift`, `Theme.swift`) —
   `TelemetryState<Value>` (`loading`/`available`/`stale`/`unavailable`) and
   `TelemetryError` represent recoverable telemetry failure explicitly, so the UI never
   silently shows wrong data. `Snapshot.swift` defines process/listener identity and
   groups processes by executable path (so two different programs that happen to share
   a filename are never merged). `Theme.swift` maps values to `MetricSeverity` /
   `MetricPresentation` with formatting thresholds.
5. **Render** (`StatusItemController.swift`, `StatusGlyph.swift`, `MenuView.swift`,
   `Components.swift`, `Trace.swift`) — `StatusItemController` owns the single
   `NSStatusItem` (its image is the `StatusGlyphRenderer` CPU sparkline), `NSPopover`, and
   `NSHostingController` (`StatusItemLifecycle`, `PopoverSizePolicy`). `MenuView.swift`
   composes the "Seismograph" popover — exposure strip, optional freshness strip, four
   metric lanes on one 3-minute time axis (`Trace.swift`), then the process/port/service
   ledgers — and manages focus/VoiceOver. Healthy lanes are monochrome ink; color appears
   only at warning/critical. Trace ink is drawn by Core Animation (`TraceInk`,
   `CAShapeLayer`); the per-sample paper-feed slide is a `CABasicAnimation` run by the
   render server. Do not move that motion back into SwiftUI animations, add
   `contentTransition(.numericText())`, or add frame-driven timers: each measured at
   5-17× the open-popover CPU cost. Don't draw lane chrome with a SwiftUI `Canvas`
   either: it made SwiftUI render with Metal in-process and spiked the footprint by
   ~210 MB on every popover open; `TraceBackdropView` uses shape layers instead. The top
   of the popover is the attention status strip (`AttentionModel`, `AttentionViews.swift`);
   AI briefs explain rule-raised items and never run on a timer.

Two supporting subsystems hang off this pipeline:

- **Process actions** (`ProcessActions.swift`) — quit/force-quit is identity-bound: it
  captures PID + exact start time + executable path, then revalidates all three
  immediately before signaling, so a recycled PID can never be signaled by mistake.
- **Optional AI briefs** (`AttentionRules.swift` -> `AttentionModel.swift` ->
  `AIBrief.swift` / `AIProviders.swift`) — local rules raise attention items; for each
  one `AttentionModel` asks the user's Claude Code or Codex CLI (opt-in, Off · Claude ·
  Codex) for one brief through `BoundedProcessRunner` (`BoundedProcessRunner.swift`:
  direct `Process`, no shell, bounded stdin/stdout/stderr, timeout, cancellation, child
  reaping). Each brief ends in one or two buttons from a closed catalog
  (`AttentionActions.swift`, ADR-022): SysBar sends the AI only the (action,
  subject) pairs it can execute, the AI picks at most two, `ActionPlanner` validates and
  fills per-rule defaults, and `AttentionModel` runs the action (apps by bundle location
  via `RunningAppControlling`, processes via `ProcessActionService`) and verifies the
  result from fresh samples (`SystemMonitor.resampleForVerification`). Notification
  buttons route back through `NotificationResponder` (`AppServices.swift`).

`App.swift` (`@main` `SysBarMain` on the plain AppKit lifecycle, `AppDelegate`, hidden
`MainMenu`) and `AppServices.swift` (notification
authorization state machine, `NotificationDeliveryPolicy`, login-item registration via
`ServiceManagement`) wire lifecycle and OS integration around the pipeline above.
`AppResources.swift` resolves the localization bundle and exposes
localized/formatted/plural string helpers used everywhere user-facing text is produced.
`KernelPageSize.swift` isolates the one `@preconcurrency import var
Darwin.vm_kernel_page_size` needed for memory accounting so the rest of the codebase
stays under strict concurrency cleanly.

## Source layout

| File | Role |
|---|---|
| `App.swift` | `@main` AppKit entry point (no SwiftUI scenes), `AppDelegate`, hidden `MainMenu` |
| `AppResources.swift` | Localization bundle resolution; `localized`/`formatted`/plural helpers |
| `StatusItemController.swift` | `NSStatusItem` + `NSPopover` + `NSHostingController` lifecycle |
| `SystemMonitor.swift` | `@MainActor` coordinator: pipelines, alert policy, keep-awake |
| `MonitorScheduling.swift` | Pure scheduling: monotonic time, adaptive cadence, `CollectionGate` |
| `MonitoringModels.swift` | `TelemetryError`/`TelemetryState`, memory/swap/process-start types |
| `Snapshot.swift` | Snapshot types; process/listener identity and grouping |
| `ProcessActions.swift` | Identity-bound quit/force-quit with revalidation before signaling |
| `SystemAPIs.swift` | Collector actors (CPU/process/network), disk, bounded `lsof` scan |
| `KernelPageSize.swift` | Isolated `Darwin.vm_kernel_page_size` import |
| `BoundedProcessRunner.swift` | `BoundedProcessRunner`: bounded, cancellable, shell-free subprocess runner for the AI CLIs |
| `Components.swift` | Reusable accessible SwiftUI building blocks (lanes, exposure/freshness strips, ledger rows) |
| `Trace.swift` | Seismograph trace engine: pure `TraceGeometry`/`MetricThresholdLines`, `TracePlot`, scrubbing, Audio Graph |
| `StatusGlyph.swift` | Menu-bar CPU sparkline: `StatusGlyphModel` quantization + cached template `StatusGlyphRenderer` |
| `AttentionRules.swift` | Pure local rules R1–R6 (`AttentionTracker`): runaway app, host CPU, memory, swap growth, disk, new LAN listener |
| `AttentionModel.swift` | `@MainActor` attention coordinator: items, one AI brief per item, caps, dismiss/snooze/mute/allow, action execution and verification, history, review, provider choice |
| `AttentionActions.swift` | Closed action catalog: `SubjectResolver`, `ActionCatalog`, `ActionPlanner`, `ActionLabel`, `ActionVerification`; app/settings boundaries (`RunningAppControlling`, `SettingsOpening`) |
| `AIBrief.swift` | Evidence sent to the AI, prompts, response schemas, validation (`BriefValidation`) |
| `AIProviders.swift` | `BriefProviding`: `ClaudeCodeProvider`, `CodexBriefProvider`, signature-verified CLI location, `AIProviderPolicy` |
| `AttentionViews.swift` | Status strip, action-first brief card (`ActionButton`), review card, Off · Claude · Codex switch |
| `MenuView.swift` | Popover composition, focus/VoiceOver handling |
| `Theme.swift` | `MetricSeverity`, presentation formats and thresholds |
| `AppServices.swift` | Notification authorization, delivery policy, login item |
| `Resources/` | `Localizable.xcstrings` (source of truth) + `en.lproj` runtime tables |

## Testing conventions

- XCTest only, via `@testable import SysBar` — no mocking library. Fakes are built
  against protocol seams (`ProcessIdentityReading`, `BoundedProcessRunning`, injected
  collector closures).
- Test names are full behavior sentences, e.g.
  `testMissingCapacityIsUnknownRatherThanAFalseFullDisk`. Follow this style for new
  tests rather than terse `testX()` names.
- `MonitorSchedulingTests` is the largest pure-logic suite — check it first when
  touching scheduling. AI briefs are covered by `AttentionRulesTests`,
  `AttentionModelTests`, `AttentionActionsTests` and `AIBriefTests`; the subprocess runner by
  `BoundedProcessRunnerTests`.
- `LocalizationTests` enforces that `Localizable.xcstrings` and the checked-in
  `en.lproj` `.strings`/`.stringsdict` runtime tables stay in sync. Any new
  user-facing string must be added to both, or this suite fails.

## Conventions

- Strict concurrency is enforced (CI builds with
  `-strict-concurrency=complete -warnings-as-errors`). UI and coordination code is
  `@MainActor`; collectors are actors; values crossing actor boundaries are `Sendable`.
- Recoverable telemetry failure is modeled with `TelemetryState`/`TelemetryError`, not
  `throws` — the UI must never render a plausible-looking but wrong value. `throws` is
  reserved for actual I/O/process boundaries (e.g. the `lsof` subprocess, the AI CLI
  subprocesses).
- All user-facing strings go through `AppResources`'s localized/formatted/plural
  helpers, and must be added to both `Resources/Localizable.xcstrings` and
  `Resources/en.lproj/Localizable.strings` (or `.stringsdict` for plurals) — see
  `LocalizationTests`.
- UI is accessibility-first: Dynamic Type, reduce-motion, differentiate-without-color,
  semantic colors, and full keyboard/VoiceOver support are expected on any new UI
  surface, not an afterthought.

## Security-sensitive areas

- `ProcessActions.swift` — quit/force-quit must remain identity-bound (PID + start
  time + executable path revalidated immediately before signaling) to avoid signaling
  a recycled PID.
- `SystemAPIs.swift` — the `lsof` listener scan is the only subprocess in the core
  telemetry path; keep it bounded (timeout, output size) and its argument list fixed.
- `AIProviders.swift` — AI CLIs run only after their Developer ID designated requirement
  (Anthropic `Q6L2SF6YDW`, OpenAI `2DC432GLL2`) validates, re-checked before every call;
  with a restricted environment (`PATH`, `HOME`/`USER`/`LOGNAME`, no API keys), a private
  temp working directory, bounded I/O, a 30 s timeout, no tools/MCP/settings/session
  (`--tools ""`, `--strict-mcp-config`, `--setting-sources ""`, Codex `--sandbox read-only`
  plus `--ignore-user-config`), and a JSON schema. Never pass Claude Code `--bare` (it
  skips the user's OAuth login).
- `AIBrief.swift` — evidence is deliberately unredacted but bounded to what
  SysBar already collects; replies are plain text (no links/code). The schema's action
  `id` is an enum without `forceQuit`.
- `AttentionActions.swift` / `AttentionModel.swift` — never execute an action that is not
  in the list `ActionCatalog.allowed` sent for that item; button labels are catalog
  strings, never model text. `SubjectResolver` excludes `/System/`, `/usr/`, `/bin/`,
  `/sbin/`, `/Library/Apple/` and SysBar itself. Apps are matched by bundle location
  (never PID or bundle identifier); process groups are re-resolved live and signaled only
  through `ProcessActionService`. Quitting more than one process and every Force Quit
  must confirm; Force Quit is only a follow-up after a quit visibly failed.
- `BoundedProcessRunner.swift` — never invokes a shell; keep stdin/stdout/stderr
  capped, the timeout and cancellation enforced, and the child reaped (SIGTERM, then
  SIGKILL). A pipe held open past the drain grace must fail, never return truncated
  output.

## Commit style

Conventional Commits, imperative lower-case subject, no scope: `fix:`, `feat:`,
`docs:`, `chore:`, `build:`, `perf:`, `refactor:` (e.g. `fix: stop memory-used
underflow wrapping to 2^64 bytes`).

## Gotchas

- `proc_taskallinfo`'s `pti_total_user`/`pti_total_system` are Mach absolute-time ticks,
  not nanoseconds (125/3 ns per tick on Apple Silicon). `ProcessSampler.cpuPercent`
  converts them; until 2026-10-16 they were read as nanoseconds and every per-process
  CPU figure was about 41x too low (pinned by `ProcessSamplerTests`, including a real
  busy-thread check).
- `swift run -c release SysBar` is a bare executable, not the app bundle — notification
  delivery and login-item registration silently no-op because both require a real
  bundle identity. Use `./build.sh` + `open build/SysBar.app` to exercise those paths.
- `StatusItemController` intentionally owns exactly one `NSStatusItem` and one
  `NSPopover` for the process lifetime; don't introduce a second popover/status item.
- `SystemMonitor` deliberately keeps `statusModel` and `panelModel` separate. If you
  add new panel-only work, gate it behind popover-open state the same way, or you will
  regress the documented energy behavior (README "Energy behavior" section).
- Architectural decisions live in `docs/adr/` as `ADR-NNN-<slug>.md` (Context, Decision,
  Consequences). Add a new ADR, or update the status of an old one, when a change
  overturns or makes a decision of that weight; code comments cite ADRs by number.
