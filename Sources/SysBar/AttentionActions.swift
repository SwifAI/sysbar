import AppKit
import Foundation

/// The closed set of things SysBar can do about an attention item. The AI may
/// pick from what SysBar offers for that item; it can never invent an action,
/// and SysBar writes every button label itself.
enum AttentionActionID: String, Codable, CaseIterable, Sendable {
    case restartApp
    case quitApp
    case openApp
    case quitProcesses
    case openStorageSettings
    case openSharingSettings
    case allowListener
    /// SIGTERM to a command-line program listening on the LAN, only after a
    /// click-time re-scan proves the same process still owns the port (ADR-023).
    case stopListener
    case snooze15
    /// Escalation only, after a quit visibly failed. Never offered to the AI.
    case forceQuit
    /// Follow-up only: relaunch an app SysBar quit, by its bundle location.
    case reopenApp

    static let aiSelectable: [AttentionActionID] = [
        .restartApp, .quitApp, .openApp, .quitProcesses,
        .openStorageSettings, .openSharingSettings, .allowListener, .stopListener, .snooze15
    ]

    var isDestructive: Bool {
        switch self {
        case .restartApp, .quitApp, .quitProcesses, .stopListener, .forceQuit: return true
        case .openApp, .openStorageSettings, .openSharingSettings, .allowListener, .snooze15, .reopenApp: return false
        }
    }

    /// Safe to run from a notification button: no confirmation, no context needed.
    var isNotificationSafe: Bool {
        switch self {
        case .restartApp, .quitApp, .openApp, .openStorageSettings, .openSharingSettings, .snooze15: return true
        case .quitProcesses, .allowListener, .stopListener, .forceQuit, .reopenApp: return false
        }
    }
}

/// A running app, addressed by its bundle location (bundle identifiers lie:
/// ChatGPT.app is `com.openai.codex`).
struct AppRef: Hashable, Sendable {
    let bundlePath: String
    let name: String
    let pid: Int32
    let executablePath: String?
    let bundleIdentifier: String?
    let isRegular: Bool
    let isFrontmost: Bool
}

enum SubjectKind: Equatable, Sendable {
    case app(AppRef)
    case helperOf(AppRef)
    case commandLine
    case bundledTool
    case system
}

enum SubjectResolver {
    private static let protectedPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
    /// The one part of `/usr` SIP leaves writable: the nodejs.org installer and
    /// Intel Homebrew put the user's programs here, like `/opt/homebrew`.
    private static let ownerWritablePrefixes = ["/usr/local/"]

    /// Paths SysBar never offers a destructive action for (macOS's own
    /// programs). A `..` component could climb out of `/usr/local`, so a
    /// path that has one is protected rather than reasoned about.
    static func isProtected(_ path: String) -> Bool {
        if path.split(separator: "/").contains("..") { return true }
        return protectedPrefixes.contains(where: path.hasPrefix)
            && !ownerWritablePrefixes.contains(where: path.hasPrefix)
    }

    /// A helper such as "Codex (Renderer)" belongs to the outermost running
    /// `.app` that contains it, so the action is "Restart ChatGPT", never
    /// "kill a renderer". Matched by bundle path, never by PID or identifier.
    static func kind(executablePath: String?, ownPath: String?, apps: [AppRef]) -> SubjectKind {
        guard let path = executablePath, !path.isEmpty else { return .system }
        if path == ownPath || isProtected(path) { return .system }
        guard let bundle = ProcessIconPath.bundlePath(containing: path) else { return .commandLine }
        let standardized = URL(fileURLWithPath: bundle).standardizedFileURL.path
        guard let app = apps.first(where: { $0.bundlePath == standardized }) else { return .bundledTool }
        if app.executablePath == path { return .app(app) }
        // Only code the app runs as part of itself lives in a bundle's MacOS
        // or Helpers folder (helper apps, XPC services, renderers). Tools that
        // merely ship inside it, like Xcode's swift-build or a bundled CLI,
        // are run by someone else: restarting the app would not stop them.
        return isHelperLocation(path) ? .helperOf(app) : .bundledTool
    }

