import UserNotifications
import XCTest
@testable import SysBar

@MainActor
final class AppServicesTests: XCTestCase {
    func testInitializationDefaultsAlertsOffWithoutTouchingSystemServices() {
        let preferences = FakeAlertsPreferenceStore(value: nil)
        let notifications = FakeNotificationService()
        let loginItems = FakeLoginItemService()

        let model = AppServicesModel(
            alertsPreferences: preferences,
            notifications: notifications,
            loginItems: loginItems
        )

        XCTAssertFalse(model.notificationState.desired)
        XCTAssertEqual(notifications.settingsCalls, 0)
        XCTAssertEqual(notifications.requestCalls, 0)
        XCTAssertEqual(loginItems.statusCalls, 0)
    }

    func testAlertIntentPersistsAcrossModelRecreation() async {
        let preferences = FakeAlertsPreferenceStore(value: nil)
        let first = AppServicesModel(
            alertsPreferences: preferences,
            notifications: FakeNotificationService(settings: [
                .init(authorization: .denied, alertSetting: .disabled)
            ]),
            loginItems: FakeLoginItemService()
        )
        await first.setAlertsDesired(true)

        let recreated = AppServicesModel(
            alertsPreferences: preferences,
            notifications: FakeNotificationService(),
            loginItems: FakeLoginItemService()
        )

        XCTAssertTrue(recreated.notificationState.desired)
    }

    func testLoadReadsSystemStateWithoutRequestingNotificationPermission() async {
        let preferences = FakeAlertsPreferenceStore(value: true)
        let notifications = FakeNotificationService(settings: [
            .init(authorization: .notDetermined, alertSetting: .disabled)
        ])
        let loginItems = FakeLoginItemService(statuses: [.notRegistered])
        let model = AppServicesModel(
            alertsPreferences: preferences,
            notifications: notifications,
            loginItems: loginItems
        )

        await model.load()

        XCTAssertTrue(model.notificationState.desired)
        XCTAssertEqual(model.notificationState.authorization, .notDetermined)
        XCTAssertEqual(notifications.settingsCalls, 1)
        XCTAssertEqual(notifications.requestCalls, 0)
        XCTAssertEqual(model.loginItemState, .notRegistered)
    }

    func testEnablingPersistsThenRequestsOnceAndTrustsRefreshedSettings() async {
        let preferences = FakeAlertsPreferenceStore(value: false)
        let notifications = FakeNotificationService(settings: [
            .init(authorization: .notDetermined, alertSetting: .disabled),
            .init(authorization: .authorized, alertSetting: .enabled)
        ])
        let model = AppServicesModel(
            alertsPreferences: preferences,
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        await model.setAlertsDesired(true)

        XCTAssertEqual(preferences.valuesWritten, [true])
        XCTAssertEqual(notifications.settingsCalls, 2)
        XCTAssertEqual(notifications.requestCalls, 1)
        XCTAssertTrue(model.notificationState.deliveryActive)

        await model.setAlertsDesired(true)
        XCTAssertEqual(notifications.requestCalls, 1)
    }

    func testEnablingDoesNotRequestWhenAuthorizationWasAlreadyDecided() async {
        let notifications = FakeNotificationService(settings: [
            .init(authorization: .denied, alertSetting: .disabled)
        ])
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: false),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        await model.setAlertsDesired(true)

        XCTAssertEqual(notifications.requestCalls, 0)
        XCTAssertTrue(model.notificationState.requiresOpenSettings)
    }

