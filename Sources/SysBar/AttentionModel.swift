import AppKit
import Foundation

/// Owns the attention watch: the local rules, one AI brief per raised item,
/// the buttons each item offers and what happens when one is pressed, rate
/// limits, snooze/dismiss/mute, the 24-hour history and the manual review.
/// SysBar's measured fact is always shown first; the AI only explains it and
/// picks from buttons SysBar already knows how to press.
@MainActor
final class AttentionModel: ObservableObject {
    struct BriefMeta: Equatable, Codable, Sendable {
        let provider: AIProviderKind
        let model: String
        let seconds: Double
        let date: Date
        /// AI picks SysBar could not execute and dropped.
        var droppedPicks = 0
    }

    enum BriefState: Equatable {
        case providerOff
        case waitingForData
        case asking
        case ready(AttentionBrief, BriefMeta)
        case failed(AIProviderError)
        case paused
    }

    /// One pressed button and what came of it, shown under the buttons.
    struct ActionRun: Equatable {
        enum Phase: Equatable {
            case running
            case checking
            case done
            case info
            case failed
        }

        let action: AllowedAction
        var phase: Phase
        var line: String
        /// What the user can do next: Force Quit…, Reopen, Open.
        var followUps: [AllowedAction] = []

        var isBusy: Bool { phase == .running || phase == .checking }
    }

    struct Entry: Identifiable, Equatable {
        var item: AttentionItem
        var brief: BriefState
        var plan: ActionPlan
        var isDismissed = false
        var seenEarlier = false
        var lastRequestAt: Date?
        var notified = false
        var snoozedUntil: Date?
        /// Set when a snooze ran out with the item still active.
        var isReminder = false
        var run: ActionRun?
        /// The button that fixed it, once SysBar verified the fix.
        var resolution: String?

        var id: AttentionKey { item.id }

        var isExpected: Bool {
            if case let .ready(brief, _) = brief { return brief.verdict == .expected }
            return false
        }

        var isSnoozed: Bool { snoozedUntil != nil }
        var isResolved: Bool { resolution != nil }

        /// Counts toward "N things need attention".
        var needsAttention: Bool { !isDismissed && !isExpected && !isSnoozed && !isResolved }
    }

    enum ReviewState: Equatable {
        case idle
        case running
        case ready(ReviewBrief, BriefMeta)
        case failed(AIProviderError)
    }

    struct HistoryEntry: Codable, Equatable, Identifiable {
        let id: UUID
        let fact: String
        let headline: String?
        let raisedAt: Date
        let clearedAt: Date
        /// "Restart ChatGPT" when a verified action fixed it.
        var resolution: String?
    }

    struct Mute: Codable, Equatable {
        let name: String
        let until: Date
    }

    struct AllowedListener: Codable, Equatable, Sendable {
        let name: String
        let isTCP: Bool
        let port: UInt16
    }

    /// SysBar's own confirmation, used only where macOS gives no second
    /// chance: quitting more than one process, stopping a listener, and every
    /// Force Quit.
    struct ActionConfirmation: Identifiable, Equatable {
        let id = UUID()
        let key: AttentionKey
        let action: AllowedAction
        let title: String
        let message: String
        let confirmTitle: String
        /// For Stop: the identity read on the click; the user confirms this
        /// process instance and nothing else is ever signaled.
        var identity: ProcessIdentity?
    }

    enum ActionSource: Sendable {
        case card
        case notification
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var review: ReviewState = .idle
    @Published private(set) var provider: AIProviderKind
    @Published private(set) var statuses: [AIProviderKind: AIProviderStatus] = [
        .claude: .checking,
        .codex: .checking
    ]
    @Published private(set) var mutes: [String: Mute] = [:]
    @Published private(set) var allowedListeners: [String: AllowedListener] = [:]
    @Published private(set) var pendingConfirmation: ActionConfirmation?
    /// Bumped when something outside the popover asks to show an item.
    @Published private(set) var revealCount = 0

    static let maxCallsPerHour = 6
    static let maxCallsPerDay = 30
    static let manualRefreshInterval: TimeInterval = 5 * 60
    static let cacheLifetime: TimeInterval = 24 * 60 * 60
    static let dismissedQuietPeriod: TimeInterval = 30 * 60
    static let reviewReuse: TimeInterval = 5 * 60
    static let historyLimit = 10
    static let snoozeInterval: TimeInterval = 15 * 60
    static let quitWait: TimeInterval = 20
    static let quitPoll: TimeInterval = 0.5
    static let doneLinger: TimeInterval = 1.5
    static let undoLinger: TimeInterval = 60

    /// Supplied by `SystemMonitor`: everything SysBar knows right now.
    var evidenceInputs: () -> BriefInputs? = { nil }
    /// Delivers a macOS notification (honors the Alerts toggle).
    var notify: (AttentionNotification) -> Void = { _ in }
    var isPanelOpen: () -> Bool = { false }
    var onWatchChange: (Bool) -> Void = { _ in }
    var onAttentionChange: (Bool) -> Void = { _ in }
    /// Asks the monitor for fresh samples to check an action's result; true
    /// also re-runs the slow collectors (ports, disk).
    var resample: (Bool) -> Void = { _ in }
    /// Identity-bound signals through the monitor's `ProcessActionService`.
    var signalProcesses: (ProcessSignal, [ProcessIdentity]) async -> ProcessActionReport
    /// Reads a listener's PID identity when Stop is pressed (ADR-023).
    var resolveIdentity: (Int32) -> ProcessIdentity? = { pid in
        guard case let .success(identity) = ProcessIdentityResolver(reader: DarwinProcessIdentityReader()).resolve(pid: pid) else {
            return nil
        }
        return identity
    }
    /// Re-runs the bounded lsof scan, bracketed by that identity, to prove who
    /// owns the listener's endpoint right before Stop signals.
    var checkListenerOwner: (ListenerStopTarget, ProcessIdentity) async -> ListenerOwnership = { target, identity in
        await Task.detached(priority: .userInitiated) { PortsAPI.ownership(of: target, expected: identity) }.value
    }
    var closePopover: () -> Void = {}
    /// Opens the popover on an item (a tapped notification).
    var revealRequest: (AttentionKey) -> Void = { _ in }