    static func isHelperLocation(_ path: String) -> Bool {
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return folder == "MacOS" || folder == "Helpers"
    }
}

enum ActionSubject: Hashable, Sendable {
    case app(AppRef)
    /// Re-resolved by executable path in the live snapshot at click time.
    case group(path: String?, name: String, count: Int)
    case listener(name: String, isTCP: Bool, port: UInt16)
    /// The process behind an R6 listener as the last scan saw it. Never
    /// signaled as-is: identity and port ownership are proved again on click.
    case listenerProcess(ListenerStopTarget)
    case none
}

/// What the last ports scan said about a listener's owner: its PID, lsof's
/// name for it, the executable path resolved after that scan, and the exact
/// endpoint. A hint for the click, never a license to signal (ADR-023).
struct ListenerStopTarget: Hashable, Sendable {
    let pid: Int32
    let processName: String
    let executablePath: String
    let endpoint: ListenerEndpointKey

    init(port: ListenSocket, executablePath: String) {
        pid = port.pid
        processName = port.processName
        self.executablePath = executablePath
        endpoint = port.endpointKey
    }

    var address: String { PortDisplayText.address(bindAddress: endpoint.bindAddress, port: endpoint.port) }
}

/// What a click-time re-scan proved about who owns a listener's endpoint.
enum ListenerOwnership: Equatable, Sendable {
    /// The PID, with the start time and path read on the click, still owns
    /// exactly that endpoint.
    case confirmed
    /// Nothing listens on the endpoint any more.
    case closed
    /// A different process owns the endpoint now.
    case otherOwner
    /// The PID is still on the endpoint but could not be proved to be the
    /// same process instance (recycled, exiting, or renamed).
    case changed
    /// The scan failed, so nothing could be proved.
    case unverified

    /// Decides from one bracketed scan (`PortsAPI.fetchResult(runner:
    /// expectedIdentities:postValidationReader:)`), which attaches an
    /// identity only when the PID re-resolved after lsof to `expected`.
    static func evaluate(
        _ scan: Result<[ListenSocket], TelemetryError>,
        target: ListenerStopTarget,
        expected: ProcessIdentity
    ) -> ListenerOwnership {
        guard case let .success(sockets) = scan else { return .unverified }
        let onEndpoint = sockets.filter {
            $0.bindAddress == target.endpoint.bindAddress
                && $0.port == target.endpoint.port
                && $0.endpointKey.transport == target.endpoint.transport
        }
        guard !onEndpoint.isEmpty else { return .closed }
        guard let owned = onEndpoint.first(where: { $0.endpointKey == target.endpoint }) else { return .otherOwner }
        guard expected.pid == target.pid,
              expected.executablePath == target.executablePath,
              owned.processIdentity == expected,
              owned.processName == target.processName else { return .changed }
        return .confirmed
    }
}

/// One (action, subject) pair SysBar can execute right now.
struct AllowedAction: Hashable, Sendable, Identifiable {
    let action: AttentionActionID
    let ref: String?
    let subject: ActionSubject
    let target: String
    let confirms: Bool

    var id: String { "\(action.rawValue):\(ref ?? "-")" }
}

struct ActionPick: Codable, Equatable, Sendable {
    let id: String
    let subjectRef: String?
    let reason: String
}

enum ActionCatalog {
    static let maximumEntries = 40