    func testDisablingPersistsWithoutQueryingOrRequestingPermission() async {
        let preferences = FakeAlertsPreferenceStore(value: true)
        let notifications = FakeNotificationService()
        let model = AppServicesModel(
            alertsPreferences: preferences,
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        await model.setAlertsDesired(false)

        XCTAssertEqual(preferences.valuesWritten, [false])
        XCTAssertEqual(notifications.settingsCalls, 0)
        XCTAssertEqual(notifications.requestCalls, 0)
        XCTAssertFalse(model.notificationState.deliveryActive)
    }

    func testDisablingWhileSettingsReadIsPendingPreventsPermissionRequest() async throws {
        let pending = NotificationSettingsProbe()
        let notifications = FakeNotificationService()
        notifications.settingsHandler = { try await pending.read() }
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: false),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        let enabling = Task { await model.setAlertsDesired(true) }
        await pending.waitForCalls(1)
        await model.setAlertsDesired(false)
        try pending.resolve(1, with: .success(.init(
            authorization: .notDetermined, alertSetting: .disabled
        )))
        await enabling.value

        XCTAssertFalse(model.notificationState.desired)
        XCTAssertEqual(model.notificationState.authorization, .unknown)
        XCTAssertEqual(notifications.requestCalls, 0)
        XCTAssertEqual(notifications.settingsCalls, 1)
    }

    func testOlderNotificationSettingsReadCannotOverwriteNewerState() async throws {
        let pending = NotificationSettingsProbe()
        let notifications = FakeNotificationService()
        notifications.settingsHandler = { try await pending.read() }
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: true),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        let older = Task { await model.refreshNotifications() }
        await pending.waitForCalls(1)
        let newer = Task { await model.refreshNotifications() }
        await pending.waitForCalls(2)
        try pending.resolve(2, with: .success(.init(
            authorization: .authorized, alertSetting: .enabled
        )))
        await newer.value
        try pending.resolve(1, with: .success(.init(
            authorization: .denied, alertSetting: .disabled
        )))
        await older.value

