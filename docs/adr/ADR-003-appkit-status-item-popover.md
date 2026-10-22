# ADR-003: AppKit NSStatusItem + NSPopover instead of SwiftUI MenuBarExtra

**Status:** Accepted
**Date:** 2026-09-28

## Context

The original design used SwiftUI's `MenuBarExtra`. Measured on 2026-08-08, the offscreen
panel kept receiving `ObservableObject` publications and repainting four animated rings:
3.58 CPU-seconds during a 30-second closed-panel sample, about 11.9% of one core. Panel
visibility inferred from SwiftUI view lifetime could not reliably prove the panel was
hidden, so popover-only work (process sampling, port and disk scans) kept running while
the panel was closed.

Three approaches were considered:

1. An AppKit `NSStatusItem`/`NSPopover` shell hosting SwiftUI content through
   `NSHostingController`. AppKit delegate callbacks give definitive open/close
   transitions.
2. Keep `MenuBarExtra` and bridge its hosting window through `NSViewRepresentable`.
   Rejected: the host window stays framework-owned and its lifecycle is hard to test and
   control across macOS releases.
3. Visual and accessibility changes only. Rejected: it does not address the measured
   offscreen energy use.

Option 1 was implemented. Re-measured afterwards: 0.06 CPU-seconds over the same
30-second closed-popover sample (0.2% of one core, against a target below 1%).

## Decision

Use one `NSStatusItem` and one transient `NSPopover` hosting an `NSHostingController`-
wrapped SwiftUI tree, driven by `NSPopoverDelegate` callbacks. `StatusItemLifecycle`
(`StatusItemController.swift`) turns AppKit's possibly duplicated show/close callbacks into
balanced panel sessions and reports them to `SystemMonitor` through `PanelSessionHandling`.
Never use SwiftUI's `MenuBarExtra` scene.

## Consequences

Easier:

- Popover open/close is an authoritative, testable AppKit signal.
  `StatusItemLifecycleTests` exercises it with a spy conformer and no real `NSPopover`.
- The panel-gated energy model (ADR-004) rests on this signal.

Harder:

- The app is a hybrid AppKit/SwiftUI architecture. `StatusItemController` manages
  `NSHostingController` sizing (`PopoverSizePolicy`), screen-edge clearance and
  secondary-display anchoring by hand.
- `StatusItemController` must own exactly one status item and one popover for the
  process lifetime. The type system does not enforce this; it is a discipline.