    /// Everything SysBar could do for this item. This list, and only this
    /// list, is what the AI may choose from.
    static func allowed(
        rule: AttentionRule,
        groups: [(ref: String, group: ProcessGroup)],
        apps: [(ref: String, app: AppRef)],
        listeners: [(ref: String, port: ListenSocket, path: String?)],
        triggerListenerRef: String?,
        runningApps: [AppRef],
        ownPath: String?
    ) -> [AllowedAction] {
        var result: [AllowedAction] = []
        var seen = Set<String>()

        func add(_ entry: AllowedAction, dedupeKey: String) {
            guard result.count < maximumEntries, seen.insert(dedupeKey).inserted else { return }
            result.append(entry)
        }

        func addAppActions(ref: String, app: AppRef) {
            for action in [AttentionActionID.restartApp, .quitApp, .openApp] {
                add(
                    AllowedAction(action: action, ref: ref, subject: .app(app), target: app.name, confirms: false),
                    dedupeKey: "\(action.rawValue)|\(app.bundlePath)"
                )
            }
        }

        for (ref, group) in groups {
            switch SubjectResolver.kind(executablePath: group.executablePath, ownPath: ownPath, apps: runningApps) {
            case let .app(app), let .helperOf(app):
                addAppActions(ref: ref, app: app)
            case .commandLine, .bundledTool, .system:
                break
            }
            if BriefEvidence.isQuittable(group, ownPath: ownPath) {
                add(
                    AllowedAction(
                        action: .quitProcesses,
                        ref: ref,
                        subject: .group(path: group.executablePath, name: group.name, count: group.count),
                        target: group.name,
                        confirms: group.count > 1
                    ),
                    dedupeKey: "quitProcesses|\(group.executablePath ?? group.name)"
                )
            }
        }
        for (ref, app) in apps {
            addAppActions(ref: ref, app: app)
        }
        for (ref, _, path) in listeners {
            switch SubjectResolver.kind(executablePath: path, ownPath: ownPath, apps: runningApps) {
            case let .app(app), let .helperOf(app): addAppActions(ref: ref, app: app)
            default: break
            }
        }

        switch rule {
        case .disk:
            add(
                AllowedAction(action: .openStorageSettings, ref: nil, subject: .none, target: "System Settings", confirms: false),
                dedupeKey: "openStorageSettings"
            )
        case .newListener:
            if let ref = triggerListenerRef, let entry = listeners.first(where: { $0.ref == ref }) {
                add(
                    AllowedAction(
                        action: .allowListener,
                        ref: ref,
                        subject: .listener(name: entry.port.processName, isTCP: entry.port.isTCP, port: entry.port.port),
                        target: entry.port.processName,
                        confirms: false
                    ),
                    dedupeKey: "allowListener|\(ref)"
                )
                if let path = entry.path, SubjectResolver.isProtected(path) {
                    add(
                        AllowedAction(action: .openSharingSettings, ref: nil, subject: .none, target: "System Settings", confirms: false),
                        dedupeKey: "openSharingSettings"
                    )
                }
                // A program outside any running app has no Apple-event Quit;
                // Stop is its remedy, always confirmed and re-proved on click.
                if let path = entry.path {
                    switch SubjectResolver.kind(executablePath: path, ownPath: ownPath, apps: runningApps) {
                    case .commandLine, .bundledTool:
                        add(
                            AllowedAction(
                                action: .stopListener,
                                ref: ref,
                                subject: .listenerProcess(ListenerStopTarget(port: entry.port, executablePath: path)),
                                target: entry.port.processName,
                                confirms: true
                            ),
                            dedupeKey: "stopListener|\(ref)"
                        )
                    case .app, .helperOf, .system:
                        break
                    }
                }
            }
        case .runawayProcess, .hostCPU, .memory, .swapGrowth:
            break
        }
        // Waiting is always a legitimate choice.
        result.append(AllowedAction(action: .snooze15, ref: nil, subject: .none, target: "", confirms: false))
        return result
    }
}

enum FooterRoute: Equatable, Sendable {
    case topCPU
    case topMemory
    case network
}

struct PlannedAction: Equatable, Identifiable, Sendable {
    let allowed: AllowedAction
    /// The AI's one-sentence reason, or SysBar's own caption.
    let reason: String

    var id: String { allowed.id }
}

struct ActionPlan: Equatable, Sendable {
    var buttons: [PlannedAction]
    var route: FooterRoute?
    var droppedPicks: Int
    /// "Remind me in 15 min" as a footer link when it isn't already a button.
    var offersSnoozeLink: Bool
}

