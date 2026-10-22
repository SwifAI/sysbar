# ADR-021: Move PortDisplayText to the Model layer and drop SystemMonitor's unused SwiftUI import

**Status:** Accepted
**Date:** 2026-09-28

## Context

SysBar's pipeline is Collect, Schedule, Coordinate, Model, Render, with the rule that
Render reads Coordinate and Model, never the reverse. A review found one violation:
`SystemMonitor.detectPorts` (Coordinate) built notification text by calling
`PortDisplayText.listenerAlertBody(processName:bindAddress:port:)`, which lived in
`Components.swift` (Render). `PortDisplayText` is pure string formatting over
`ListenSocket`, `Int` and `String` values with no `View` conformance; it was in
`Components.swift` only because `PortRow` also uses it for on-screen text.

The same review found that `SystemMonitor.swift` imported SwiftUI without using a single
SwiftUI symbol. `SystemMonitor` publishes through a manually driven
`ObservableObjectPublisher` from Combine, not `@Published`, so the import was a leftover
from the earlier SwiftUI-hosted panel (ADR-003, ADR-004).

`Thresholds` in `Theme.swift`, which `SystemMonitor` also reads, is a plain value type and
belongs to the Model layer alongside `MetricSeverity` and `MetricPresentation`; the
`Color`/`Font` helpers declared in the same file are an accepted file-level exception
consumed only by Render.

## Decision

Move `PortDisplayText` unchanged into `MonitoringModels.swift`, next to `MetricFormat`,
the existing home for shared non-SwiftUI formatting that Coordinate and Render both use.
`PortRow` keeps calling the same API from its new location with no change to its output.
Remove the unused `import SwiftUI` from `SystemMonitor.swift`.

Rejected: documenting the Coordinate-to-Render call as a permanent accepted exception.
Unlike the platform-imposed windows accepted in ADR-009 and ADR-011, this one had no
reason to remain and a mechanical fix.

## Consequences

Easier:

- `SystemMonitor.swift` has no compile-time dependency on `Components.swift`; its imports
  (AppKit, Combine, Foundation, IOKit, os) reflect what it uses.
- `PortDisplayText` sits next to its closest sibling in purpose.

Harder:

- The move had to change no observable string. `FormattingTests` and
  `ListenerPresentationTests` cover `PortDisplayText`'s output and must keep passing when
  it is touched.