    private var tracker = AttentionTracker()
    private let providers: [AIProviderKind: any BriefProviding]
    private let defaults: UserDefaults
    private let now: () -> Date
    private let apps: any RunningAppControlling
    private let settings: any SettingsOpening
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var automaticCalls: [Date] = []
    private var tasks: [AttentionKey: Task<Void, Never>] = [:]
    private var actionTasks: [AttentionKey: Task<Void, Never>] = [:]
    private var reviewTask: Task<Void, Never>?
    private var reviewItemsSignature: [AttentionKey] = []
    private var cache: [AttentionKey: CachedBrief] = [:]
    private var dismissedClearedAt: [AttentionKey: Date] = [:]
    private var lastProbeAt: Date?
    private var probeTask: Task<Void, Never>?

    private struct CachedBrief {
        let bucket: Int
        let state: BriefState
        let plan: ActionPlan
        let date: Date
    }

    private static let historyKey = "AttentionHistory"
    private static let mutesKey = "AttentionMutes"
    static let allowedListenersKey = "AttentionAllowedListeners"

    init(
        providers: [AIProviderKind: any BriefProviding] = [
            .claude: ClaudeCodeProvider(),
            .codex: CodexBriefProvider()
        ],
        defaults: UserDefaults = .standard,
        apps: (any RunningAppControlling)? = nil,
        settings: (any SettingsOpening)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.providers = providers
        self.defaults = defaults
        self.apps = apps ?? WorkspaceAppController()
        self.settings = settings ?? WorkspaceSettingsOpener()
        self.sleep = sleep
        self.now = now
        let processActions = ProcessActionService()
        signalProcesses = { signal, identities in await processActions.perform(signal, on: identities) }
        provider = defaults.string(forKey: AIProviderPolicy.selectionKey)
            .flatMap(AIProviderKind.init(rawValue:)) ?? .off
        history = Self.load([HistoryEntry].self, key: Self.historyKey, from: defaults) ?? []
        mutes = Self.load([String: Mute].self, key: Self.mutesKey, from: defaults) ?? [:]
        allowedListeners = Self.load([String: AllowedListener].self, key: Self.allowedListenersKey, from: defaults) ?? [:]
        pruneExpired()
    }

    var attentionEntries: [Entry] { entries.filter(\.needsAttention) }
    /// Cards: what needs attention, plus a fix whose result is still showing.
    var cardEntries: [Entry] { entries.filter { $0.needsAttention || ($0.isResolved && $0.run != nil) } }
    var hasAttention: Bool { !attentionEntries.isEmpty }
    var watchEnabled: Bool { provider != .off }
    var hasStoredSelection: Bool { defaults.string(forKey: AIProviderPolicy.selectionKey) != nil }

    // MARK: Samples from the monitor

    func ingestProcesses(_ groups: [ProcessGroup], frontmostAppPath: String?, ownPath: String?, at date: Date) {
        apply(tracker.ingestProcesses(
            groups,
            frontmostAppPath: frontmostAppPath,
            excludedPaths: ownPath.map { [$0] } ?? [],
            at: date
        ))
    }

    func ingestHost(cpuHistory: [Double], memory: MemorySnapshot?, swap: SwapSnapshot?, at date: Date) {
        apply(tracker.ingestHost(cpuHistory: cpuHistory, memory: memory, swap: swap, at: date))
        retryWaitingBriefs()
    }

    func ingestDisk(freeGB: Double, totalGB: Double, at date: Date) {
        apply(tracker.ingestDisk(freeGB: freeGB, totalGB: totalGB, at: date))
    }

    func ingestListeners(
        _ ports: [ListenSocket],
        trusted: Set<ListenerEndpointKey>,
        names: [Int32: String],
        at date: Date
    ) {
        // Listeners the user allowed count as trusted for the rules only;
        // the Network list still shows them as open to the network.
        let allowed = Set(ports.filter { allowedListeners[AttentionTracker.subject(for: $0)] != nil }.map(\.endpointKey))
        apply(tracker.ingestListeners(ports, trusted: trusted.union(allowed), displayNames: names, at: date))
    }

    private func apply(_ changes: AttentionChanges) {
        let date = now()
        let hadAttention = hasAttention
        var updated = entries
        var reminders: [AttentionKey] = []

        for key in changes.cleared {
            tasks[key]?.cancel()
            tasks[key] = nil
            guard let index = updated.firstIndex(where: { $0.id == key }) else { continue }
            // An action is checking its own result; let it finish and resolve.
            if updated[index].run?.isBusy == true || updated[index].isResolved { continue }
            let entry = updated.remove(at: index)
            if entry.isDismissed { dismissedClearedAt[key] = date }
            appendHistory(Self.historyEntry(entry, clearedAt: date))
        }

        var toRequest: [AttentionKey] = []
        for item in changes.raised where updated.allSatisfy({ $0.id != item.id }) {
            guard !isMuted(item.id.subject, at: date) else { continue }
            var entry = Entry(item: item, brief: .providerOff, plan: defaultPlan(for: item))
            if let clearedAt = dismissedClearedAt[item.id],
               date.timeIntervalSince(clearedAt) < Self.dismissedQuietPeriod {
                entry.isDismissed = true
            }
            if let cached = cache[item.id],
               date.timeIntervalSince(cached.date) < Self.cacheLifetime,
               cached.bucket == item.magnitudeBucket {
                entry.brief = cached.state
                entry.plan = cached.plan
                entry.seenEarlier = true
                entry.notified = true
            } else {
                toRequest.append(item.id)
            }
            updated.append(entry)
        }

        for index in updated.indices {
            // Keep the measured facts current while items stay raised.
            if let live = tracker.active[updated[index].id] {
                updated[index].item.fact = live.fact
                updated[index].item.magnitudeBucket = live.magnitudeBucket
            }
            // A snooze that ran out with the item still active reminds once.
            if let until = updated[index].snoozedUntil, until <= date {
                updated[index].snoozedUntil = nil
                updated[index].isReminder = true
                updated[index].notified = false
                reminders.append(updated[index].id)
            }
        }
        updated.sort { $0.item.raisedAt > $1.item.raisedAt }
        if updated != entries { entries = updated }

        for key in toRequest { requestBrief(for: key, automatic: true) }
        for key in reminders { notifyIfClosed(key) }
        if hadAttention != hasAttention { onAttentionChange(hasAttention) }
    }

