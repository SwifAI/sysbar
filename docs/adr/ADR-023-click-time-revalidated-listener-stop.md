# ADR-023: Stop a command-line listener only after a click-time identity and endpoint re-proof (amends ADR-019)

**Status:** Accepted
**Date:** 2026-10-16

## Context

ADR-019 keeps every listener row fail-closed: the periodic ports collector attaches no
`ProcessIdentity`, because `lsof` reports no start time or executable path and a PID can
be recycled between the scan and a click. ADR-022 then made the new-listener attention
card act on the owning app (quit by bundle location) or allow the port. That left the most
common case, a command-line program such as `node *:3000` with no running `.app`, with only
"Allow" and "Remind me in 15 min"; ADR-019's own consequences name the cost.

`PortsAPI.fetchResult(runner:expectedIdentities:postValidationReader:timeout:)` already
exists and is tested: it attaches an identity only when the PID re-resolves after `lsof`
to the identity captured before it. ADR-019 rejected it for the periodic collector, where
the identity would be captured long before any click. Capturing it at the click is a
different proposition.

## Decision

Add one card-only action, `AttentionActionID.stopListener` ("Stop node…"), and leave
listener rows and the periodic collector exactly as ADR-019 pins them. The action:

1. Is offered only for the card's trigger listener whose executable resolves to
   `.commandLine` or `.bundledTool` in `SubjectResolver`: never a process inside a running
   app (that is quit-the-app), never under `/System/`, `/usr/` (except `/usr/local/`),
   `/bin/`, `/sbin/` or `/Library/Apple/`, never SysBar itself, never when the path is
   unknown or contains a `..` component. It is destructive and AI-selectable, never
   notification-safe, and an `expected` verdict strips it like every destructive pick.
2. On the click, resolves the PID's identity once (`ProcessIdentityResolver`: BSD info,
   path, BSD info again) and refuses without asking if that fails or the path differs from
   the scan's.
3. Always confirms, naming the process, executable path and endpoint of that identity.
4. On confirmation, re-runs the same fixed, bounded `lsof` scan through the bracketed seam
   (`PortsAPI.ownership(of:expected:)`) with that identity as the only expected one.
   `ListenerOwnership.evaluate` requires the same PID, start time, path and `lsof` process
   name to still own exactly that bind address, port and transport. A closed endpoint,
   another owner, a changed identity or a failed scan is refused with no signal and a
   fresh ports scan.
5. Only then sends `SIGTERM` through `ProcessActionService`, which revalidates the
   identity immediately before `kill(2)` (ADR-009). No `SIGKILL` escalation is offered
   from this card.
6. Verifies like every other action: a ports re-scan must show the endpoint closed before
   the item resolves.

## Consequences

Easier:

- The card for a dev server or script ends in a real remedy instead of a pointer to
  another section.
- A recycled PID cannot be signaled at any point: before the click (path check), between
  click and confirmation or during the scan (bracketed post-validation), or between the
  scan and the signal (`ProcessActionService` revalidation). `ListenerStopTests` and
  `AttentionModelTests.testARecycledPIDIsNeverSignaledWhetherItIsReplacedBeforeOrAfterTheRescan`
  pin each window against the real `PortsAPI.ownership` and `ProcessActionService`.

Harder:

- One extra user-initiated `lsof` run per confirmed Stop, bounded by the same timeout and
  output cap, never periodic.
- The bracketed seam's narrow window remains, now covered by the extra pre-`kill`
  revalidation; the kernel-level window between the last BSD read and `kill(2)` stays as
  ADR-009 documents.
- `/usr/local/` is carved out of the protected prefixes because SIP leaves it writable and
  the nodejs.org installer and Intel Homebrew put the owner's programs there, so
  `/usr/local/bin/node` gets Stop (and a runaway one gets Quit) like `/opt/homebrew/bin/node`.
  The carve-out is matched case-sensitively, a path with a `..` component stays protected,
  and everything else under `/usr/` stays protected, so an Apple daemon there still gets
  "Open Sharing Settings". A root-owned daemon under `/usr/local` can be offered Stop;
  SysBar runs as the user, so `kill(2)` fails with `EPERM`, nothing is stopped, and the
  card shows the failure.
- ADR-019's rejected alternative, identity on every listener row, stays rejected; its
  pinning tests are unchanged and must stay green.