enum ActionPlanner {
    /// Turns the AI's picks into at most two buttons SysBar can execute:
    /// unknown or mismatched picks are dropped (the brief is kept), at most one
    /// destructive button, nothing destructive for "expected", the gentle
    /// option first for "unsure", and per-rule defaults so every attention card
    /// has a real button even with no AI at all.
    static func plan(
        picks: [ActionPick],
        verdict: AttentionBrief.Verdict?,
        rule: AttentionRule,
        triggerRef: String?,
        topCPURefs: [String],
        topMemoryRefs: [String],
        allowed: [AllowedAction]
    ) -> ActionPlan {
        var chosen: [PlannedAction] = []
        var dropped = 0
        for pick in picks.prefix(4) {
            guard chosen.count < 2,
                  let action = AttentionActionID(rawValue: pick.id),
                  AttentionActionID.aiSelectable.contains(action),
                  let entry = allowed.first(where: { $0.action == action && $0.ref == pick.subjectRef }),
                  !chosen.contains(where: { $0.allowed == entry }),
                  !(action.isDestructive && chosen.contains(where: { $0.allowed.action.isDestructive })) else {
                dropped += 1
                continue
            }
            let reason = pick.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            chosen.append(PlannedAction(allowed: entry, reason: reason.isEmpty ? ActionLabel.caption(entry) : reason))
        }
        dropped += max(0, picks.count - 4)

        if verdict == .expected {
            chosen.removeAll { $0.allowed.action.isDestructive }
            // An expected listener can still be allowed so it stops being flagged.
            if rule == .newListener, !chosen.contains(where: { $0.allowed.action == .allowListener }),
               let allow = allowed.first(where: { $0.action == .allowListener && $0.ref == triggerRef }) {
                chosen.append(PlannedAction(allowed: allow, reason: ActionLabel.caption(allow)))
            }
        } else if verdict == .unsure {
            chosen = chosen.filter { !$0.allowed.action.isDestructive } + chosen.filter { $0.allowed.action.isDestructive }
        }

        if chosen.isEmpty, verdict != .expected {
            chosen = defaults(rule: rule, triggerRef: triggerRef, topCPURefs: topCPURefs, topMemoryRefs: topMemoryRefs, allowed: allowed)
                .map { PlannedAction(allowed: $0, reason: ActionLabel.caption($0)) }
        }
        if verdict != .expected, chosen.count == 1, chosen[0].allowed.action != .snooze15,
           let snooze = allowed.first(where: { $0.action == .snooze15 }) {
            chosen.append(PlannedAction(allowed: snooze, reason: ActionLabel.caption(snooze)))
        }

        let route: FooterRoute?
        switch rule {
        case .runawayProcess, .hostCPU: route = .topCPU
        case .memory, .swapGrowth: route = .topMemory
        case .newListener: route = .network
        case .disk: route = nil
        }
        return ActionPlan(
            buttons: Array(chosen.prefix(2)),
            route: route,
            droppedPicks: dropped,
            offersSnoozeLink: !chosen.contains { $0.allowed.action == .snooze15 }
        )
    }

