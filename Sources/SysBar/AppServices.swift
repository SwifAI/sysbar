import AppKit
import Combine
import Foundation
import ServiceManagement
@preconcurrency import UserNotifications

enum NotificationAuthorizationState: String, CaseIterable, Equatable, Sendable {
    case unknown
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

enum NotificationAlertSettingState: String, Equatable, Sendable {
    case unknown
    case enabled
    case disabled
    case notSupported
}

struct NotificationSettingsSnapshot: Equatable, Sendable {
    let authorization: NotificationAuthorizationState
    let alertSetting: NotificationAlertSettingState

    static let unknown = NotificationSettingsSnapshot(
        authorization: .unknown,
        alertSetting: .unknown
    )
}

enum NotificationDeliveryPolicy {
    static func isActive(
        desired: Bool,
        authorization: NotificationAuthorizationState,
        alertSetting: NotificationAlertSettingState
    ) -> Bool {
        guard desired, alertSetting == .enabled else { return false }
        return authorization == .authorized || authorization == .provisional
    }
}

enum NotificationSettingsDestination {
    static func candidates(bundleIdentifier: String?) -> [URL] {
        var components = URLComponents(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        )
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            components?.queryItems = [URLQueryItem(name: "id", value: bundleIdentifier)]
        }

        var urls = components?.url.map { [$0] } ?? []
        urls.append(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        return urls
    }
}

struct NotificationServiceState: Equatable, Sendable {
    let desired: Bool
    let authorization: NotificationAuthorizationState
    let alertSetting: NotificationAlertSettingState
    let errorMessage: String?

    var deliveryActive: Bool {
        NotificationDeliveryPolicy.isActive(
            desired: desired,
            authorization: authorization,
            alertSetting: alertSetting
        )
    }

    var requiresOpenSettings: Bool {
        guard desired else { return false }
        return authorization == .denied
            || ((authorization == .authorized || authorization == .provisional)
                && alertSetting != .enabled)
    }

    func updating(
        desired: Bool? = nil,
        settings: NotificationSettingsSnapshot? = nil,
        errorMessage: String?? = nil
    ) -> NotificationServiceState {
        NotificationServiceState(
            desired: desired ?? self.desired,
            authorization: settings?.authorization ?? authorization,
            alertSetting: settings?.alertSetting ?? alertSetting,
            errorMessage: errorMessage ?? self.errorMessage
        )
    }
}

enum LoginItemState: String, CaseIterable, Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unavailable
}

@MainActor
protocol AlertsPreferenceStoring: AnyObject {
    func storedAlertsDesired() -> Bool?
    func storeAlertsDesired(_ desired: Bool)
}

/// A notification with optional action buttons. `identifier` is stable per
/// subject, so a later result notification replaces the first one.
struct NotificationPayload: Equatable, Sendable {
    struct Action: Equatable, Sendable {
        let id: String
        let title: String
        let isDestructive: Bool
        let opensApp: Bool
    }

    var identifier: String?
    let title: String
    let body: String
    var actions: [Action] = []
}

@MainActor
protocol NotificationServicing: AnyObject {
    func currentSettings() async throws -> NotificationSettingsSnapshot
    func requestAuthorization() async throws
    func deliver(title: String, body: String) async throws
    func deliver(_ payload: NotificationPayload) async throws
    func openSystemSettings()
}

extension NotificationServicing {
    /// Services without action support deliver the text alone.
    func deliver(_ payload: NotificationPayload) async throws {
        try await deliver(title: payload.title, body: payload.body)
    }
}

@MainActor
protocol LoginItemServicing: AnyObject {
    func currentStatus() async throws -> LoginItemState
    func register() async throws
    func unregister() async throws
    func openSystemSettings()
}

@MainActor
final class AppServicesModel: ObservableObject {
    private enum AuthorizationAttempt {
        case skipped
        case completed
        case failed(String)

        var errorMessage: String? {
            if case let .failed(message) = self { return message }
            return nil
        }
    }

