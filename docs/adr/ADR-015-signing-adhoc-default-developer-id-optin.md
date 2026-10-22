# ADR-015: Ad-hoc code signing by default, Developer ID signing opt-in via SYSBAR_SIGN_IDENTITY

**Status:** Accepted
**Date:** 2026-09-28

## Context

`build.sh` must produce a runnable `.app` for local development and CI without requiring
every contributor to hold a paid Apple Developer Program membership, while still
supporting a hardened, notarizable signature for anyone distributing the app more widely.

`build.sh` reads `SIGN_IDENTITY="${SYSBAR_SIGN_IDENTITY:--}"`. When unset it runs
`codesign --force --sign -` (ad-hoc); when set it runs `codesign --force --options runtime
--timestamp --sign "$SIGN_IDENTITY"` (Developer ID, hardened runtime, secure timestamp).
Either way it then runs `codesign --verify --strict`, so a build never silently produces an
unverifiable signature. CI runs `./build.sh` with the variable unset, so every CI run
exercises the ad-hoc path and its verification.

## Decision

Default to ad-hoc signing, make Developer ID signing an explicit opt-in through
`SYSBAR_SIGN_IDENTITY`, and always verify the resulting signature. Notarization and
stapling stay a separate step outside `build.sh`.

## Consequences

Easier:

- Any contributor can build and run a fully functional `.app` with no Apple Developer
  account.
- CI needs no signing secret to validate the build and signing pipeline end to end.
- A Developer ID holder opts into a hardened, Gatekeeper-friendly signature with one
  environment variable and no second code path.

Harder:

- An ad-hoc signature has no stable Team ID, so Gatekeeper and TCC cannot pin trust to it
  across rebuilds. Published release builds are ad-hoc signed and not notarized, so macOS
  blocks the first launch until the user chooses "Open Anyway" or clears the quarantine
  flag; the README documents both.
- Notarization and stapling are unimplemented here and must be added by whoever performs a
  notarized release.