        XCTAssertTrue(model.notificationState.deliveryActive)
        XCTAssertNil(model.notificationState.errorMessage)
    }

    func testOlderNotificationSettingsFailureCannotReplaceNewerSuccess() async throws {
        let pending = NotificationSettingsProbe()
        let notifications = FakeNotificationService()
        notifications.settingsHandler = { try await pending.read() }
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: true),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        let older = Task { await model.refreshNotifications() }
        await pending.waitForCalls(1)
        let newer = Task { await model.refreshNotifications() }
        await pending.waitForCalls(2)
        try pending.resolve(2, with: .success(.init(
            authorization: .authorized, alertSetting: .enabled
        )))
        await newer.value
        try pending.resolve(1, with: .failure(TestServiceError.delivery))
        await older.value

        XCTAssertTrue(model.notificationState.deliveryActive)
        XCTAssertNil(model.notificationState.errorMessage)
    }

    func testFailedPermissionRequestCanBeRetriedByAnotherExplicitOptIn() async {
        let notifications = FakeNotificationService(settings: [
            .init(authorization: .notDetermined, alertSetting: .disabled),
            .init(authorization: .notDetermined, alertSetting: .disabled),
            .init(authorization: .notDetermined, alertSetting: .disabled),
            .init(authorization: .authorized, alertSetting: .enabled)
        ])
        notifications.requestError = TestServiceError.permission
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: false),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        await model.setAlertsDesired(true)
        XCTAssertEqual(notifications.requestCalls, 1)
        XCTAssertEqual(model.notificationState.errorMessage, "Notification permission request failed")

        notifications.requestError = nil
        await model.setAlertsDesired(false)
        await model.setAlertsDesired(true)

        XCTAssertEqual(notifications.requestCalls, 2)
        XCTAssertTrue(model.notificationState.deliveryActive)
        XCTAssertNil(model.notificationState.errorMessage)
    }

    func testConcurrentOptInsShareAnInFlightPermissionRequest() async throws {
        let notifications = FakeNotificationService()
        var requestContinuation: CheckedContinuation<Void, Error>?
        var permissionGranted = false
        notifications.settingsHandler = {
            .init(
                authorization: permissionGranted ? .authorized : .notDetermined,
                alertSetting: permissionGranted ? .enabled : .disabled
            )
        }
        notifications.requestHandler = {
            try await withCheckedThrowingContinuation { requestContinuation = $0 }
        }
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: false),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        let first = Task { await model.setAlertsDesired(true) }
        for _ in 0..<1_000 where requestContinuation == nil { await Task.yield() }
        let second = Task { await model.setAlertsDesired(true) }
        for _ in 0..<1_000 where notifications.settingsCalls < 2 { await Task.yield() }
        XCTAssertEqual(notifications.settingsCalls, 2)
        XCTAssertEqual(notifications.requestCalls, 1)

        permissionGranted = true
        try XCTUnwrap(requestContinuation).resume()
        await first.value
        await second.value

        XCTAssertEqual(notifications.requestCalls, 1)
        XCTAssertTrue(model.notificationState.deliveryActive)
    }

    func testPermissionFailureAfterOptOutDoesNotRestoreErrorOrRefreshSettings() async throws {
        let notifications = FakeNotificationService(settings: [
            .init(authorization: .notDetermined, alertSetting: .disabled)
        ])
        var requestContinuation: CheckedContinuation<Void, Error>?
        notifications.requestHandler = {
            try await withCheckedThrowingContinuation { requestContinuation = $0 }
        }
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: false),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        let enabling = Task { await model.setAlertsDesired(true) }
        for _ in 0..<1_000 where requestContinuation == nil { await Task.yield() }
        await model.setAlertsDesired(false)
        try XCTUnwrap(requestContinuation).resume(throwing: TestServiceError.permission)
        await enabling.value

        XCTAssertFalse(model.notificationState.desired)
        XCTAssertNil(model.notificationState.errorMessage)
        XCTAssertEqual(notifications.settingsCalls, 1)
    }

    func testBackgroundRefreshDoesNotSwallowExplicitPermissionRequest() async throws {
        let pending = NotificationSettingsProbe()
        let notifications = FakeNotificationService()
        notifications.settingsHandler = { try await pending.read() }
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: false),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        let enabling = Task { await model.setAlertsDesired(true) }
        await pending.waitForCalls(1)
        let refreshing = Task { await model.refreshNotifications() }
        await pending.waitForCalls(2)
        try pending.resolve(1, with: .success(.init(
            authorization: .notDetermined, alertSetting: .disabled
        )))
        await pending.waitForCalls(3)
        XCTAssertEqual(notifications.requestCalls, 1)
        try pending.resolve(3, with: .success(.init(
            authorization: .authorized, alertSetting: .enabled
        )))
        await enabling.value
        try pending.resolve(2, with: .success(.init(
            authorization: .notDetermined, alertSetting: .disabled
        )))
        await refreshing.value

        XCTAssertTrue(model.notificationState.deliveryActive)
    }

    func testDeliveryPolicyRequiresIntentSupportedAuthorizationAndEnabledAlerts() {
        XCTAssertTrue(NotificationDeliveryPolicy.isActive(
            desired: true, authorization: .authorized, alertSetting: .enabled
        ))
        XCTAssertTrue(NotificationDeliveryPolicy.isActive(
            desired: true, authorization: .provisional, alertSetting: .enabled
        ))

        for authorization in NotificationAuthorizationState.allCases where authorization != .authorized && authorization != .provisional {
            XCTAssertFalse(NotificationDeliveryPolicy.isActive(
                desired: true, authorization: authorization, alertSetting: .enabled
            ))
        }
        XCTAssertFalse(NotificationDeliveryPolicy.isActive(
            desired: false, authorization: .authorized, alertSetting: .enabled
        ))
        XCTAssertFalse(NotificationDeliveryPolicy.isActive(
            desired: true, authorization: .authorized, alertSetting: .disabled
        ))
    }

    func testDeliveryIsSuppressedUntilSystemSettingsAllowIt() async {
        let notifications = FakeNotificationService()
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: true),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        let delivered = await model.deliver(title: "Memory critical", body: "Low memory")

        XCTAssertFalse(delivered)
        XCTAssertTrue(notifications.deliveries.isEmpty)
    }

    func testDeliveryFailureIsVisible() async {
        let notifications = FakeNotificationService(settings: [
            .init(authorization: .authorized, alertSetting: .enabled)
        ])
        notifications.deliveryError = TestServiceError.delivery
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: true),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )
        await model.refreshNotifications()

        let delivered = await model.deliver(title: "VPN disconnected", body: "Tunnel changed")

        XCTAssertFalse(delivered)
        XCTAssertEqual(model.notificationState.errorMessage, "Notification delivery failed")
    }

    func testAlertSettingDisabledIsExposedAsBlockedWithSettingsAction() async {
        let notifications = FakeNotificationService(settings: [
            .init(authorization: .authorized, alertSetting: .disabled)
        ])
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: true),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )

        await model.refreshNotifications()
        model.openNotificationSettings()

        XCTAssertFalse(model.notificationState.deliveryActive)
        XCTAssertTrue(model.notificationState.requiresOpenSettings)
        XCTAssertEqual(notifications.openSettingsCalls, 1)
    }

    func testLoginStatusRemainsDistinctAcrossAllPlatformStates() async {
        let loginItems = FakeLoginItemService(statuses: [
            .enabled, .notRegistered, .requiresApproval, .notFound, .unavailable
        ])
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: nil),
            notifications: FakeNotificationService(),
            loginItems: loginItems
        )

        for expected in LoginItemState.allCases {
            await model.refreshLoginItem()
            XCTAssertEqual(model.loginItemState, expected)
        }
    }

    func testLoginRegisterErrorIsSeparateAndActualStateStillRefreshes() async {
        let loginItems = FakeLoginItemService(statuses: [.notRegistered, .notRegistered])
        loginItems.registerError = TestServiceError.login
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: nil),
            notifications: FakeNotificationService(),
            loginItems: loginItems
        )
        await model.refreshLoginItem()

        await model.setLoginItemEnabled(true)

        XCTAssertEqual(loginItems.registerCalls, 1)
        XCTAssertEqual(loginItems.statusCalls, 2)
        XCTAssertEqual(model.loginItemState, .notRegistered)
        XCTAssertEqual(model.loginItemError, "Login item operation failed")
    }

    func testNeverRegisteredMainAppCanRegisterFromNotFoundStatus() async {
        let loginItems = FakeLoginItemService(statuses: [.notFound, .enabled])
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: nil),
            notifications: FakeNotificationService(),
            loginItems: loginItems
        )
        await model.refreshLoginItem()

        await model.setLoginItemEnabled(true)

        XCTAssertEqual(loginItems.registerCalls, 1)
        XCTAssertEqual(loginItems.statusCalls, 2)
        XCTAssertEqual(model.loginItemState, .enabled)
        XCTAssertNil(model.loginItemError)
    }

    func testRequiresApprovalOpensSettingsAndNeverRegisters() async {
        let loginItems = FakeLoginItemService(statuses: [.requiresApproval, .requiresApproval])
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: nil),
            notifications: FakeNotificationService(),
            loginItems: loginItems
        )
        await model.refreshLoginItem()

        await model.setLoginItemEnabled(true)

        XCTAssertEqual(loginItems.openSettingsCalls, 1)
        XCTAssertEqual(loginItems.registerCalls, 0)
        XCTAssertEqual(loginItems.statusCalls, 2)
        XCTAssertEqual(model.loginItemState, .requiresApproval)
    }

    func testDisablingRequiresApprovalAttemptsUnregisterInsteadOfOpeningSettings() async {
        let loginItems = FakeLoginItemService(statuses: [.requiresApproval, .notRegistered])
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: nil),
            notifications: FakeNotificationService(),
            loginItems: loginItems
        )
        await model.refreshLoginItem()

        await model.setLoginItemEnabled(false)

        XCTAssertEqual(loginItems.unregisterCalls, 1)
        XCTAssertEqual(loginItems.openSettingsCalls, 0)
        XCTAssertEqual(model.loginItemState, .notRegistered)
    }

    func testNotificationSettingsRouteEncodesBundleIdentifierAndIncludesFallback() {
        let urls = NotificationSettingsDestination.candidates(
            bundleIdentifier: "com.example.Sys Bar"
        )

        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(
            URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value,
            "com.example.Sys Bar"
        )
        XCTAssertTrue(urls[0].absoluteString.contains("com.example.Sys%20Bar"))
        XCTAssertEqual(urls[1].path, "/System/Applications/System Settings.app")
    }

    func testUnregisterAlwaysRefreshesActualState() async {
        let loginItems = FakeLoginItemService(statuses: [.enabled, .notRegistered])
        let model = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: nil),
            notifications: FakeNotificationService(),
            loginItems: loginItems
        )
        await model.refreshLoginItem()

        await model.setLoginItemEnabled(false)

        XCTAssertEqual(loginItems.unregisterCalls, 1)
        XCTAssertEqual(loginItems.statusCalls, 2)
        XCTAssertEqual(model.loginItemState, .notRegistered)
        XCTAssertNil(model.loginItemError)
    }

    func testMonitorEnablesHiddenAlertWorkOnlyAfterDeliveryBecomesActive() async {
        let notifications = FakeNotificationService(settings: [
            .init(authorization: .authorized, alertSetting: .enabled)
        ])
        let services = AppServicesModel(
            alertsPreferences: FakeAlertsPreferenceStore(value: false),
            notifications: notifications,
            loginItems: FakeLoginItemService()
        )
        let ports = ServiceInvocationCounter()
        let monitor = SystemMonitor(
            autoStart: false,
            appServices: services,
            summaryCollector: {
                SummarySample(
                    cpu: .success(10),
                    memory: .success(MemorySnapshot(usedGB: 8, freeMB: 8_192, totalGB: 16)),
                    swap: .success(.empty),
                    network: .success(.empty),
                    sampledAt: Date()
                )
            },
            processCollector: { .success([]) },
            portsCollector: {
                await ports.increment()
                return .success([])
            },
            diskCollector: { .success(.empty) }
        )

        monitor.refresh()
        await monitor.waitForIdle()
        let beforeEnabling = await ports.value()
        XCTAssertEqual(beforeEnabling, 0)

        await monitor.setAlertsDesired(true)
        await monitor.waitForIdle()

        XCTAssertTrue(services.notificationState.deliveryActive)
        let afterEnabling = await ports.value()
        XCTAssertEqual(afterEnabling, 1)
    }
}