    static func defaults(
        rule: AttentionRule,
        triggerRef: String?,
        topCPURefs: [String],
        topMemoryRefs: [String],
        allowed: [AllowedAction]
    ) -> [AllowedAction] {
        func entry(_ action: AttentionActionID, _ ref: String?) -> AllowedAction? {
            allowed.first { $0.action == action && $0.ref == ref }
        }
        func forGroup(_ ref: String?) -> [AllowedAction] {
            if let restart = entry(.restartApp, ref) {
                return [restart, entry(.openApp, ref)].compactMap { $0 }
            }
            return [entry(.quitProcesses, ref)].compactMap { $0 }
        }
        var result: [AllowedAction]
        switch rule {
        case .runawayProcess:
            result = forGroup(triggerRef)
        case .hostCPU:
            let ref = topCPURefs.first { entry(.restartApp, $0) != nil || entry(.quitProcesses, $0) != nil }
            result = forGroup(ref)
        case .memory, .swapGrowth:
            let ref = topMemoryRefs.first { entry(.restartApp, $0) != nil }
            result = [entry(.restartApp, ref)].compactMap { $0 }
        case .disk:
            result = [entry(.openStorageSettings, nil)].compactMap { $0 }
        case .newListener:
            if let quit = entry(.quitApp, triggerRef) {
                result = [quit, entry(.allowListener, triggerRef)].compactMap { $0 }
            } else if let sharing = entry(.openSharingSettings, nil) {
                result = [sharing, entry(.allowListener, triggerRef)].compactMap { $0 }
            } else if let stop = entry(.stopListener, triggerRef) {
                result = [stop, entry(.allowListener, triggerRef)].compactMap { $0 }
            } else {
                result = [entry(.allowListener, triggerRef)].compactMap { $0 }
            }
        }
        if result.isEmpty, let snooze = entry(.snooze15, nil) { result = [snooze] }
        return result
    }
}

enum ActionLabel {
    /// Button titles are catalog strings: a process that names itself cleverly
    /// can never relabel a button.
    static func title(_ action: AllowedAction) -> String {
        switch action.action {
        case .restartApp:
            return AppResources.formatted("action.restartApp", fallback: "Restart %@", action.target)
        case .quitApp:
            return AppResources.formatted("action.quitApp", fallback: "Quit %@", action.target)
        case .openApp:
            return AppResources.formatted("action.openApp", fallback: "Open %@", action.target)
        case .quitProcesses:
            if case let .group(_, name, count) = action.subject, count > 1 {
                return AppResources.formatted("action.quitProcesses.many", fallback: "Quit %1$@ (%2$@ processes)…", name, count.formatted())
            }
            return AppResources.formatted("action.quitApp", fallback: "Quit %@", action.target)
        case .forceQuit:
            return AppResources.formatted("action.forceQuit", fallback: "Force Quit %@…", action.target)
        case .reopenApp:
            return AppResources.formatted("action.reopen", fallback: "Reopen %@", action.target)
        case .openStorageSettings:
            return AppResources.localized("action.openStorageSettings", fallback: "Open Storage Settings")
        case .openSharingSettings:
            return AppResources.localized("action.openSharingSettings", fallback: "Open Sharing Settings")
        case .allowListener:
            if case let .listener(name, _, port) = action.subject {
                return AppResources.formatted("action.allowListener", fallback: "Allow %1$@ on %2$@", name, String(port))
            }
            return AppResources.formatted("action.allowListener", fallback: "Allow %1$@ on %2$@", action.target, "")
        case .stopListener:
            return AppResources.formatted("action.stopListener", fallback: "Stop %@…", action.target)
        case .snooze15:
            return AppResources.localized("action.snooze15", fallback: "Remind me in 15 min")
        }
    }

    static func caption(_ action: AllowedAction) -> String {
        switch action.action {
        case .restartApp:
            return AppResources.formatted("action.caption.restartApp", fallback: "Restart quits %@ and reopens it; it may ask to save first.", action.target)
        case .quitApp:
            return AppResources.formatted("action.caption.quitApp", fallback: "Quits %@ normally; it may ask to save first.", action.target)
        case .openApp:
            return AppResources.formatted("action.caption.openApp", fallback: "Brings %@ forward so you can check it.", action.target)
        case .quitProcesses:
            return AppResources.localized("action.caption.quitProcesses", fallback: "Sends Quit to the process; unsaved work in it is lost.")
        case .forceQuit:
            return AppResources.localized("action.caption.forceQuit", fallback: "Ends it immediately; unsaved work is lost.")
        case .reopenApp:
            return AppResources.formatted("action.caption.reopen", fallback: "Opens %@ again.", action.target)
        case .openStorageSettings:
            return AppResources.localized("action.caption.openStorageSettings", fallback: "macOS shows what is using space and what can be removed.")
        case .openSharingSettings:
            return AppResources.localized("action.caption.openSharingSettings", fallback: "Turn off sharing services you don't use.")
        case .allowListener:
            return AppResources.localized("action.caption.allowListener", fallback: "SysBar stops flagging this port; it still shows in Network.")
        case .stopListener:
            return AppResources.formatted("action.caption.stopListener", fallback: "Asks %@ to quit once SysBar re-checks it still owns this port.", action.target)
        case .snooze15:
            return AppResources.localized("action.caption.snooze15", fallback: "SysBar asks again in 15 minutes if it's still happening.")
        }
    }
}