    private static func historyEntry(_ entry: Entry, clearedAt: Date) -> HistoryEntry {
        var headline: String?
        if case let .ready(brief, _) = entry.brief { headline = brief.headline }
        return HistoryEntry(
            id: UUID(),
            fact: entry.item.fact.text,
            headline: headline,
            raisedAt: entry.item.raisedAt,
            clearedAt: clearedAt,
            resolution: entry.resolution
        )
    }

    // MARK: Plans

    /// The evidence for one item: also what the AI may pick from.
    private func evidence(for item: AttentionItem, inputs: BriefInputs, kind: String = "attention") -> BriefEvidence {
        var full = BriefInputs(
            now: inputs.now,
            mac: inputs.mac,
            snapshot: inputs.snapshot,
            processes: inputs.processes,
            trigger: item,
            activeItems: entries.map(\.item),
            appNames: inputs.appNames,
            listenerAppNames: inputs.listenerAppNames,
            ownExecutablePath: inputs.ownExecutablePath,
            frontmostAppPath: inputs.frontmostAppPath
        )
        full.runningApps = apps.apps()
        return BriefEvidence.make(full, kind: kind)
    }

    private static func plan(
        picks: [ActionPick],
        verdict: AttentionBrief.Verdict?,
        item: AttentionItem,
        evidence: BriefEvidence
    ) -> ActionPlan {
        ActionPlanner.plan(
            picks: picks,
            verdict: verdict,
            rule: item.rule,
            triggerRef: evidence.triggerRef,
            topCPURefs: evidence.topCPURefs,
            topMemoryRefs: evidence.topMemoryRefs,
            allowed: evidence.allowedActions
        )
    }

    /// SysBar's own buttons for an item, with no AI involved.
    private func defaultPlan(for item: AttentionItem) -> ActionPlan {
        guard let inputs = evidenceInputs() else {
            return ActionPlanner.plan(
                picks: [], verdict: nil, rule: item.rule, triggerRef: nil,
                topCPURefs: [], topMemoryRefs: [], allowed: [.snooze]
            )
        }
        return Self.plan(picks: [], verdict: nil, item: item, evidence: evidence(for: item, inputs: inputs))
    }

    // MARK: Briefs

    private func requestBrief(for key: AttentionKey, automatic: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == key }) else { return }
        guard provider != .off, let implementation = providers[provider] else {
            entries[index].brief = .providerOff
            return
        }
        guard let inputs = evidenceInputs(),
              PanelHealthPresentation.snapshot(inputs.snapshot) == .current || inputs.processes != nil else {
            entries[index].brief = .waitingForData
            return
        }
        let date = now()
        if automatic {
            automaticCalls.removeAll { date.timeIntervalSince($0) > 24 * 60 * 60 }
            let lastHour = automaticCalls.filter { date.timeIntervalSince($0) <= 60 * 60 }.count
            guard lastHour < Self.maxCallsPerHour, automaticCalls.count < Self.maxCallsPerDay else {
                entries[index].brief = .paused
                notifyIfClosed(key)
                return
            }
            automaticCalls.append(date)
        }