@MainActor
private final class FakeAlertsPreferenceStore: AlertsPreferenceStoring {
    private(set) var valuesWritten: [Bool] = []
    private var value: Bool?

    init(value: Bool?) {
        self.value = value
    }

    func storedAlertsDesired() -> Bool? { value }

    func storeAlertsDesired(_ desired: Bool) {
        value = desired
        valuesWritten.append(desired)
    }
}

@MainActor
private final class FakeNotificationService: NotificationServicing {
    private var settings: [NotificationSettingsSnapshot]
    private(set) var settingsCalls = 0
    private(set) var requestCalls = 0
    private(set) var openSettingsCalls = 0
    private(set) var deliveries: [(String, String)] = []
    var settingsError: Error?
    var requestError: Error?
    var deliveryError: Error?
    var settingsHandler: (() async throws -> NotificationSettingsSnapshot)?
    var requestHandler: (() async throws -> Void)?

    init(settings: [NotificationSettingsSnapshot] = []) {
        self.settings = settings
    }

    func currentSettings() async throws -> NotificationSettingsSnapshot {
        settingsCalls += 1
        if let settingsHandler { return try await settingsHandler() }
        if let settingsError { throw settingsError }
        if settings.count > 1 { return settings.removeFirst() }
        return settings.first ?? .unknown
    }