// MARK: - The two system boundaries the actions cross

@MainActor
protocol RunningAppControlling: AnyObject {
    func apps() -> [AppRef]
    func isRunning(_ app: AppRef) -> Bool
    func terminate(_ app: AppRef) -> Bool
    func forceTerminate(_ app: AppRef) -> Bool
    func activate(_ app: AppRef) -> Bool
    func open(bundlePath: String) async -> Bool
}

/// Apps through `NSRunningApplication` (Apple-event Quit, like ⌘Q), matched
/// by bundle location. Never a PID-only signal.
@MainActor
final class WorkspaceAppController: RunningAppControlling {
    private var ownBundlePath: String { Bundle.main.bundleURL.standardizedFileURL.path }

    func apps() -> [AppRef] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let url = app.bundleURL, app.activationPolicy != .prohibited else { return nil }
            let path = url.standardizedFileURL.path
            guard !SubjectResolver.isProtected(path), path != ownBundlePath else { return nil }
            return AppRef(
                bundlePath: path,
                name: app.localizedName ?? (url.lastPathComponent as NSString).deletingPathExtension,
                pid: app.processIdentifier,
                executablePath: app.executableURL?.standardizedFileURL.path,
                bundleIdentifier: app.bundleIdentifier,
                isRegular: app.activationPolicy == .regular,
                isFrontmost: app.processIdentifier == frontmost
            )
        }
    }

    private func running(_ app: AppRef) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL.path == app.bundlePath && !$0.isTerminated
        }
    }

    func isRunning(_ app: AppRef) -> Bool { !running(app).isEmpty }

    func terminate(_ app: AppRef) -> Bool {
        let instances = running(app)
        guard !instances.isEmpty else { return false }
        return instances.map { $0.terminate() }.contains(true)
    }

    func forceTerminate(_ app: AppRef) -> Bool {
        let instances = running(app)
        guard !instances.isEmpty else { return false }
        return instances.map { $0.forceTerminate() }.contains(true)
    }

    func activate(_ app: AppRef) -> Bool {
        guard let instance = running(app).first else { return false }
        return instance.activate(options: [.activateIgnoringOtherApps])
    }

    func open(bundlePath: String) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bundlePath), configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}

@MainActor
protocol SettingsOpening: AnyObject {
    func open(_ action: AttentionActionID) -> Bool
}

@MainActor
final class WorkspaceSettingsOpener: SettingsOpening {
    static func url(for action: AttentionActionID) -> URL? {
        switch action {
        case .openStorageSettings: return URL(string: "x-apple.systempreferences:com.apple.settings.Storage")
        case .openSharingSettings: return URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")
        default: return nil
        }
    }