    @Published private(set) var notificationState: NotificationServiceState
    @Published private(set) var loginItemState: LoginItemState = .unavailable
    @Published private(set) var loginItemError: String?

    private let alertsPreferences: any AlertsPreferenceStoring
    private let notifications: any NotificationServicing
    private let loginItems: any LoginItemServicing
    private var didRequestAuthorization = false
    private var authorizationRequestTask: Task<AuthorizationAttempt, Never>?
    private var notificationIntentGeneration: UInt64 = 0
    private var notificationSettingsGeneration: UInt64 = 0

    init(
        alertsPreferences: any AlertsPreferenceStoring,
        notifications: any NotificationServicing,
        loginItems: any LoginItemServicing
    ) {
        self.alertsPreferences = alertsPreferences
        self.notifications = notifications
        self.loginItems = loginItems
        self.notificationState = NotificationServiceState(
            desired: alertsPreferences.storedAlertsDesired() ?? false,
            authorization: .unknown,
            alertSetting: .unknown,
            errorMessage: nil
        )
    }

    static func live() -> AppServicesModel {
        let notificationService: any NotificationServicing = Bundle.main.bundleIdentifier == nil
            ? UnavailableNotificationService()
            : UserNotificationService()
        return AppServicesModel(
            alertsPreferences: UserDefaultsAlertsPreferenceStore(),
            notifications: notificationService,
            loginItems: MainAppLoginItemService()
        )
    }

    static func transient(alertsDesired: Bool) -> AppServicesModel {
        AppServicesModel(
            alertsPreferences: TransientAlertsPreferenceStore(value: alertsDesired),
            notifications: UnavailableNotificationService(),
            loginItems: UnavailableLoginItemService()
        )
    }

    func load() async {
        await refreshNotifications()
        await refreshLoginItem()
    }

    func refreshNotifications() async {
        _ = await readNotificationSettings()
    }

    func setAlertsDesired(_ desired: Bool) async {
        notificationIntentGeneration &+= 1
        let intentGeneration = notificationIntentGeneration
        alertsPreferences.storeAlertsDesired(desired)
        notificationState = notificationState.updating(
            desired: desired,
            errorMessage: .some(nil)
        )
        guard desired else { return }

        guard let current = await readNotificationSettings(),
              notificationIntentGeneration == intentGeneration,
              notificationState.desired,
              current.authorization == .notDetermined else { return }

        let requestError = await requestNotificationAuthorizationIfNeeded()
        guard notificationIntentGeneration == intentGeneration,
              notificationState.desired else { return }
        _ = await readNotificationSettings(preserving: requestError)
    }