    func requestAuthorization() async throws {
        requestCalls += 1
        if let requestHandler { return try await requestHandler() }
        if let requestError { throw requestError }
    }

    func deliver(title: String, body: String) async throws {
        if let deliveryError { throw deliveryError }
        deliveries.append((title, body))
    }

    func openSystemSettings() {
        openSettingsCalls += 1
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    private var statuses: [LoginItemState]
    private(set) var statusCalls = 0
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var openSettingsCalls = 0
    var statusError: Error?
    var registerError: Error?
    var unregisterError: Error?

    init(statuses: [LoginItemState] = []) {
        self.statuses = statuses
    }

    func currentStatus() async throws -> LoginItemState {
        statusCalls += 1
        if let statusError { throw statusError }
        if statuses.count > 1 { return statuses.removeFirst() }
        return statuses.first ?? .unavailable
    }

    func register() async throws {
        registerCalls += 1
        if let registerError { throw registerError }
    }

    func unregister() async throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
    }

    func openSystemSettings() {
        openSettingsCalls += 1
    }
}

private enum TestServiceError: LocalizedError {
    case delivery
    case login
    case permission

    var errorDescription: String? {
        switch self {
        case .delivery: "Notification delivery failed"
        case .login: "Login item operation failed"
        case .permission: "Notification permission request failed"
        }
    }
}