    func open(_ action: AttentionActionID) -> Bool {
        if let url = Self.url(for: action), NSWorkspace.shared.open(url) { return true }
        return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

// MARK: - Verification

/// SysBar's own numbers for an item, read before an action and while it
/// checks the result. Only the fields the item's rule needs are filled.
struct VerificationReading: Equatable, Sendable {
    var subjectCPU: Double?
    var hostCPU: Double?
    var availableGB: Double?
    var totalGB: Double?
    var swapUsedMB: Double?
    var diskFreeGB: Double?
    var listenerOpen: Bool?
}

enum VerificationOutcome: Equatable, Sendable {
    case pending
    case done
    case notBetter
}

/// Decides, from SysBar's own samples, whether an action fixed the item.
/// Nothing is called fixed in the first ten seconds: a restarted app needs
/// a moment before its helpers show what they will do.
enum ActionVerification {
    static let earliestVerdict: TimeInterval = 10
    static let hostCPUDone = AttentionTracker.hostCPUClearPercent
    static let hostCPUStill = 60.0
    static let memoryDoneFraction = 0.20
    static let swapSettledMB = AttentionTracker.swapQuietGrowthMB
    static let diskSettledGB = 1.0

    static func limit(for rule: AttentionRule) -> TimeInterval {
        switch rule {
        case .runawayProcess, .hostCPU, .newListener: return 60
        case .memory, .swapGrowth, .disk: return 120
        }
    }

    /// Seconds between checks: a first look at +3 s, the verdict from +10 s.
    static func steps(for rule: AttentionRule) -> [TimeInterval] {
        var steps: [TimeInterval] = [3, 7]
        var total: TimeInterval = 10
        while total < limit(for: rule) {
            steps.append(10)
            total += 10
        }
        return steps
    }

    /// Whether the slow collectors (ports, disk) must be re-run to check.
    static func needsSlowSample(_ rule: AttentionRule) -> Bool {
        rule == .disk || rule == .newListener
    }

    static func outcome(
        rule: AttentionRule,
        before: VerificationReading,
        after: VerificationReading,
        elapsed: TimeInterval
    ) -> VerificationOutcome {
        guard elapsed >= earliestVerdict else { return .pending }
        let expired = elapsed >= limit(for: rule)
        switch rule {
        case .runawayProcess:
            guard let cpu = after.subjectCPU, cpu >= AttentionTracker.runawayFloorPercent else { return .done }
            if cpu >= AttentionTracker.runawayCPUPercent { return .notBetter }
            return expired ? .notBetter : .pending
        case .hostCPU:
            guard let cpu = after.hostCPU else { return expired ? .notBetter : .pending }
            if cpu < hostCPUDone { return .done }
            if cpu >= hostCPUStill { return .notBetter }
            return expired ? .notBetter : .pending
        case .memory:
            if let available = after.availableGB, let total = after.totalGB, total > 0,
               available / total >= memoryDoneFraction {
                return .done
            }
            return expired ? .notBetter : .pending
        case .swapGrowth:
            guard let start = before.swapUsedMB, let now = after.swapUsedMB else {
                return expired ? .notBetter : .pending
            }
            if now < start - swapSettledMB { return .done }
            guard expired else { return .pending }
            return now - start < swapSettledMB ? .done : .notBetter
        case .disk:
            guard expired else { return .pending }
            guard let start = before.diskFreeGB, let now = after.diskFreeGB else { return .notBetter }
            return now >= start - diskSettledGB ? .done : .notBetter
        case .newListener:
            if after.listenerOpen == false { return .done }
            return expired ? .notBetter : .pending
        }
    }
}

/// The result line under the buttons, in SysBar's numbers.
enum ActionResultText {
    static func done(_ item: AttentionItem, after: VerificationReading) -> String {
        let detail: String
        switch item.rule {
        case .runawayProcess:
            if let cpu = after.subjectCPU {
                detail = AppResources.formatted(
                    "action.result.done.cpu", fallback: "%1$@ back to %2$@",
                    item.subjectName, MetricFormat.percent(cpu.rounded())
                )
            } else {
                detail = AppResources.formatted("action.result.done.calm", fallback: "%@ is back to normal", item.subjectName)
            }
        case .hostCPU:
            detail = AppResources.formatted(
                "action.result.done.hostCPU", fallback: "CPU back to %@",
                MetricFormat.percent((after.hostCPU ?? 0).rounded())
            )
        case .memory:
            detail = AppResources.formatted(
                "action.result.done.memory", fallback: "%@ available",
                AttentionFormat.gigabytes(after.availableGB ?? 0)
            )
        case .swapGrowth:
            detail = AppResources.localized("action.result.done.swap", fallback: "swap stopped growing")
        case .disk:
            detail = AppResources.formatted(
                "action.result.done.disk", fallback: "no longer dropping · %@ free",
                AttentionFormat.gigabytes(after.diskFreeGB ?? 0)
            )
        case .newListener:
            detail = AppResources.formatted("action.result.done.listener", fallback: "port %@ closed", portText(item))
        }
        return AppResources.formatted("action.result.done", fallback: "Done · %@", detail)
    }

    static func notBetter(_ item: AttentionItem, after: VerificationReading, elapsed: TimeInterval) -> String {
        let seconds = Duration.seconds(Int(elapsed)).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
        switch item.rule {
        case .runawayProcess:
            return AppResources.formatted(
                "action.result.still.cpu", fallback: "Still at %1$@ after %2$@",
                MetricFormat.percent((after.subjectCPU ?? 0).rounded()), seconds
            )
        case .hostCPU:
            return AppResources.formatted(
                "action.result.still.cpu", fallback: "Still at %1$@ after %2$@",
                MetricFormat.percent((after.hostCPU ?? 0).rounded()), seconds
            )
        case .memory:
            return AppResources.formatted(
                "action.result.still.memory", fallback: "Still only %@ available",
                AttentionFormat.gigabytes(after.availableGB ?? 0)
            )
        case .swapGrowth:
            return AppResources.localized("action.result.still.swap", fallback: "Swap is still growing")
        case .disk:
            return AppResources.formatted(
                "action.result.still.disk", fallback: "Still dropping · %@ free",
                AttentionFormat.gigabytes(after.diskFreeGB ?? 0)
            )
        case .newListener:
            return AppResources.formatted("action.result.still.listener", fallback: "Port %@ is still open", portText(item))
        }
    }

    /// The live value while checking: "Checking · 72%".
    static func progress(_ item: AttentionItem, after: VerificationReading) -> String {
        let value: String?
        switch item.rule {
        case .runawayProcess: value = after.subjectCPU.map { MetricFormat.percent($0.rounded()) }
        case .hostCPU: value = after.hostCPU.map { MetricFormat.percent($0.rounded()) }
        case .memory: value = after.availableGB.map { AppResources.formatted("action.result.done.memory", fallback: "%@ available", AttentionFormat.gigabytes($0)) }
        case .swapGrowth: value = after.swapUsedMB.map { MetricFormat.memory(megabytes: Int($0)) }
        case .disk: value = after.diskFreeGB.map { AppResources.formatted("action.value.free", fallback: "%@ free", AttentionFormat.gigabytes($0)) }
        case .newListener: value = nil
        }
        guard let value else { return AppResources.localized("action.progress.checking", fallback: "Checking…") }
        return AppResources.formatted("action.progress.checkingValue", fallback: "Checking · %@", value)
    }

    private static func portText(_ item: AttentionItem) -> String {
        if case let .listener(_, _, port) = item.fact { return String(port) }
        return item.subjectName
    }
}

extension AllowedAction {
    /// Escalation after a quit visibly failed. Always confirms.
    var forceQuitFollowUp: AllowedAction? {
        switch subject {
        case .app, .group:
            return AllowedAction(action: .forceQuit, ref: ref, subject: subject, target: target, confirms: true)
        case .listener, .listenerProcess, .none:
            return nil
        }
    }

    static func reopen(_ app: AppRef, ref: String?) -> AllowedAction {
        AllowedAction(action: .reopenApp, ref: ref, subject: .app(app), target: app.name, confirms: false)
    }

    static func open(_ app: AppRef, ref: String?) -> AllowedAction {
        AllowedAction(action: .openApp, ref: ref, subject: .app(app), target: app.name, confirms: false)
    }

    static let snooze = AllowedAction(action: .snooze15, ref: nil, subject: .none, target: "", confirms: false)
}
