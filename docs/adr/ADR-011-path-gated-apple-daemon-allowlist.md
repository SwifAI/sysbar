# ADR-011: Path-gated Apple-daemon allowlist plus name-keyed ephemeral-port dedupe

**Status:** Accepted
**Date:** 2026-09-28

## Context

macOS system daemons (`rapportd`, `mDNSResponder`, `sharingd` and others) bind fresh
ephemeral ports throughout the day. Alerting on each rebind produced notification spam
severe enough to cause a CPU spike and to make users disable alerts entirely.

A first fix added a name-based allowlist, but it never suppressed anything: the trust
check required an executable path, and the ports collector deliberately attaches no
process identity to listeners (ADR-019). A name alone is also not trustworthy, since any
program can call itself `rapportd`.

The current implementation resolves the executable path at alert-decision time, not from
the listener's (absent) identity. `SystemMonitor.resolveListenerPaths` does one path
lookup per listening PID per scan; `SystemMonitor.isTrustedAppleListener` trusts a
listener only when its name is on `SystemMonitor.portAlertAllowlist` (21 names, matched
both as `lsof` reports it, truncated to nine characters, and as the executable's full file
name) and the live path is under `/System/Library/`, `/usr/libexec/`, `/usr/sbin/` or
`/Library/Apple/System/Library/`. An unresolvable path or any other location alerts.

The same change added ephemeral-port dedupe: `ListenerDiff.exposuresAdded`
(`Snapshot.swift`) keys listeners at or above port 49152 by `(processName, transport)`,
so a daemon rebinding many times a day is one exposure fact, not one alert per rebind.

## Decision

Suppress a LAN-exposure alert for an allowlisted Apple daemon name only when a live,
alert-time executable-path lookup resolves under a SIP-protected system location. A stale
PID here can at worst suppress one alert; it can never authorize an action. Deduplicate
repeated ephemeral-port exposures per `(processName, transport)` rather than per exact
endpoint, accepting that a same-named newcomer's ephemeral listener may be masked while
the original still holds one.

## Consequences

Easier:

- Apple daemons that legitimately rebind ephemeral ports no longer generate one
  notification per rebind, so the alert channel stays useful for new exposures.
- The allowlist cannot launder a real exposure: trust requires re-resolving the live path
  at the moment of the decision.

Harder:

- The dedupe key is name-only, so a second same-named process's first ephemeral listener
  can be absorbed into an existing suppression window. This narrow false-negative window
  was chosen deliberately over per-rebind spam. Service ports below the ephemeral floor
  keep exact per-endpoint alerting.

Update 2026-10-15: the popover applies the same verdict. `SystemMonitor` records the
listeners this rule trusts as `PanelSnapshot.trustedListenerKeys` on each successful ports
scan, and the exposure strip and port rows count only the remaining listeners. Trust still
fails toward visibility: a lookalike name or an unresolvable path is flagged. With AI
briefs on, the attention watch's new-listener rule reports exposures instead of the
notification path, using the same trust verdict.