@MainActor
private final class NotificationSettingsProbe {
    private var calls = 0
    private var pending: [Int: CheckedContinuation<NotificationSettingsSnapshot, Error>] = [:]

    func read() async throws -> NotificationSettingsSnapshot {
        calls += 1
        let call = calls
        return try await withCheckedThrowingContinuation { pending[call] = $0 }
    }

    func waitForCalls(_ count: Int) async {
        for _ in 0..<1_000 where calls < count { await Task.yield() }
        XCTAssertGreaterThanOrEqual(calls, count)
    }

    func resolve(
        _ call: Int,
        with result: Result<NotificationSettingsSnapshot, Error>
    ) throws {
        try XCTUnwrap(pending.removeValue(forKey: call)).resume(with: result)
    }
}

private actor ServiceInvocationCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}

final class NotificationActionTests: XCTestCase {
    private func actions(_ titles: [String]) -> [NotificationPayload.Action] {
        titles.map { NotificationPayload.Action(id: $0.lowercased(), title: $0, isDestructive: false, opensApp: false) }
    }

    func testCategoriesAreStablePerButtonSetAndOnlyTheMostRecentFewAreKept() {
        let restart = NotificationCategoryRegistry.identifier(for: actions(["Restart ChatGPT"]))
        XCTAssertEqual(restart, NotificationCategoryRegistry.identifier(for: actions(["Restart ChatGPT"])))
        XCTAssertNotEqual(restart, NotificationCategoryRegistry.identifier(for: actions(["Restart Safari"])))

        var registry = NotificationCategoryRegistry()
        for index in 0..<6 {
            registry.register(NotificationCategoryRegistry.category(for: actions(["App \(index)"])))
        }
        XCTAssertEqual(registry.identifiers.count, NotificationCategoryRegistry.limit)
        XCTAssertEqual(registry.all.count, NotificationCategoryRegistry.limit)
        XCTAssertEqual(
            registry.identifiers.last,
            NotificationCategoryRegistry.identifier(for: actions(["App 5"]))
        )
    }

    @MainActor
    func testTheResponderRoutesTheTapToRevealAndAButtonToItsActionAndReplaysOneEarlyResponse() {
        XCTAssertEqual(
            NotificationResponder.response(notification: "n", action: UNNotificationDefaultActionIdentifier),
            .open(notification: "n")
        )
        XCTAssertNil(NotificationResponder.response(notification: "n", action: UNNotificationDismissActionIdentifier))

        let responder = NotificationResponder()
        responder.receive(.action(notification: "n", action: "restartApp:p1"))
        var received: [NotificationResponder.Response] = []
        responder.handler = { received.append($0) }
        XCTAssertEqual(received, [.action(notification: "n", action: "restartApp:p1")])
        responder.receive(.open(notification: "n"))
        XCTAssertEqual(received.count, 2)
    }

    func testNotificationIdentifiersRoundTripTheAttentionKey() {
        let key = AttentionKey(rule: .runawayProcess, subject: "/Applications/A|B.app/Contents/MacOS/A")
        XCTAssertEqual(AttentionNotification.key(from: AttentionNotification.identifier(for: key)), key)
        XCTAssertNil(AttentionNotification.key(from: "something else"))
    }
}
