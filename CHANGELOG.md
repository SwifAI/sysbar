# Changelog

All notable changes to SysBar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Opening the popover right after a background sample could show SysBar itself, and other
  briefly busy processes, at about 100% CPU in Top CPU for one update. Process CPU is now
  only computed over at least one second; a sample that comes sooner repeats the last full
  reading.

## [1.2.0] - 2026-10-16

First public release. Earlier versions were developed privately and aren't listed here.

### Added

- **Seismograph popover.** CPU, memory, swap and disk run as four lanes on one 3-minute time
  axis, with the pointer scrubbing all four at once. Healthy lanes are monochrome ink; color
  appears only at warning or critical. The menu-bar item shows a CPU sparkline.
- **Attention watch.** Local rules notice an app holding more than a core (5 minutes in the
  background, 20 if it's the frontmost app), CPU pinned, memory low, swap growing, disk low or
  filling fast, and a new non-Apple program accepting network connections. The status line at
  the top says "Everything looks normal" or what needs attention, in SysBar's own numbers.
- **Action buttons on every attention card.** Restart, Quit or Open the app that owns a runaway
  helper (matched by bundle location), Quit a command-line process, Stop a command-line program
  listening on the network after re-checking at click time that it still owns the port, Open
  Storage or Sharing Settings, Allow a listener, or Remind me in 15 minutes. After a click
  SysBar re-samples and reports the result ("Done · … back to 3%"), offering Force Quit, always
  confirmed, only after a quit visibly failed. The same buttons appear on notifications.
- **AI briefs with Claude Code or Codex (Off · Claude · Codex).** For each raised item, your own
  CLI and subscription write a short brief and choose among the actions SysBar computed; SysBar
  writes every label. Each CLI is verified by its Developer ID signature before every call and
  runs with no tools, MCP servers, settings or saved session, a 30-second timeout and a strict
  JSON schema. Briefs are capped at six an hour, and nothing is sent while nothing is wrong.
  **Review now** asks for a whole-Mac check.
- **Top processes** grouped by executable path, with identity-bound Quit and Force Quit.
- **Listening ports** with LAN exposure kept apart from loopback, verified macOS services listed
  but never flagged, and search by process, PID, port, protocol or address.
- **Network context**: VPN state, primary address, DNS and transfer rates.
- **Opt-in alerts**, **Keep Awake** and **Open at Login**.
- Full VoiceOver, keyboard, Dynamic Type, Reduce Motion and Differentiate Without Color support;
  each lane is also available as an Audio Graph.

### Performance

Measured on an Apple M5 Max with macOS 27.0.1, using the release checklist in the README:

- Popover closed: 0.10 CPU-seconds over 30 seconds (target 0.30), physical footprint 18.0 MB
  with a peak of 22.7 MB (target under 45 MiB).
- Popover open and idle: 1.4–1.9% CPU.
- Release executable 1.63 MiB, app bundle 2.30 MiB.

[Unreleased]: https://github.com/SwifAI/sysbar/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/SwifAI/sysbar/releases/tag/v1.2.0
