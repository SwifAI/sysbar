# Contributing to SysBar

Thanks for helping. Bug reports, fixes and focused improvements are all welcome.

## Before you start

- **Bugs:** open an issue using the bug report form, with your macOS version, SysBar version and steps to reproduce.
- **Larger changes:** please open an issue or a discussion before writing code, so we can agree on the approach. SysBar deliberately stays small, dependency-free and cheap on energy, and some ideas don't fit that.
- **Security issues:** don't open a public issue. Follow [SECURITY.md](SECURITY.md).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE) and that you'll follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Set up

You need an Apple Silicon Mac with macOS 13 or later, Swift 6.0+ and Xcode 16+.

```bash
git clone https://github.com/SwifAI/sysbar.git
cd sysbar
swift build
./build.sh && open build/SysBar.app
```

`swift run -c release SysBar` starts a bare executable, which is faster for UI work. Notifications and Open at Login only work in the real app bundle that `./build.sh` produces.

## The three gates

CI runs these on macOS 15 and macOS 26. Run them locally before opening a pull request; a change is done only when all three pass:

```bash
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
./build.sh
```

`./build.sh` fails with status 3 if the executable or app bundle grows past its size budget. Raise a budget only on purpose, as the comment at the top of `build.sh` explains.

## Conventions

- **Style.** There's no linter or formatter; match the surrounding code.
- **Concurrency.** Strict concurrency is enforced. UI and coordination code is `@MainActor`, collectors are actors, and values crossing actor boundaries are `Sendable`.
- **Failure states.** Recoverable telemetry failure is modeled with `TelemetryState` and `TelemetryError`, not `throws`. The UI must never show a plausible-looking but wrong value.
- **Strings.** Every user-facing string goes through the `AppResources` helpers and must be added to both `Resources/Localizable.xcstrings` and the `en.lproj` runtime tables, or `LocalizationTests` fails.
- **Accessibility.** Any new UI supports Dynamic Type, VoiceOver, full keyboard control, Reduce Motion and Differentiate Without Color from the start.
- **Energy.** Work that only the popover needs must stop when the popover closes. See "Energy behavior" in the README.
- **Tests.** XCTest only, with fakes built on protocol seams. Name tests as full behavior sentences, for example `testMissingCapacityIsUnknownRatherThanAFalseFullDisk`.
- **Decisions.** Architectural choices are recorded as ADRs in [`docs/adr/`](docs/adr/). Add one when you change a decision recorded there or make a new one of the same weight.

[AGENTS.md](AGENTS.md) maps every source file and explains the pipeline and the security-sensitive areas. It's written for AI coding agents, but it's the fastest way for anyone to learn the codebase.

## Commits and pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/) with an imperative, lower-case subject and no scope, for example `fix: stop memory-used underflow wrapping to 2^64 bytes`.
- Keep each pull request to one change, and include tests for behavior changes.
- Add user-visible changes to the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md).
- For UI changes, attach before and after screenshots in light and dark mode.
