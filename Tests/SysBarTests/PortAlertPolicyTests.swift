import Foundation
import XCTest
@testable import SysBar

@MainActor
final class PortAlertPolicyTests: XCTestCase {
    // MARK: - Ephemeral-port diff identity

    func testEphemeralRebindBySameProcessIsNotANewExposure() {
        let before = socket(pid: 500, name: "rapportd", port: 50_300)
        let after = socket(pid: 500, name: "rapportd", port: 53_086)

        XCTAssertEqual(ListenerDiff.exposuresAdded(from: [before], to: [after]), [])
    }

    func testEphemeralRebindAfterDaemonRestartIsNotANewExposure() {
        let before = socket(pid: 500, name: "rapportd", port: 50_300)
        let after = socket(pid: 811, name: "rapportd", port: 53_086)

        XCTAssertEqual(ListenerDiff.exposuresAdded(from: [before], to: [after]), [])
    }

    func testNewProcessOnEphemeralPortIsReported() {
        let existing = socket(pid: 500, name: "rapportd", port: 50_300)
        let newcomer = socket(pid: 900, name: "curl", port: 59_869)

        XCTAssertEqual(
            ListenerDiff.exposuresAdded(from: [existing], to: [existing, newcomer]),
            [newcomer]
        )
    }

    func testWellKnownPortsKeepExactEndpointIdentity() {
        let before = socket(pid: 500, name: "postgres", port: 5_432)
        let moved = socket(pid: 500, name: "postgres", port: 5_433)

        XCTAssertEqual(ListenerDiff.exposuresAdded(from: [before], to: [before, moved]), [moved])
    }

    func testEphemeralProcessReturningAfterFullDisappearanceIsReportedAgain() {
        let listener = socket(pid: 500, name: "rapportd", port: 50_300)

        XCTAssertEqual(ListenerDiff.exposuresAdded(from: [], to: [listener]), [listener])
    }

    // MARK: - Apple allowlist suppression in the alert path

    func testAllowlistedAppleDaemonListenerDoesNotAlert() async throws {
        let harness = try await AlertHarness(
            pathsByPID: [500: "/usr/libexec/rapportd"],
            baseline: [],
            update: [socket(pid: 500, name: "rapportd", port: 53_086)]
        )
        XCTAssertEqual(harness.portAlerts, [])
    }

    func testImposterUsingAllowlistedNameStillAlerts() async throws {
        let harness = try await AlertHarness(
            pathsByPID: [700: "/Users/example/Downloads/rapportd"],
            baseline: [],
            update: [socket(pid: 700, name: "rapportd", port: 53_086)]
        )
        XCTAssertEqual(harness.portAlerts.count, 1)
    }

    func testUnknownProcessListenerStillAlerts() async throws {
        let harness = try await AlertHarness(
            pathsByPID: [900: "/opt/homebrew/bin/node"],
            baseline: [],
            update: [socket(pid: 900, name: "node", port: 5_173)]
        )
        XCTAssertEqual(harness.portAlerts.count, 1)
    }

    func testAllowlistedNameWithUnresolvablePathStillAlerts() async throws {
        let harness = try await AlertHarness(
            pathsByPID: [:],
            baseline: [],
            update: [socket(pid: 600, name: "rapportd", port: 53_086)]
        )
        XCTAssertEqual(harness.portAlerts.count, 1)
    }
}

// MARK: - Helpers

private func socket(pid: Int32, name: String, port: UInt16) -> ListenSocket {
    ListenSocket(pid: pid, processName: name, port: port, bindAddress: "*", isTCP: true)
}

@MainActor
final class TrustedListenerPanelTests: XCTestCase {
    func testTrustMatchesTheFullExecutableNameWhenLsofTruncatesTheCommand() {
        let pairing = ListenSocket(pid: 1, processName: "remotepai", port: 3_722, bindAddress: "*", isTCP: false)
        let identity = ListenSocket(pid: 2, processName: "identitys", port: 4_400, bindAddress: "*", isTCP: true)
        XCTAssertTrue(SystemMonitor.isTrustedAppleListener(
            pairing,
            executablePath: "/Library/Apple/System/Library/PrivateFrameworks/RemotePairing.framework/Versions/A/XPCServices/remotepairingd.xpc/Contents/MacOS/remotepairingd"
        ))
        XCTAssertTrue(SystemMonitor.isTrustedAppleListener(
            identity,
            executablePath: "/System/Library/PrivateFrameworks/IDS.framework/identityservicesd.app/Contents/MacOS/identityservicesd"
        ))
    }

    func testTrustStillRequiresAnAllowlistedNameAndASystemLocation() {
        let sshd = ListenSocket(pid: 3, processName: "sshd", port: 22, bindAddress: "*", isTCP: true)
        let fake = ListenSocket(pid: 4, processName: "remotepai", port: 3_722, bindAddress: "*", isTCP: true)
        XCTAssertFalse(SystemMonitor.isTrustedAppleListener(sshd, executablePath: "/usr/sbin/sshd"))
        XCTAssertFalse(SystemMonitor.isTrustedAppleListener(fake, executablePath: "/Users/someone/remotepairingd"))
        XCTAssertFalse(SystemMonitor.isTrustedAppleListener(fake, executablePath: nil))
    }

