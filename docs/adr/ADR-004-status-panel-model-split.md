# ADR-004: Split StatusSummaryModel / PanelDetailModel publication

**Status:** Accepted
**Date:** 2026-09-28

## Context

Once ADR-003 gave the app a definitive popover open/close signal, a second problem
remained: a single shared `ObservableObject` would still redraw the always-visible
menu-bar button (and re-evaluate the whole observing view graph) on every 3-second
summary tick, and would give popover-only work no natural place to stop.

`MonitoringModels.swift` therefore declares two models. `StatusSummaryModel` holds only
the menu-bar summary and skips publication when the new value equals the current one.
`PanelDetailModel` holds one coalesced `PanelSnapshot` and publishes unconditionally; the
call site in `SystemMonitor` publishes it only while `schedule.isPanelOpen`.

## Decision

Publish menu-bar summary state and popover detail state through two independently
observable `ObservableObject`s (`StatusSummaryModel`, `PanelDetailModel`) rather than one
shared model, and gate `panelModel` publication behind the popover-open state.

## Consequences

Easier:

- The status button's subscription (`StatusItemController.subscribe(to:)`) never
  re-evaluates popover content.
- Popover-only rendering (process list, listener and disk rows) genuinely does not run
  while the popover is closed, which is what the measurement in ADR-003 depends on.
- `SystemMonitorPublicationTests` can assert precise regressions such as "closed,
  changing summaries publish status without publishing panel or sampling processes".

Harder:

- Two models means two dedup policies: `StatusSummaryModel.publish` short-circuits on
  equality, `PanelDetailModel.publish` does not because the call site already gates it.
  Moving a field between the models means re-deriving the right policy.
- A view that needs both a summary and a panel value subscribes to two objects.

Update 2026-10-16: `MenuContentView` no longer observes `panelModel` as a whole. Each
telemetry section reads it through its own `PanelReader` (`MenuView.swift`), so a panel
publication re-renders those sections and not the status line, services, footer or
dialogs. `SystemMonitor.objectWillChange` fires only for its own state (Keep Awake,
alerts). `PanelPublicationBarrier` (`MonitorScheduling.swift`) folds one tick's summary and
process results into a single publication. The split itself is unchanged.
