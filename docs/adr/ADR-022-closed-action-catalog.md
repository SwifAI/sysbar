# ADR-022: The AI picks, SysBar executes: a closed action catalog keyed by bundle location and process identity

**Status:** Accepted
**Date:** 2026-10-16

## Context

Attention briefs explained what was wrong but ended in at most "Show in Top CPU" or a
confirmed Quit of one process group. The goal was for each brief to end in the action
itself, without letting a language model (fed process names it does not control) decide
what SysBar executes.

Two facts measured while designing this shaped it: renderer helpers such as
`Codex (Renderer)` are not `NSRunningApplication`s, so "quit the app" and "quit the
helper" are different mechanisms; and bundle identifiers are not trustworthy names (one
installed ChatGPT.app reported `com.openai.codex`), whereas bundle locations are.

## Decision

1. A closed catalog, `AttentionActionID` (`AttentionActions.swift`), of things SysBar can
   do with no new entitlements, no admin prompt, no file deletion and no shell commands:
   restart, quit or open an app, quit a process group, open Storage or Sharing settings,
   allow a listener, stop a command-line listener (ADR-023), snooze; plus force quit and
   reopen as follow-ups the AI cannot select.
2. Per item, `ActionCatalog.allowed` computes the exact (action, subject) pairs possible
   right now. Only that list (at most 40 entries, with at most 12 apps) is sent to the AI,
   which returns at most two picks with a one-sentence reason each. The whole evidence is
   capped at `BriefEvidence.maximumBytes` (20 KB), pinned by `AIBriefTests`.
3. `ActionPlanner` drops any pick not in the list while keeping the brief, allows at most
   one destructive button, reorders for an `unsure` verdict, strips destructive picks for
   an `expected` verdict, and fills per-rule defaults so a card always has a button even
   with no AI. Button labels are catalog strings (`ActionLabel`), never model text.
4. Apps are addressed by bundle location: `NSRunningApplication.terminate()`, then
   `NSWorkspace.openApplication(at:)` with `activates = false` for a restart
   (`WorkspaceAppController`). Helpers and command-line tools are addressed by identity
   through `ProcessActionService` (ADR-009 unchanged). `SubjectResolver` never offers a
   destructive action for `/System/`, `/usr/` (except `/usr/local/`), `/bin/`, `/sbin/`,
   `/Library/Apple/` or SysBar itself. Listener rows stay non-actionable (ADR-019).
5. Every destructive action is verified from SysBar's own re-samples
   (`SystemMonitor.resampleForVerification`, `ActionVerification`). Force Quit is reachable
   only after a quit visibly failed, and always confirms. Quitting more than one process
   also confirms.

## Consequences

- A prompt-injected process name cannot relabel a button or reach an action SysBar did not
  offer for that item.
- The evidence grows by the `apps` and `actions` lists, within the byte cap.
- Verification adds a few extra samples per click, popover open or closed.
- `terminate()` sends the consent-exempt quit Apple event. If a future macOS prompts for
  Automation consent, the action degrades to "didn't accept the quit request" with Force
  Quit offered.
- AI calls are capped at `AttentionModel.maxCallsPerHour` (6), and nothing is sent while
  nothing is wrong.
