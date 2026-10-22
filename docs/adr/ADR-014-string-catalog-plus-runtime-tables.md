# ADR-014: Author with a String Catalog, ship checked-in .strings/.stringsdict runtime tables

**Status:** Accepted
**Date:** 2026-09-28

## Context

SysBar has no Xcode project (ADR-002), so it cannot rely on Xcode's build phase to compile
`Resources/Localizable.xcstrings` (the authoring String Catalog) into a runtime resource.

`Package.swift` declares `defaultLocalization: "en"` and two resource rules:
`.process("Resources/en.lproj")`, a hand-maintained `.strings`/`.stringsdict` pair that
SwiftPM ships and the app reads at runtime, and `.copy("Resources/Localizable.xcstrings")`,
the authoring catalog copied verbatim so a parity test can read it. `AppResources`
(`AppResources.swift`) resolves the `SysBar_SysBar.bundle` installed in the app's
`Contents/Resources`, falling back to `Bundle.module` for bare `swift build`/`test`/`run`,
and exposes the `localized`/`formatted`/`plural` helpers every user-facing string goes
through.

## Decision

Author user-facing strings in `Localizable.xcstrings`, but ship and read the checked-in
`en.lproj/Localizable.strings` and `.stringsdict` runtime tables. Keep the two in sync with
`LocalizationTests.testStringCatalogAndEnglishRuntimeTableStayInSync` rather than relying
on SwiftPM or Xcode to compile the catalog.

## Consequences

Easier:

- Xcode's String Catalog editor remains available for authoring, while the shipped
  resource is a plain, portable `.strings`/`.stringsdict` pair that works identically under
  `swift build`, `swift test`, bare `swift run` and the `build.sh` bundle.
- No SwiftPM String Catalog compilation feature needs to exist or work for the app to
  localize correctly.

Harder:

- The catalog and the runtime table are two independently editable artifacts that drift
  if a contributor edits one without the other. The parity test is the only thing that
  stops that drift from shipping, so every new string must be added to both.
- Only English ships today; there is no automated check that a translated locale, if one
  were added, would keep the same parity guarantee.