    /// A permission sheet can outlive the opt-in that opened it. Share an
    /// in-flight request, but allow a later explicit opt-in to retry a failed
    /// system call instead of requiring an app restart.
    private func requestNotificationAuthorizationIfNeeded() async -> String? {
        if let authorizationRequestTask {
            return await authorizationRequestTask.value.errorMessage
        }
        guard !didRequestAuthorization else { return nil }

        let notifications = self.notifications
        let task = Task<AuthorizationAttempt, Never> {
            guard self.notificationState.desired else { return .skipped }
            do {
                try await notifications.requestAuthorization()
                return .completed
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        authorizationRequestTask = task
        let result = await task.value
        if case .completed = result { didRequestAuthorization = true }
        authorizationRequestTask = nil
        return result.errorMessage
    }

    /// Only the newest read for the current user intent may update the UI.
    /// Return the read result to its caller even if a background refresh has
    /// since started; a refresh must not swallow an explicit permission request.
    private func readNotificationSettings(
        preserving requestError: String? = nil
    ) async -> NotificationSettingsSnapshot? {
        notificationSettingsGeneration &+= 1
        let settingsGeneration = notificationSettingsGeneration
        let intentGeneration = notificationIntentGeneration
        do {
            let settings = try await notifications.currentSettings()
            if settingsGeneration == notificationSettingsGeneration,
               intentGeneration == notificationIntentGeneration {
                notificationState = notificationState.updating(
                    settings: settings,
                    errorMessage: .some(requestError)
                )
            }
            return settings
        } catch {
            if settingsGeneration == notificationSettingsGeneration,
               intentGeneration == notificationIntentGeneration {
                notificationState = notificationState.updating(
                    errorMessage: .some(requestError ?? error.localizedDescription)
                )
            }
            return nil
        }
    }

    @discardableResult
    func deliver(title: String, body: String) async -> Bool {
        await deliver(NotificationPayload(title: title, body: body))
    }

    @discardableResult
    func deliver(_ payload: NotificationPayload) async -> Bool {
        guard notificationState.deliveryActive else { return false }
        do {
            try await notifications.deliver(payload)
            notificationState = notificationState.updating(errorMessage: .some(nil))
            return true
        } catch {
            notificationState = notificationState.updating(
                errorMessage: .some(error.localizedDescription)
            )
            return false
        }
    }

    func openNotificationSettings() {
        notifications.openSystemSettings()
    }

    func refreshLoginItem() async {
        loginItemError = await readLoginItemStatus()
    }

    func setLoginItemEnabled(_ enabled: Bool) async {
        var actionError: String?
        do {
            if enabled, loginItemState == .requiresApproval {
                loginItems.openSystemSettings()
            } else if enabled,
                      loginItemState == .notRegistered || loginItemState == .notFound {
                try await loginItems.register()
            } else if !enabled,
                      loginItemState == .enabled || loginItemState == .requiresApproval {
                try await loginItems.unregister()
            }
        } catch {
            actionError = error.localizedDescription
        }

        let refreshError = await readLoginItemStatus()
        loginItemError = actionError ?? refreshError
    }

    func openLoginItemSettings() async {
        loginItems.openSystemSettings()
        await refreshLoginItem()
    }

    private func readLoginItemStatus() async -> String? {
        do {
            loginItemState = try await loginItems.currentStatus()
            return nil
        } catch {
            loginItemState = .unavailable
            return error.localizedDescription
        }
    }
}

@MainActor
private final class TransientAlertsPreferenceStore: AlertsPreferenceStoring {
    private var value: Bool

    init(value: Bool) {
        self.value = value
    }

    func storedAlertsDesired() -> Bool? { value }
    func storeAlertsDesired(_ desired: Bool) { value = desired }
}

@MainActor
private final class UnavailableNotificationService: NotificationServicing {
    func currentSettings() async throws -> NotificationSettingsSnapshot { .unknown }
    func requestAuthorization() async throws {}
    func deliver(title: String, body: String) async throws {}
    func openSystemSettings() {}
}

@MainActor
private final class UnavailableLoginItemService: LoginItemServicing {
    func currentStatus() async throws -> LoginItemState { .unavailable }
    func register() async throws {}
    func unregister() async throws {}
    func openSystemSettings() {}
}

@MainActor
private final class UserDefaultsAlertsPreferenceStore: AlertsPreferenceStoring {
    private static let key = "alertsDesired"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func storedAlertsDesired() -> Bool? {
        guard defaults.object(forKey: Self.key) != nil else { return nil }
        return defaults.bool(forKey: Self.key)
    }

    func storeAlertsDesired(_ desired: Bool) {
        defaults.set(desired, forKey: Self.key)
    }
}

@MainActor
private final class UserNotificationService: NotificationServicing {
    private let center: UNUserNotificationCenter
    private var categories = NotificationCategoryRegistry()

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func currentSettings() async throws -> NotificationSettingsSnapshot {
        let settings = await center.notificationSettings()
        return NotificationSettingsSnapshot(
            authorization: Self.authorization(settings.authorizationStatus),
            alertSetting: Self.alertSetting(settings.alertSetting)
        )
    }

    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func deliver(title: String, body: String) async throws {
        try await deliver(NotificationPayload(title: title, body: body))
    }

    func deliver(_ payload: NotificationPayload) async throws {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.threadIdentifier = "sysbar.attention"
        if !payload.actions.isEmpty {
            let category = NotificationCategoryRegistry.category(for: payload.actions)
            categories.register(category)
            center.setNotificationCategories(categories.all)
            // Let the registration land before the notification that uses it.
            _ = await center.notificationCategories()
            content.categoryIdentifier = category.identifier
        }
        let request = UNNotificationRequest(
            identifier: payload.identifier ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    func openSystemSettings() {
        for url in NotificationSettingsDestination.candidates(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) where NSWorkspace.shared.open(url) {
            return
        }
    }

    private static func authorization(
        _ status: UNAuthorizationStatus
    ) -> NotificationAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }

    private static func alertSetting(
        _ setting: UNNotificationSetting
    ) -> NotificationAlertSettingState {
        switch setting {
        case .enabled: .enabled
        case .disabled: .disabled
        case .notSupported: .notSupported
        @unknown default: .unknown
        }
    }
}

@MainActor
private final class MainAppLoginItemService: LoginItemServicing {
    func currentStatus() async throws -> LoginItemState {
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return LoginItemState.enabled
        case .notRegistered: return LoginItemState.notRegistered
        case .requiresApproval: return LoginItemState.requiresApproval
        case .notFound: return LoginItemState.notFound
        @unknown default: return LoginItemState.unavailable
        }
    }

    func register() async throws {
        try SMAppService.mainApp.register()
    }

    func unregister() async throws {
        try await SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Notification action buttons are named per item ("Restart ChatGPT"), so
/// each distinct set gets its own category. Only the most recent few are kept.
struct NotificationCategoryRegistry {
    static let limit = 4
    private(set) var identifiers: [String] = []
    private var categoriesByID: [String: UNNotificationCategory] = [:]

    var all: Set<UNNotificationCategory> { Set(identifiers.compactMap { categoriesByID[$0] }) }

    mutating func register(_ category: UNNotificationCategory) {
        identifiers.removeAll { $0 == category.identifier }
        identifiers.append(category.identifier)
        categoriesByID[category.identifier] = category
        while identifiers.count > Self.limit {
            categoriesByID[identifiers.removeFirst()] = nil
        }
    }

    static func identifier(for actions: [NotificationPayload.Action]) -> String {
        // FNV-1a over the ids and titles: stable across launches.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in actions.map({ "\($0.id)=\($0.title)" }).joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return "sysbar.actions." + String(hash, radix: 16)
    }

    static func category(for actions: [NotificationPayload.Action]) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: identifier(for: actions),
            actions: actions.map { action in
                var options: UNNotificationActionOptions = []
                if action.isDestructive { options.insert(.destructive) }
                if action.opensApp { options.insert(.foreground) }
                return UNNotificationAction(identifier: action.id, title: action.title, options: options)
            },
            intentIdentifiers: [],
            options: []
        )
    }
}

/// Routes taps on SysBar's notifications: the notification itself opens the
/// popover on that item, a button runs that action. A response that arrives
/// before the app finished launching is kept and replayed once.
@MainActor
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    enum Response: Equatable, Sendable {
        case open(notification: String)
        case action(notification: String, action: String)
    }

    var handler: ((Response) -> Void)? {
        didSet {
            guard let handler else { return }
            let queued = pending
            pending = []
            queued.forEach(handler)
        }
    }

    private var pending: [Response] = []

    func receive(_ response: Response) {
        guard let handler else {
            pending = Array((pending + [response]).suffix(1))
            return
        }
        handler(response)
    }

    static func response(notification: String, action: String) -> Response? {
        switch action {
        case UNNotificationDefaultActionIdentifier:
            return .open(notification: notification)
        case UNNotificationDismissActionIdentifier:
            return nil
        default:
            return .action(notification: notification, action: action)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let notification = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            if let value = Self.response(notification: notification, action: action) {
                self?.receive(value)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