    func testPanelTrustsOnlyAllowlistedListenersRunningFromSystemPaths() async {
        let apple = ListenSocket(pid: 10, processName: "rapportd", port: 58002, bindAddress: "*", isTCP: true)
        let lookalike = ListenSocket(pid: 11, processName: "rapportd", port: 58003, bindAddress: "*", isTCP: true)
        let devServer = ListenSocket(pid: 12, processName: "node", port: 3000, bindAddress: "*", isTCP: true)
        let services = AppServicesModel(
            alertsPreferences: EnabledAlertsPreferenceStore(),
            notifications: GrantingNotificationService(),
            loginItems: InertLoginItemService()
        )
        let monitor = SystemMonitor(
            autoStart: false,
            initialAlertsEnabled: false,
            appServices: services,
            summaryCollector: {
                SummarySample(
                    cpu: .success(10),
                    memory: .success(MemorySnapshot(usedGB: 8, freeMB: 8_192, totalGB: 16)),
                    swap: .success(.empty),
                    network: .success(.empty),
                    sampledAt: Date(timeIntervalSince1970: 10)
                )
            },
            processCollector: { .success([]) },
            portsCollector: { .success([apple, lookalike, devServer]) },
            diskCollector: { .success(.empty) },
            alertIdentityReader: FixedPathIdentityReader(pathsByPID: [
                10: "/usr/libexec/rapportd",
                11: "/Users/someone/Downloads/rapportd",
                12: "/usr/local/bin/node"
            ])
        )

        monitor.panelDidOpen(at: .zero)
        await monitor.waitForIdle()

        XCTAssertEqual(monitor.panelModel.snapshot.trustedListenerKeys, [apple.endpointKey])
        XCTAssertEqual(monitor.panelModel.snapshot.listenerExecutablePaths[12], "/usr/local/bin/node")
        let ports = monitor.panelModel.snapshot.listenPorts.value ?? []
        let verdict = ExposureVerdict(
            ports,
            trusted: monitor.panelModel.snapshot.trustedListenerKeys,
            allowedSubjects: []
        )
        XCTAssertEqual(Set(verdict.needsLook.map(\.pid)), [11, 12])
        monitor.shutdown()
    }
}

/// Drives a SystemMonitor through a baseline ports scan and one update scan
/// with alert delivery active, then exposes the port alerts that fired.
@MainActor
private struct AlertHarness {
    let portAlerts: [MonitorAlert]

    init(
        pathsByPID: [Int32: String],
        baseline: [ListenSocket],
        update: [ListenSocket]
    ) async throws {
        let notifications = GrantingNotificationService()
        let services = AppServicesModel(
            alertsPreferences: EnabledAlertsPreferenceStore(),
            notifications: notifications,
            loginItems: InertLoginItemService()
        )
        await services.load()
        guard services.notificationState.deliveryActive else {
            throw XCTSkip("notification stub failed to activate delivery")
        }

        let ports = PortsResultQueue([.success(baseline), .success(update)])
        let monitor = SystemMonitor(
            autoStart: false,
            appServices: services,
            summaryCollector: {
                SummarySample(
                    cpu: .success(10),
                    memory: .success(MemorySnapshot(usedGB: 8, freeMB: 8_192, totalGB: 16)),
                    swap: .success(.empty),
                    network: .success(.empty),
                    sampledAt: Date(timeIntervalSince1970: 10)
                )
            },
            processCollector: { .success([]) },
            portsCollector: { await ports.next() },
            diskCollector: { .success(.empty) },
            alertIdentityReader: FixedPathIdentityReader(pathsByPID: pathsByPID)
        )

        monitor.panelDidOpen(at: .zero)
        await monitor.waitForIdle()
        monitor.tick(at: .seconds(15))
        await monitor.waitForIdle()

        portAlerts = monitor.emittedAlerts.filter {
            $0.title == AppResources.localized("New LAN-exposed port")
        }
    }
}

private actor PortsResultQueue {
    private var results: [Result<[ListenSocket], TelemetryError>]

    init(_ results: [Result<[ListenSocket], TelemetryError>]) {
        self.results = results
    }

    func next() -> Result<[ListenSocket], TelemetryError> {
        results.isEmpty ? .success([]) : results.removeFirst()
    }
}

private struct FixedPathIdentityReader: ProcessIdentityReading {
    let pathsByPID: [Int32: String]

    func readBSDInfo(for pid: Int32) -> ProcessBSDIdentitySnapshot? { nil }
    func readExecutablePath(for pid: Int32) -> String? { pathsByPID[pid] }
}

private final class EnabledAlertsPreferenceStore: AlertsPreferenceStoring {
    func storedAlertsDesired() -> Bool? { true }
    func storeAlertsDesired(_ desired: Bool) {}
}

@MainActor
private final class GrantingNotificationService: NotificationServicing {
    func currentSettings() async throws -> NotificationSettingsSnapshot {
        NotificationSettingsSnapshot(authorization: .authorized, alertSetting: .enabled)
    }

    func requestAuthorization() async throws {}
    func deliver(title: String, body: String) async throws {}
    func openSystemSettings() {}
}

@MainActor
private final class InertLoginItemService: LoginItemServicing {
    func currentStatus() async throws -> LoginItemState { .notRegistered }
    func register() async throws {}
    func unregister() async throws {}
    func openSystemSettings() {}
}