        let item = entries[index].item
        entries[index].brief = .asking
        entries[index].lastRequestAt = date
        let evidence = evidence(for: item, inputs: inputs)
        // The buttons SysBar would offer anyway, refreshed with this evidence.
        entries[index].plan = Self.plan(picks: [], verdict: nil, item: item, evidence: evidence)
        let kind = provider
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            var plan: ActionPlan?
            let state: BriefState
            do {
                let json = try evidence.json()
                let call = AIBriefCall(
                    systemPrompt: BriefPrompt.system,
                    userMessage: BriefPrompt.attention(observed: item.fact.text, rule: item.rule, evidenceJSON: json),
                    schema: BriefPrompt.attentionSchema
                )
                let result = try await implementation.run(call)
                let brief = try BriefValidation.attention(result.object, evidence: evidence)
                // Picks are resolved against the evidence the AI actually saw,
                // so a ref can never point at a process that took its place.
                let planned = Self.plan(picks: brief.actions, verdict: brief.verdict, item: item, evidence: evidence)
                plan = planned
                state = .ready(brief, BriefMeta(
                    provider: kind,
                    model: result.modelLabel,
                    seconds: result.durationSeconds,
                    date: Date(),
                    droppedPicks: planned.droppedPicks
                ))
            } catch let error as AIProviderError {
                state = .failed(error)
            } catch {
                state = Task.isCancelled ? .failed(.cancelled) : .failed(.failed)
            }
            guard !Task.isCancelled else { return }
            self?.finishBrief(key, state: state, plan: plan, bucket: item.magnitudeBucket)
        }
    }

    private func finishBrief(_ key: AttentionKey, state: BriefState, plan: ActionPlan?, bucket: Int) {
        tasks[key] = nil
        guard let index = entries.firstIndex(where: { $0.id == key }) else { return }
        let hadAttention = hasAttention
        entries[index].brief = state
        if let plan { entries[index].plan = plan }
        if case .ready = state {
            cache[key] = CachedBrief(bucket: bucket, state: state, plan: entries[index].plan, date: now())
        }
        if case .failed(.signInNeeded) = state { refreshProviders(force: true) }
        notifyIfClosed(key)
        if hadAttention != hasAttention { onAttentionChange(hasAttention) }
    }

    /// One notification per item, only once the verdict is known, never for
    /// an "expected" verdict. A failed brief still notifies with the fact, so
    /// a broken CLI never hides a real event. The notification carries the
    /// card's buttons that need no confirmation.
    private func notifyIfClosed(_ key: AttentionKey) {
        guard let index = entries.firstIndex(where: { $0.id == key }),
              !entries[index].notified, !entries[index].isDismissed, !entries[index].isSnoozed,
              provider != .off, !isPanelOpen() else { return }
        let entry = entries[index]
        var title: String
        let body: String
        switch entry.brief {
        case .asking, .waitingForData, .providerOff:
            return
        case let .ready(brief, _):
            guard brief.verdict != .expected else {
                entries[index].notified = true
                return
            }
            title = brief.headline
            body = Self.notificationBody(brief)
        case .failed, .paused:
            title = entry.item.fact.text
            body = AppResources.localized("notification.fact.body", fallback: "Open SysBar for details.")
        }
        if entry.isReminder {
            title = AppResources.formatted("notification.still.title", fallback: "Still: %@", entry.item.fact.text)
        }
        notify(AttentionNotification(
            key: key,
            title: title,
            body: body,
            actions: Self.notificationActions(entry.plan)
        ))
        entries[index].notified = true
    }

    static func notificationActions(_ plan: ActionPlan) -> [AttentionNotification.Action] {
        var actions = plan.buttons.map(\.allowed).filter { $0.action.isNotificationSafe }
        if !actions.contains(where: { $0.action == .snooze15 }) { actions.append(.snooze) }
        return actions.prefix(3).map {
            AttentionNotification.Action(
                id: $0.id,
                title: ActionLabel.title($0),
                isDestructive: $0.action == .quitApp,
                opensApp: $0.action == .openApp || $0.action == .openStorageSettings || $0.action == .openSharingSettings
            )
        }
    }

    static func notificationBody(_ brief: AttentionBrief) -> String {
        let body = brief.why.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.count <= 200 ? body : String(body.prefix(199)) + "…"
    }

    private func notifyResultIfClosed(_ key: AttentionKey, line: String) {
        guard !isPanelOpen(), provider != .off,
              let entry = entries.first(where: { $0.id == key }) else { return }
        notify(AttentionNotification(key: key, title: line, body: entry.item.fact.text, actions: []))
    }

    private func retryWaitingBriefs() {
        for entry in entries where entry.brief == .waitingForData {
            requestBrief(for: entry.id, automatic: true)
        }
    }

    // MARK: User actions on the card

    func canRefresh(_ key: AttentionKey) -> Bool {
        guard let entry = entries.first(where: { $0.id == key }), entry.brief != .asking else { return false }
        guard let last = entry.lastRequestAt else { return true }
        return now().timeIntervalSince(last) >= Self.manualRefreshInterval
    }

    func refresh(_ key: AttentionKey) {
        guard canRefresh(key) else { return }
        requestBrief(for: key, automatic: false)
    }

    func tryAgain(_ key: AttentionKey) {
        requestBrief(for: key, automatic: false)
    }

    func dismiss(_ key: AttentionKey) {
        guard let index = entries.firstIndex(where: { $0.id == key }) else { return }
        let hadAttention = hasAttention
        entries[index].isDismissed = true
        if hadAttention != hasAttention { onAttentionChange(hasAttention) }
    }

    func muteToday(_ key: AttentionKey) {
        guard let entry = entries.first(where: { $0.id == key }) else { return }
        let hadAttention = hasAttention
        let endOfDay = Calendar.current.startOfDay(for: now()).addingTimeInterval(24 * 60 * 60)
        mutes[key.subject] = Mute(name: entry.item.subjectName, until: endOfDay)
        tasks[key]?.cancel()
        tasks[key] = nil
        entries.removeAll { $0.id == key }
        save(mutes, key: Self.mutesKey)
        if hadAttention != hasAttention { onAttentionChange(hasAttention) }
    }

    func unmute(_ subject: String) {
        mutes[subject] = nil
        save(mutes, key: Self.mutesKey)
    }

    func isMuted(_ subject: String, at date: Date) -> Bool {
        guard let mute = mutes[subject] else { return false }
        return mute.until > date
    }

    func snooze(_ key: AttentionKey) {
        guard let index = entries.firstIndex(where: { $0.id == key }) else { return }
        let hadAttention = hasAttention
        entries[index].snoozedUntil = now().addingTimeInterval(Self.snoozeInterval)
        entries[index].isReminder = false
        entries[index].run = nil
        if hadAttention != hasAttention { onAttentionChange(hasAttention) }
    }

    func showNow(_ key: AttentionKey) {
        guard let index = entries.firstIndex(where: { $0.id == key }), entries[index].isSnoozed else { return }
        let hadAttention = hasAttention
        entries[index].snoozedUntil = nil
        if hadAttention != hasAttention { onAttentionChange(hasAttention) }
    }

    /// A tapped notification: bring the item back if it was snoozed and ask
    /// the popover to expand its status area.
    func reveal(_ key: AttentionKey) {
        showNow(key)
        revealCount &+= 1
    }

    /// The user vouches for a listener from the Network section. A raised
    /// card for it resolves the same way as its own Allow button.
    func allow(_ port: ListenSocket) {
        let subject = AttentionTracker.subject(for: port)
        let action = AllowedAction(
            action: .allowListener,
            ref: nil,
            subject: .listener(name: port.processName, isTCP: port.isTCP, port: port.port),
            target: port.processName,
            confirms: false
        )
        if let key = entries.first(where: { $0.id.rule == .newListener && $0.id.subject == subject && !$0.isResolved })?.id {
            return allowListener(key, action: action)
        }
        allowedListeners[subject] = AllowedListener(name: port.processName, isTCP: port.isTCP, port: port.port)
        save(allowedListeners, key: Self.allowedListenersKey)
    }

    func removeAllowedListener(_ subject: String) {
        allowedListeners[subject] = nil
        save(allowedListeners, key: Self.allowedListenersKey)
    }

    /// Records a fix: the item leaves the count at once, the rules forget its
    /// history so a genuine recurrence raises cleanly, and the history row
    /// says what fixed it.
    func resolve(_ key: AttentionKey, by label: String) {
        guard let index = entries.firstIndex(where: { $0.id == key }), !entries[index].isResolved else { return }
        let hadAttention = hasAttention
        entries[index].resolution = label
        tracker.forget(key)
        cache[key] = nil
        tasks[key]?.cancel()
        tasks[key] = nil
        appendHistory(Self.historyEntry(entries[index], clearedAt: now()))
        if hadAttention != hasAttention { onAttentionChange(hasAttention) }
    }

    // MARK: Executing an action

    /// Runs one of the card's (or a notification's) buttons. Every subject is
    /// re-resolved live first: an app by its bundle location, a process group
    /// by its executable path with fresh identities.
    func perform(_ action: AllowedAction, for key: AttentionKey, source: ActionSource = .card) {
        guard let index = entries.firstIndex(where: { $0.id == key }),
              entries[index].run?.isBusy != true else { return }
        if source == .notification, !action.action.isNotificationSafe {
            revealRequest(key)
            return
        }
        switch action.action {
        case .snooze15:
            snooze(key)
        case .allowListener:
            allowListener(key, action: action)
        case .openStorageSettings, .openSharingSettings:
            if settings.open(action.action) {
                setRun(key, ActionRun(
                    action: action,
                    phase: .info,
                    line: AppResources.localized("action.result.settingsOpened", fallback: "Opened in System Settings")
                ))
            } else {
                setRun(key, ActionRun(
                    action: action,
                    phase: .failed,
                    line: AppResources.localized("action.result.settingsFailed", fallback: "System Settings couldn't be opened"),
                    followUps: [action]
                ))
            }
        case .openApp:
            guard case let .app(app) = action.subject, apps.isRunning(app) else { return alreadyGone(key, action) }
            if apps.activate(app) {
                setRun(key, nil)
                closePopover()
            } else {
                setRun(key, ActionRun(
                    action: action,
                    phase: .failed,
                    line: AppResources.formatted("action.result.activateFailed", fallback: "Couldn't bring %@ forward", app.name)
                ))
            }
        case .reopenApp:
            guard case let .app(app) = action.subject else { return }
            setRun(key, ActionRun(
                action: action,
                phase: .running,
                line: AppResources.formatted("action.progress.reopening", fallback: "Reopening %@…", app.name)
            ))
            actionTasks[key] = Task { [weak self] in
                guard let self else { return }
                let opened = await self.apps.open(bundlePath: app.bundlePath)
                self.updateRun(key) { run in
                    run.phase = opened ? .done : .failed
                    run.line = opened
                        ? AppResources.formatted("action.result.done.reopened", fallback: "%@ reopened", app.name)
                        : AppResources.formatted("action.result.relaunchFailed", fallback: "%@ quit but couldn't be reopened", app.name)
                    run.followUps = opened ? [] : [action]
                }
            }
        case .restartApp, .quitApp:
            guard case let .app(app) = action.subject, apps.isRunning(app) else { return alreadyGone(key, action) }
            let before = reading(for: key)
            // The quit is sent on the click itself; only the waiting is async.
            setRun(key, ActionRun(
                action: action,
                phase: .running,
                line: AppResources.formatted("action.progress.quitting", fallback: "Asked %@ to quit · waiting up to 20 s", app.name)
            ))
            guard apps.terminate(app) else {
                return setRun(key, ActionRun(
                    action: action,
                    phase: .failed,
                    line: AppResources.formatted("action.result.notAccepted", fallback: "%@ didn't accept the quit request", app.name),
                    followUps: [action.forceQuitFollowUp].compactMap { $0 }
                ))
            }
            actionTasks[key] = Task { [weak self] in
                await self?.finishQuit(app, restart: action.action == .restartApp, action: action, key: key, before: before)
            }
        case .quitProcesses:
            guard let group = liveGroup(for: action) else { return alreadyGone(key, action) }
            if group.count > 1 {
                pendingConfirmation = ActionConfirmation(
                    key: key,
                    action: action,
                    title: AppResources.formatted("action.confirm.quit.title", fallback: "Quit %@?", group.name),
                    message: Self.pidMessage(group),
                    confirmTitle: AppResources.localized("action.confirm.quit.button", fallback: "Quit")
                )
                return
            }
            runSignal(.terminate, on: group, action: action, key: key)
        case .stopListener:
            guard case let .listenerProcess(target) = action.subject else { return }
            // Everything after this click is bound to the identity read now.
            guard let identity = resolveIdentity(target.pid) else { return alreadyGone(key, action) }
            guard identity.executablePath == target.executablePath else {
                setRun(key, ActionRun(action: action, phase: .failed, line: Self.identityChangedLine))
                return resample(true)
            }
            pendingConfirmation = ActionConfirmation(
                key: key,
                action: action,
                title: AppResources.formatted("action.confirm.stopListener.title", fallback: "Stop %@?", target.processName),
                message: AppResources.formatted(
                    "action.confirm.stopListener.message",
                    fallback: "%1$@ (PID %2$@, %3$@) is accepting network connections on %4$@. SysBar re-checks that this process still owns the port, then asks it to quit. Unsaved work in it is lost.",
                    target.processName,
                    String(identity.pid),
                    identity.executablePath,
                    target.address
                ),
                confirmTitle: AppResources.localized("action.confirm.stopListener.button", fallback: "Stop"),
                identity: identity
            )
        case .forceQuit:
            let name = action.target
            let message: String
            switch action.subject {
            case .app:
                message = AppResources.formatted(
                    "action.confirm.forceQuitApp.message",
                    fallback: "Force quitting ends %1$@ immediately; unsaved work in %1$@ is lost.",
                    name
                )
            default:
                guard let group = liveGroup(for: action) else { return alreadyGone(key, action) }
                message = Self.pidMessage(group)
            }
            pendingConfirmation = ActionConfirmation(
                key: key,
                action: action,
                title: AppResources.formatted("action.confirm.forceQuit.title", fallback: "Force Quit %@?", name),
                message: message,
                confirmTitle: AppResources.localized("action.confirm.forceQuit.button", fallback: "Force Quit")
            )
        }
    }

    /// Runs a button that arrived from a notification, by its identifier.
    func performNotificationAction(_ identifier: String, for key: AttentionKey) {
        guard let entry = entries.first(where: { $0.id == key }) else { return }
        let candidates = entry.plan.buttons.map(\.allowed) + [.snooze]
        guard let action = candidates.first(where: { $0.id == identifier }) else { return }
        perform(action, for: key, source: .notification)
    }

    func confirmPending() {
        guard let confirmation = pendingConfirmation else { return }
        pendingConfirmation = nil
        let key = confirmation.key
        let action = confirmation.action
        guard entries.contains(where: { $0.id == key }) else { return }
        switch (action.action, action.subject) {
        case let (.forceQuit, .app(app)):
            guard apps.isRunning(app) else { return alreadyGone(key, action) }
            let before = reading(for: key)
            setRun(key, ActionRun(
                action: action,
                phase: .running,
                line: AppResources.formatted("action.progress.forceQuitting", fallback: "Force quitting %@…", app.name)
            ))
            guard apps.forceTerminate(app) else {
                return setRun(key, ActionRun(
                    action: action,
                    phase: .failed,
                    line: AppResources.formatted("action.result.notAccepted", fallback: "%@ didn't accept the quit request", app.name)
                ))
            }
            actionTasks[key] = Task { [weak self] in
                guard let self else { return }
                _ = await self.waitUntilGone(app, seconds: 5)
                await self.verify(key, action: action, before: before, note: nil, followUps: [.reopen(app, ref: action.ref)])
            }
        case (.forceQuit, _):
            guard let group = liveGroup(for: action) else { return alreadyGone(key, action) }
            runSignal(.forceKill, on: group, action: action, key: key)
        case (.quitProcesses, _):
            guard let group = liveGroup(for: action) else { return alreadyGone(key, action) }
            runSignal(.terminate, on: group, action: action, key: key)
        case let (.stopListener, .listenerProcess(target)):
            guard let identity = confirmation.identity else { return }
            stopListener(target, identity: identity, action: action, key: key)
        default:
            break
        }
    }

    func cancelPending() {
        pendingConfirmation = nil
    }

    /// Clears a finished or failed result line ("Keep watching").
    func clearRun(_ key: AttentionKey) {
        guard let index = entries.firstIndex(where: { $0.id == key }), entries[index].run?.isBusy != true else { return }
        entries[index].run = nil
    }

    private func finishQuit(
        _ app: AppRef,
        restart: Bool,
        action: AllowedAction,
        key: AttentionKey,
        before: VerificationReading
    ) async {
        guard await waitUntilGone(app, seconds: Self.quitWait) else {
            return setRun(key, ActionRun(
                action: action,
                phase: .failed,
                line: AppResources.formatted(
                    "action.result.stillRunning",
                    fallback: "%@ is still running — it may be asking you to save.",
                    app.name
                ),
                followUps: [.open(app, ref: action.ref), action.forceQuitFollowUp].compactMap { $0 }
            ))
        }
        guard restart else {
            return await verify(key, action: action, before: before, note: nil, followUps: [.reopen(app, ref: action.ref)])
        }
        setRun(key, ActionRun(
            action: action,
            phase: .running,
            line: AppResources.formatted("action.progress.quit", fallback: "%@ quit · reopening…", app.name)
        ))
        // The bundle location was captured before the quit; the relaunch
        // never looks the app up again by name or identifier.
        guard await apps.open(bundlePath: app.bundlePath) else {
            return setRun(key, ActionRun(
                action: action,
                phase: .failed,
                line: AppResources.formatted("action.result.relaunchFailed", fallback: "%@ quit but couldn't be reopened", app.name),
                followUps: [.reopen(app, ref: action.ref)]
            ))
        }
        let note = AppResources.formatted("action.result.done.reopened", fallback: "%@ reopened", app.name)
        await verify(key, action: action, before: before, note: note, followUps: [])
    }

    private func waitUntilGone(_ app: AppRef, seconds: TimeInterval) async -> Bool {
        let polls = max(1, Int((seconds / Self.quitPoll).rounded()))
        for _ in 0..<polls {
            if !apps.isRunning(app) { return true }
            await sleep(Self.quitPoll)
        }
        return !apps.isRunning(app)
    }

    private func runSignal(_ signal: ProcessSignal, on group: ProcessGroup, action: AllowedAction, key: AttentionKey) {
        let before = reading(for: key)
        let identities = group.expectedIdentities
        setRun(key, ActionRun(
            action: action,
            phase: .running,
            line: AppResources.formatted("action.progress.quittingProcesses", fallback: "Quitting %@…", group.name)
        ))
        actionTasks[key] = Task { [weak self] in
            guard let self else { return }
            let report = await self.signalProcesses(signal, identities)
            let signaled = report.results.filter { $0.outcome == .signaled }.count
            guard signaled > 0 else {
                return self.setRun(key, ActionRun(action: action, phase: .failed, line: Self.identityChangedLine))
            }
            let follow = signal == .terminate ? [action.forceQuitFollowUp].compactMap { $0 } : []
            await self.verify(key, action: action, before: before, note: nil, followUps: [], notBetterFollowUps: follow)
        }
    }

    private static var identityChangedLine: String {
        AppResources.localized("action.result.identityChanged", fallback: "A process changed; no signal was sent to it.")
    }

    /// Stop on a new-listener card, after the user confirmed (ADR-023): prove
    /// with a fresh bounded scan that the confirmed process instance still owns
    /// that exact endpoint, then SIGTERM it through `ProcessActionService`,
    /// which revalidates the identity once more immediately before `kill`.
    private func stopListener(
        _ target: ListenerStopTarget,
        identity: ProcessIdentity,
        action: AllowedAction,
        key: AttentionKey
    ) {
        let before = reading(for: key)
        let port = String(target.endpoint.port)
        setRun(key, ActionRun(
            action: action,
            phase: .running,
            line: AppResources.formatted(
                "action.progress.checkingOwner", fallback: "Checking that %1$@ still owns port %2$@…",
                target.processName, port
            )
        ))
        actionTasks[key] = Task { [weak self] in
            guard let self else { return }
            let ownership = await self.checkListenerOwner(target, identity)
            guard !Task.isCancelled else { return }
            let refusal: ActionRun?
            switch ownership {
            case .confirmed:
                refusal = nil
            case .closed:
                refusal = ActionRun(
                    action: action,
                    phase: .info,
                    line: AppResources.formatted("action.result.portClosed", fallback: "Port %@ is already closed; nothing was stopped.", port)
                )
            case .otherOwner:
                refusal = ActionRun(
                    action: action,
                    phase: .failed,
                    line: AppResources.formatted(
                        "action.result.otherOwner", fallback: "Port %@ now belongs to another process; nothing was stopped.", port
                    )
                )
            case .changed:
                refusal = ActionRun(action: action, phase: .failed, line: Self.identityChangedLine)
            case .unverified:
                refusal = ActionRun(
                    action: action,
                    phase: .failed,
                    line: AppResources.formatted("action.result.recheckFailed", fallback: "Couldn't re-check port %@; nothing was stopped.", port),
                    followUps: [action]
                )
            }
            if let refusal {
                self.setRun(key, refusal)
                self.resample(true)
                return
            }
            self.updateRun(key) {
                $0.line = AppResources.formatted("action.progress.stopping", fallback: "Stopping %@…", target.processName)
            }
            let report = await self.signalProcesses(.terminate, [identity])
            guard report.results.contains(where: { $0.outcome == .signaled }) else {
                self.setRun(key, ActionRun(action: action, phase: .failed, line: Self.identityChangedLine))
                self.resample(true)
                return
            }
            await self.verify(key, action: action, before: before, note: nil, followUps: [], notBetterFollowUps: [])
        }
    }

    /// Re-samples and decides from SysBar's own numbers whether the action
    /// fixed the item. A verified fix resolves it at once.
    private func verify(
        _ key: AttentionKey,
        action: AllowedAction,
        before: VerificationReading,
        note: String?,
        followUps: [AllowedAction],
        notBetterFollowUps: [AllowedAction]? = nil
    ) async {
        guard let item = entries.first(where: { $0.id == key })?.item else { return }
        let slow = ActionVerification.needsSlowSample(item.rule)
        func joined(_ line: String) -> String {
            guard let note else { return line }
            return AppResources.formatted("action.result.joined", fallback: "%1$@ · %2$@", line, note)
        }
        setRun(key, ActionRun(
            action: action,
            phase: .checking,
            line: joined(AppResources.localized("action.progress.checking", fallback: "Checking…"))
        ))
        resample(slow)
        // Each check reads a sample taken just before it: request it a moment
        // ahead (longer for an lsof scan), then look.
        let lead: TimeInterval = slow ? 2.5 : 1
        var elapsed: TimeInterval = 0
        for step in ActionVerification.steps(for: item.rule) {
            if step > lead {
                await sleep(step - lead)
                resample(slow)
                await sleep(lead)
            } else {
                await sleep(step)
            }
            elapsed += step
            guard !Task.isCancelled, let current = entries.first(where: { $0.id == key }) else { return }
            let after = reading(for: key)
            switch ActionVerification.outcome(rule: item.rule, before: before, after: after, elapsed: elapsed) {
            case .pending:
                updateRun(key) { $0.line = joined(ActionResultText.progress(current.item, after: after)) }
            case .done:
                let line = joined(ActionResultText.done(current.item, after: after))
                setRun(key, ActionRun(action: action, phase: .done, line: line, followUps: followUps))
                resolve(key, by: ActionLabel.title(action))
                notifyResultIfClosed(key, line: line)
                announce(line)
                await sleep(followUps.isEmpty ? Self.doneLinger : Self.undoLinger)
                removeResolved(key)
                return
            case .notBetter:
                let line = joined(ActionResultText.notBetter(current.item, after: after, elapsed: elapsed))
                let escalation = notBetterFollowUps ?? [action.forceQuitFollowUp].compactMap { $0 }
                setRun(key, ActionRun(action: action, phase: .failed, line: line, followUps: escalation))
                notifyResultIfClosed(key, line: AppResources.formatted(
                    "notification.result.still", fallback: "%@ — open SysBar", line
                ))
                announce(line)
                return
            }
        }
    }

    private func allowListener(_ key: AttentionKey, action: AllowedAction) {
        guard case let .listener(name, isTCP, port) = action.subject else { return }
        allowedListeners[key.subject] = AllowedListener(name: name, isTCP: isTCP, port: port)
        save(allowedListeners, key: Self.allowedListenersKey)
        let label = ActionLabel.title(action)
        setRun(key, ActionRun(
            action: action,
            phase: .done,
            line: AppResources.localized("action.result.allowed", fallback: "Allowed · SysBar won't flag this port again")
        ))
        resolve(key, by: label)
        actionTasks[key] = Task { [weak self] in
            guard let self else { return }
            await self.sleep(Self.doneLinger)
            self.removeResolved(key)
        }
    }

    private func alreadyGone(_ key: AttentionKey, _ action: AllowedAction) {
        setRun(key, ActionRun(
            action: action,
            phase: .info,
            line: AppResources.formatted("action.result.gone", fallback: "%@ is no longer running", action.target)
        ))
        resample(ActionVerification.needsSlowSample(key.rule))
    }

    private func removeResolved(_ key: AttentionKey) {
        guard entries.contains(where: { $0.id == key && $0.isResolved }) else { return }
        entries.removeAll { $0.id == key }
        actionTasks[key] = nil
        // If the rules re-raised it while the result lingered, show it again.
        if let live = tracker.active[key] {
            apply(AttentionChanges(raised: [live], cleared: []))
        }
    }

    private func setRun(_ key: AttentionKey, _ run: ActionRun?) {
        guard let index = entries.firstIndex(where: { $0.id == key }) else { return }
        entries[index].run = run
    }

    private func updateRun(_ key: AttentionKey, _ change: (inout ActionRun) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == key }), var run = entries[index].run else { return }
        change(&run)
        entries[index].run = run
    }

    private func announce(_ text: String) {
        guard isPanelOpen() else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    private static func pidMessage(_ group: ProcessGroup) -> String {
        let pids = group.pids.prefix(8).map(String.init).joined(separator: ", ") + (group.pids.count > 8 ? ", …" : "")
        return AppResources.formatted(
            "action.confirm.quit.message",
            fallback: "%1$@ (%2$@ processes). PIDs: %3$@. Unsaved work in them is lost.",
            group.name,
            group.count.formatted(),
            pids
        )
    }

    /// The live group behind a group action, re-read from the latest sample.
    private func liveGroup(for action: AllowedAction) -> ProcessGroup? {
        guard case let .group(path, name, _) = action.subject, let inputs = evidenceInputs() else { return nil }
        let groups = (inputs.processes?.topCPU ?? []) + (inputs.processes?.topMemory ?? [])
        return groups.first { group in
            (path.map { group.executablePath == $0 } ?? (group.executablePath == nil && group.name == name))
                && BriefEvidence.isQuittable(group, ownPath: inputs.ownExecutablePath)
        }
    }

    /// SysBar's current numbers for an item's rule.
    func reading(for key: AttentionKey) -> VerificationReading {
        guard let inputs = evidenceInputs() else { return VerificationReading() }
        let snapshot = inputs.snapshot
        var reading = VerificationReading()
        switch key.rule {
        case .runawayProcess:
            reading.subjectCPU = (inputs.processes?.topCPU ?? [])
                .first { ($0.executablePath ?? "name:\($0.name)") == key.subject }?
                .totalCPU
        case .hostCPU:
            let recent = snapshot.cpuHistory.suffix(3).filter(\.isFinite)
            reading.hostCPU = recent.isEmpty ? snapshot.cpu.value : recent.reduce(0, +) / Double(recent.count)
        case .memory:
            if let memory = snapshot.memory.value {
                reading.availableGB = Double(max(0, memory.freeMB)) / 1_024
                reading.totalGB = memory.totalGB
            }
        case .swapGrowth:
            reading.swapUsedMB = snapshot.swap.value.map { Double(max(0, $0.usedMB)) }
        case .disk:
            reading.diskFreeGB = snapshot.disk.value.flatMap(DiskPresentationPolicy.internalVolume(in:))?.freeGB
        case .newListener:
            reading.listenerOpen = snapshot.listenPorts.value.map { ports in
                ports.contains { AttentionTracker.subject(for: $0) == key.subject }
            }
        }
        return reading
    }

    // MARK: Review

    func runReview() {
        guard review != .running, provider != .off, let implementation = providers[provider],
              let inputs = evidenceInputs() else { return }
        if case let .ready(_, meta) = review,
           now().timeIntervalSince(meta.date) < Self.reviewReuse,
           reviewItemsSignature == entries.map(\.id) {
            return
        }
        review = .running
        reviewItemsSignature = entries.map(\.id)
        let evidence = BriefEvidence.make(
            BriefInputs(
                now: inputs.now,
                mac: inputs.mac,
                snapshot: inputs.snapshot,
                processes: inputs.processes,
                trigger: nil,
                activeItems: entries.map(\.item),
                appNames: inputs.appNames,
                listenerAppNames: inputs.listenerAppNames,
                ownExecutablePath: inputs.ownExecutablePath,
                frontmostAppPath: inputs.frontmostAppPath
            ),
            kind: "review"
        )
        let kind = provider
        reviewTask = Task { [weak self] in
            let state: ReviewState
            do {
                let call = AIBriefCall(
                    systemPrompt: BriefPrompt.system,
                    userMessage: BriefPrompt.review(evidenceJSON: try evidence.json()),
                    schema: BriefPrompt.reviewSchema
                )
                let result = try await implementation.run(call)
                let review = try BriefValidation.review(result.object, evidence: evidence)
                state = .ready(review, BriefMeta(provider: kind, model: result.modelLabel, seconds: result.durationSeconds, date: Date()))
            } catch let error as AIProviderError {
                state = .failed(error)
            } catch {
                state = .failed(.failed)
            }
            guard !Task.isCancelled else { return }
            self?.review = state
            self?.reviewTask = nil
        }
    }

    func setProvider(_ kind: AIProviderKind) {
        guard kind != provider || !hasStoredSelection else { return }
        defaults.set(kind.rawValue, forKey: AIProviderPolicy.selectionKey)
        let wasWatching = watchEnabled
        provider = kind
        review = .idle
        if wasWatching != watchEnabled { onWatchChange(watchEnabled) }
        for entry in entries where entry.brief == .providerOff || kind == .off {
            if kind == .off {
                tasks[entry.id]?.cancel()
                tasks[entry.id] = nil
                if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[index].brief = .providerOff
                    entries[index].plan = defaultPlan(for: entries[index].item)
                }
            } else {
                requestBrief(for: entry.id, automatic: false)
            }
        }
    }

    // MARK: Providers

    /// Detects and verifies both CLIs. Runs at launch and when the popover
    /// opens (at most every ten minutes), never on a timer while closed.
    func refreshProviders(force: Bool = false) {
        let date = now()
        guard probeTask == nil else { return }
        if !force, let last = lastProbeAt, date.timeIntervalSince(last) < 10 * 60 { return }
        lastProbeAt = date
        let claude = providers[.claude]
        let codex = providers[.codex]
        probeTask = Task { [weak self] in
            async let claudeStatus = claude?.status() ?? .notInstalled
            async let codexStatus = codex?.status() ?? .notInstalled
            let results = await (claudeStatus, codexStatus)
            self?.finishProbe(claude: results.0, codex: results.1)
        }
    }

    private func finishProbe(claude: AIProviderStatus, codex: AIProviderStatus) {
        probeTask = nil
        statuses = [.claude: claude, .codex: codex]
        if !hasStoredSelection {
            let kind = AIProviderPolicy.defaultKind(claude: claude, codex: codex)
            defaults.set(kind.rawValue, forKey: AIProviderPolicy.selectionKey)
            let wasWatching = watchEnabled
            provider = kind
            if wasWatching != watchEnabled { onWatchChange(watchEnabled) }
        }
    }

    var activeProviderStatus: AIProviderStatus? {
        provider == .off ? nil : statuses[provider]
    }

    // MARK: Persistence

    private func appendHistory(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        pruneExpired()
        save(history, key: Self.historyKey)
    }

    private func pruneExpired() {
        let date = now()
        history = Array(history.filter { date.timeIntervalSince($0.clearedAt) < Self.cacheLifetime }.prefix(Self.historyLimit))
        mutes = mutes.filter { $0.value.until > date }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

/// A user-facing app name for an executable: the outermost `.app` bundle's
/// display name, else the executable's file name. Cached per path.
@MainActor
enum AppDisplayName {
    private static var cache: [String: String] = [:]

    static func name(forExecutablePath path: String) -> String {
        if let cached = cache[path] { return cached }
        let name: String
        if let bundlePath = ProcessIconPath.bundlePath(containing: path) {
            let bundle = Bundle(path: bundlePath)
            name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        } else {
            name = (path as NSString).lastPathComponent
        }
        if cache.count > 256 { cache.removeAll() }
        cache[path] = name
        return name
    }
}

/// One attention notification and the buttons it carries. Only buttons that
/// need no confirmation and no context ride on a notification.
struct AttentionNotification: Equatable, Sendable {
    struct Action: Equatable, Sendable {
        let id: String
        let title: String
        let isDestructive: Bool
        let opensApp: Bool
    }

    let key: AttentionKey
    let title: String
    let body: String
    let actions: [Action]

    /// Stable per item, so a result notification replaces the original.
    var identifier: String { Self.identifier(for: key) }

    static let prefix = "attention|"

    static func identifier(for key: AttentionKey) -> String {
        "\(prefix)\(key.rule.rawValue)|\(key.subject)"
    }

    static func key(from identifier: String) -> AttentionKey? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let parts = identifier.dropFirst(prefix.count).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let rule = AttentionRule(rawValue: String(parts[0])) else { return nil }
        return AttentionKey(rule: rule, subject: String(parts[1]))
    }
}
