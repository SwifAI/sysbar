# ADR-012: Opt-in notification authorization, never requested at launch, double-gated delivery

**Status:** Accepted
**Date:** 2026-09-28

## Context

A menu-bar utility that requests notification permission unconditionally at launch trains
users to dismiss permission prompts reflexively and gives people who never want alerts a
worse first run. SysBar's alerts are security-relevant (new LAN-exposed ports, critical
memory, VPN transitions) but still opt-in.

`AppServicesModel.setAlertsDesired(true)` (`AppServices.swift`) is the only path that
requests OS authorization, and only when the OS reports `.notDetermined`; nothing in
`applicationDidFinishLaunching` asks. Delivery is double-gated:
`NotificationDeliveryPolicy.isActive(desired:authorization:alertSetting:)` requires the
stored user preference, a live OS authorization of `.authorized` or `.provisional`, and a
live OS alert setting of `.enabled`.

Only the notification service branches on bundle identity: `AppServicesModel.live()`
installs `UnavailableNotificationService` when `Bundle.main.bundleIdentifier` is `nil`
(a bare `swift run` executable) and `UserNotificationService` otherwise. The login-item
service is always `MainAppLoginItemService`; its `currentStatus()` reports `.unavailable`
without a bundle identity, while `register()`/`unregister()` call `SMAppService` directly.

## Decision

Never request notification authorization at launch. Request it only as the direct
consequence of an explicit user opt-in, and deliver only when the stored preference and
the OS's live authorization and alert-setting state all agree.

## Consequences

Easier:

- The first run never interrupts the user with a system permission dialog before they have
  shown interest in alerts.
- A user who revokes permission in System Settings stops receiving SysBar notifications
  immediately; the gate re-checks live OS state, so SysBar does not need to detect the
  revocation itself.
- `AppServicesTests` drives every authorization-state transition, including states hard to
  reach live (denied, provisional, alerts disabled), through fakes.

Harder:

- "Get notified" depends on two independent pieces of state, which is one more thing to
  explain when the in-app toggle is on and nothing fires because the OS setting disagrees.
  `NotificationServiceState.requiresOpenSettings` exists to surface that discrepancy with a
  link to System Settings rather than leaving it invisible.
