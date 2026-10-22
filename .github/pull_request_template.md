## What this changes

<!-- One or two sentences. Link the issue it fixes, e.g. "Fixes #12". -->

## How it was tested

<!-- Tests added or updated, and what you checked by hand. Attach light and dark screenshots for UI changes. -->

## Checklist

- [ ] `swift test` passes
- [ ] `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` passes
- [ ] `./build.sh` passes, within the size budgets
- [ ] New user-facing strings are in both `Localizable.xcstrings` and the `en.lproj` tables
- [ ] New UI works with VoiceOver, keyboard, Dynamic Type and Reduce Motion
- [ ] User-visible changes are in the `Unreleased` section of `CHANGELOG.md`
