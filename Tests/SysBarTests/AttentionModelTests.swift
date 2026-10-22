import Foundation
import XCTest
@testable import SysBar

private actor FakeBriefProvider: BriefProviding {
    nonisolated let kind: AIProviderKind
    private(set) var calls = 0
    private let verdict: String
    private let picks: [(String, String?)]
    private let failure: AIProviderError?

    init(
        kind: AIProviderKind = .claude,
        verdict: String = "attention",
        picks: [(String, String?)] = [("restartApp", "p1"), ("openApp", "p1")],
        failure: AIProviderError? = nil
    ) {
        self.kind = kind
        self.verdict = verdict
        self.picks = picks
        self.failure = failure
    }

    func status() async -> AIProviderStatus { .ready(version: "1.0") }

    func run(_ call: AIBriefCall) async throws -> AIBriefResult {
        calls += 1
        if let failure { throw failure }
        let actions = picks.map { id, ref in
            "{\"id\":\"\(id)\",\"subjectRef\":\(ref.map { "\"\($0)\"" } ?? "null"),\"reason\":\"Reloads the Codex view.\"}"
        }.joined(separator: ",")
        let object = """
        {"verdict":"\(verdict)","headline":"Codex's renderer has been running hot","why":"It held 1.5 cores for 22 minutes.",
         "detail":"Nothing is streaming, so the work is wasted.","likelyCause":"A stuck render loop.","confidence":"medium",
         "actions":[\(actions)],"manualStep":null}
        """
        return AIBriefResult(object: Data(object.utf8), durationSeconds: 6.3, modelLabel: "Opus")
    }
}

@MainActor
private final class FakeAppController: RunningAppControlling {
    var running: [AppRef]
    var acceptsQuit = true
    var quitsOnRequest = true
    var opensSucceed = true
    var terminated: [String] = []
    var forceTerminated: [String] = []
    var activated: [String] = []
    var opened: [String] = []
    var onOpen: () -> Void = {}

    init(running: [AppRef]) {
        self.running = running
    }

    func apps() -> [AppRef] { running }

    func isRunning(_ app: AppRef) -> Bool { running.contains { $0.bundlePath == app.bundlePath } }

    func terminate(_ app: AppRef) -> Bool {
        terminated.append(app.bundlePath)
        guard acceptsQuit else { return false }
        if quitsOnRequest { running.removeAll { $0.bundlePath == app.bundlePath } }
        return true
    }

    func forceTerminate(_ app: AppRef) -> Bool {
        forceTerminated.append(app.bundlePath)
        running.removeAll { $0.bundlePath == app.bundlePath }
        return true
    }

    func activate(_ app: AppRef) -> Bool {
        activated.append(app.bundlePath)
        return true
    }

    func open(bundlePath: String) async -> Bool {
        opened.append(bundlePath)
        guard opensSucceed else { return false }
        running.append(AppRef(
            bundlePath: bundlePath, name: "ChatGPT", pid: 20_000, executablePath: bundlePath + "/Contents/MacOS/ChatGPT",
            bundleIdentifier: "com.openai.codex", isRegular: true, isFrontmost: false
        ))
        onOpen()
        return true
    }
}

@MainActor
private final class FakeSettingsOpener: SettingsOpening {
    var opened: [AttentionActionID] = []

    func open(_ action: AttentionActionID) -> Bool {
        opened.append(action)
        return true
    }
}

@MainActor
final class AttentionModelTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 3_000_000)
    private let path = "/Applications/ChatGPT.app/Contents/MacOS/Codex (Renderer)"
    private var rendererCPU = 156.0
    private var rendererPIDs: [Int32] = [7]
    private var ports: [ListenSocket] = []
    private var listenerPaths: [Int32: String] = [:]
    private var signals: [(ProcessSignal, [ProcessIdentity])] = []
    private var ownerChecks: [ProcessIdentity] = []

    private let chatGPT = AppRef(
        bundlePath: "/Applications/ChatGPT.app", name: "ChatGPT", pid: 15_209,
        executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        bundleIdentifier: "com.openai.codex", isRegular: true, isFrontmost: false
    )

    private struct Harness {
        let model: AttentionModel
        let notifications: Notifications
        let apps: FakeAppController
        let settings: FakeSettingsOpener
        let defaults: UserDefaults
    }

    private func makeModel(
        _ provider: FakeBriefProvider,
        kind: AIProviderKind = .claude,
        defaults existing: UserDefaults? = nil
    ) -> Harness {
        let defaults = existing ?? UserDefaults(suiteName: "AttentionModelTests-\(UUID().uuidString)")!
        defaults.set(kind.rawValue, forKey: AIProviderPolicy.selectionKey)
        let apps = FakeAppController(running: [chatGPT])
        let settings = FakeSettingsOpener()
        let model = AttentionModel(
            providers: [provider.kind: provider],
            defaults: defaults,
            apps: apps,
            settings: settings,
            sleep: { _ in await Task.yield() }
        ) { [unowned self] in self.clock }
        let notifications = Notifications()
        model.notify = { notifications.items.append($0) }
        model.signalProcesses = { [unowned self] signal, identities in
            self.signals.append((signal, identities))
            return ProcessActionReport(
                signal: signal,
                results: identities.map { ProcessActionMemberResult(identity: $0, outcome: .signaled) }
            )
        }
        model.evidenceInputs = { [unowned self] in
            var snapshot = PanelSnapshot.loading
            snapshot.cpu = .available(15, sampledAt: self.clock)
            snapshot.listenPorts = .available(self.ports, sampledAt: self.clock)
            snapshot.listenerExecutablePaths = self.listenerPaths
            return BriefInputs(
                now: self.clock,
                mac: BriefMachineFacts(chip: nil, cores: 18, ramGB: 64, macOS: "27", uptimeHours: 1, frontmostApp: nil),
                snapshot: snapshot,
                processes: ProcessOverview(topCPU: [self.renderer(cpu: self.rendererCPU)], topMemory: []),
                trigger: nil,
                activeItems: [],
                appNames: [:],
                listenerAppNames: [:],
                ownExecutablePath: nil,
                frontmostAppPath: nil
            )
        }
        return Harness(model: model, notifications: notifications, apps: apps, settings: settings, defaults: defaults)
    }

    final class Notifications {
        var items: [AttentionNotification] = []
    }

    private func renderer(cpu: Double) -> ProcessGroup {
        let identities = rendererPIDs.compactMap {
            ProcessIdentity(pid: $0, startTime: ProcessStartTime(seconds: 1_000, microseconds: 1), executablePath: path)
        }
        return ProcessGroup(id: .executablePath(path), name: "Codex (Renderer)", executablePath: path, pids: rendererPIDs,
                            expectedIdentities: identities, totalCPU: cpu, totalMemMB: 1_139)
    }

    /// Six minutes of samples at one per minute: enough to raise the runaway rule.
    private func runHot(_ model: AttentionModel, cpu: Double = 156) {
        for _ in 0...6 {
            model.ingestProcesses([renderer(cpu: cpu)], frontmostAppPath: nil, ownPath: nil, at: clock)
            clock.addTimeInterval(60)
        }
    }

    private func settle() async {
        for _ in 0..<400 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<200 { await Task.yield() }
    }

    private func action(_ id: AttentionActionID, in model: AttentionModel) throws -> AllowedAction {
        try XCTUnwrap(model.entries.first?.plan.buttons.map(\.allowed).first { $0.action == id })
    }

    // MARK: Briefs and notifications

    func testTheAIIsNeverInvokedWhileNoItemIsRaised() async {
        let provider = FakeBriefProvider()
        let model = makeModel(provider).model
        for _ in 0...10 {
            model.ingestProcesses([renderer(cpu: 40)], frontmostAppPath: nil, ownPath: nil, at: clock)
            model.ingestHost(cpuHistory: Array(repeating: 20, count: 60), memory: nil, swap: nil, at: clock)
            clock.addTimeInterval(60)
        }
        await settle()
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(model.hasAttention)
    }

    func testARaisedItemGetsOneBriefAndOneNotificationWhileThePopoverIsClosed() async {
        let provider = FakeBriefProvider()
        let harness = makeModel(provider)
        runHot(harness.model)
        await settle()
        runHot(harness.model)
        await settle()

        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(harness.model.attentionEntries.count, 1)
        guard case .ready = harness.model.entries.first?.brief else { return XCTFail("expected a ready brief") }
        XCTAssertEqual(harness.notifications.items.map(\.title), ["Codex's renderer has been running hot"])
        XCTAssertEqual(harness.notifications.items.first?.body, "It held 1.5 cores for 22 minutes.")
    }

    func testNotificationsCarryOnlyActionsThatNeedNoConfirmation() async {
        let harness = makeModel(FakeBriefProvider(picks: [("restartApp", "p1"), ("openApp", "p1")]))
        runHot(harness.model)
        await settle()
        let note = try? XCTUnwrap(harness.notifications.items.first)
        XCTAssertEqual(note?.actions.map(\.id), ["restartApp:p1", "openApp:p1", "snooze15:-"])
        XCTAssertEqual(note?.actions.map(\.title), ["Restart ChatGPT", "Open ChatGPT", "Remind me in 15 min"])
        XCTAssertEqual(note.flatMap { AttentionNotification.key(from: $0.identifier) }, harness.model.entries.first?.id)

        rendererPIDs = [7, 8, 9]
        let quitting = makeModel(FakeBriefProvider(picks: [("quitProcesses", "p1")]))
        runHot(quitting.model)
        await settle()
        XCTAssertEqual(quitting.model.entries.first?.plan.buttons.first?.allowed.action, .quitProcesses)
        XCTAssertEqual(quitting.notifications.items.first?.actions.map(\.id), ["snooze15:-"])
    }

    func testAnExpectedVerdictDemotesTheItemAndSuppressesTheNotification() async {
        let harness = makeModel(FakeBriefProvider(verdict: "expected"))
        runHot(harness.model)
        await settle()
        XCTAssertEqual(harness.model.entries.count, 1)
        XCTAssertFalse(harness.model.hasAttention)
        XCTAssertTrue(harness.model.entries[0].plan.buttons.allSatisfy { !$0.allowed.action.isDestructive })
        XCTAssertTrue(harness.notifications.items.isEmpty)
    }

    func testAFailedBriefStillNotifiesWithTheMeasuredFactAndSysBarsOwnButtons() async {
        let harness = makeModel(FakeBriefProvider(failure: .timedOut))
        runHot(harness.model)
        await settle()
        XCTAssertEqual(harness.notifications.items.first?.title.hasPrefix("Codex (Renderer) has used 156% CPU for"), true)
        XCTAssertTrue(harness.model.hasAttention)
        XCTAssertEqual(harness.model.entries.first?.plan.buttons.map(\.allowed.action), [.restartApp, .openApp])
    }

    func testNoNotificationIsSentWhileThePopoverIsOpen() async {
        let harness = makeModel(FakeBriefProvider())
        harness.model.isPanelOpen = { true }
        runHot(harness.model)
        await settle()
        XCTAssertTrue(harness.notifications.items.isEmpty)
    }

    func testDismissedItemsStopCountingButStayVisibleUntilTheyClear() async {
        let model = makeModel(FakeBriefProvider()).model
        runHot(model)
        await settle()
        model.dismiss(model.entries[0].id)
        XCTAssertFalse(model.hasAttention)
        XCTAssertEqual(model.entries.count, 1)
    }

    func testMutedSubjectsNeverRaiseUntilMidnight() async {
        let model = makeModel(FakeBriefProvider()).model
        runHot(model)
        await settle()
        model.muteToday(model.entries[0].id)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.isMuted(path, at: clock))
        XCTAssertFalse(model.isMuted(path, at: Calendar.current.startOfDay(for: clock).addingTimeInterval(86_401)))
    }

    func testAutomaticBriefsAreCappedAtSixPerHour() async {
        let provider = FakeBriefProvider()
        let model = makeModel(provider).model
        for index in 0..<8 {
            let listener = ListenSocket(pid: Int32(100 + index), processName: "srv\(index)", port: UInt16(3_000 + index), bindAddress: "*", isTCP: true)
            if index == 0 { model.ingestListeners([], trusted: [], names: [:], at: clock) }
            model.ingestListeners([listener], trusted: [], names: [:], at: clock)
            clock.addTimeInterval(60)
        }
        await settle()
        let calls = await provider.calls
        XCTAssertEqual(calls, AttentionModel.maxCallsPerHour)
        XCTAssertTrue(model.entries.contains { $0.brief == .paused })
    }

    func testTurningTheProviderOffNeverCallsTheAIButKeepsTheItemAndItsButtons() async {
        let provider = FakeBriefProvider()
        let model = makeModel(provider, kind: .off).model
        runHot(model)
        await settle()
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.entries.first?.brief, .providerOff)
        XCTAssertTrue(model.hasAttention, "turning AI off never turns the watching off")
        XCTAssertEqual(model.entries.first?.plan.buttons.map(\.allowed.action), [.restartApp, .openApp])
    }

    func testClearedItemsMoveToTheTwentyFourHourHistory() async {
        let model = makeModel(FakeBriefProvider()).model
        runHot(model)
        await settle()
        for _ in 0...3 {
            model.ingestProcesses([], frontmostAppPath: nil, ownPath: nil, at: clock)
            clock.addTimeInterval(60)
        }
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(model.history.first?.headline, "Codex's renderer has been running hot")
        XCTAssertNil(model.history.first?.resolution)
    }

    // MARK: Actions

    func testRestartWaitsForTheAppToExitThenReopensItFromTheBundleLocationCapturedBeforeTheQuit() async throws {
        let harness = makeModel(FakeBriefProvider())
        runHot(harness.model)
        await settle()
        harness.apps.onOpen = { [unowned self] in self.rendererCPU = 3 }

        harness.model.perform(try action(.restartApp, in: harness.model), for: harness.model.entries[0].id)
        XCTAssertEqual(harness.model.entries.first?.run?.phase, .running)
        await settle()

        XCTAssertEqual(harness.apps.terminated, ["/Applications/ChatGPT.app"])
        XCTAssertEqual(harness.apps.opened, ["/Applications/ChatGPT.app"])
        XCTAssertTrue(harness.apps.forceTerminated.isEmpty)
        XCTAssertNil(harness.model.pendingConfirmation, "an app-level restart never asks first")
    }

    func testAVerifiedFixClearsTheItemImmediatelyAndRecordsTheActionInHistory() async throws {
        let harness = makeModel(FakeBriefProvider())
        runHot(harness.model)
        await settle()
        var resampled = 0
        harness.model.resample = { _ in resampled += 1 }
        harness.apps.onOpen = { [unowned self] in self.rendererCPU = 3 }

        harness.model.perform(try action(.restartApp, in: harness.model), for: harness.model.entries[0].id)
        await settle()

        XCTAssertFalse(harness.model.hasAttention)
        XCTAssertTrue(harness.model.entries.isEmpty, "the result lingers briefly, then the card goes")
        XCTAssertEqual(harness.model.history.first?.resolution, "Restart ChatGPT")
        XCTAssertGreaterThan(resampled, 0)
        XCTAssertEqual(harness.notifications.items.last?.title, "Done · Codex (Renderer) back to 3% · ChatGPT reopened")
    }

    func testAnUnverifiedFixKeepsTheItemAndOffersForceQuit() async throws {
        let harness = makeModel(FakeBriefProvider())
        runHot(harness.model)
        await settle()

        harness.model.perform(try action(.restartApp, in: harness.model), for: harness.model.entries[0].id)
        await settle()

        let run = try XCTUnwrap(harness.model.entries.first?.run)
        XCTAssertEqual(run.phase, .failed)
        XCTAssertTrue(run.line.hasPrefix("Still at 156% after"), run.line)
        XCTAssertEqual(run.followUps.map(\.action), [.forceQuit])
        XCTAssertTrue(harness.model.hasAttention)
        XCTAssertTrue(harness.apps.forceTerminated.isEmpty, "Force Quit is offered, never done")
    }

    func testRestartEscalatesToForceQuitOnlyAfterTheAppIgnoresQuitAndForceQuitAlwaysConfirms() async throws {
        let harness = makeModel(FakeBriefProvider())
        harness.apps.quitsOnRequest = false
        runHot(harness.model)
        await settle()
        let key = harness.model.entries[0].id

        harness.model.perform(try action(.restartApp, in: harness.model), for: key)
        await settle()

        let run = try XCTUnwrap(harness.model.entries.first?.run)
        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.line, "ChatGPT is still running — it may be asking you to save.")
        XCTAssertEqual(run.followUps.map(\.action), [.openApp, .forceQuit])
        XCTAssertTrue(harness.apps.opened.isEmpty)

        harness.model.perform(run.followUps[1], for: key)
        XCTAssertEqual(harness.model.pendingConfirmation?.title, "Force Quit ChatGPT?")
        XCTAssertTrue(harness.apps.forceTerminated.isEmpty)
        harness.model.confirmPending()
        XCTAssertEqual(harness.apps.forceTerminated, ["/Applications/ChatGPT.app"])
    }

    func testQuittingMoreThanOneProcessAsksForConfirmationButQuittingAnAppDoesNot() async throws {
        rendererPIDs = [7, 8, 9]
        let harness = makeModel(FakeBriefProvider(picks: [("quitProcesses", "p1"), ("openApp", "p1")]))
        runHot(harness.model)
        await settle()
        let key = harness.model.entries[0].id

        harness.model.perform(try action(.quitProcesses, in: harness.model), for: key)
        XCTAssertEqual(harness.model.pendingConfirmation?.title, "Quit Codex (Renderer)?")
        XCTAssertTrue(signals.isEmpty)
        harness.model.confirmPending()
        await settle()
        XCTAssertEqual(signals.first?.0, .terminate)
        XCTAssertEqual(signals.first?.1.map(\.pid), [7, 8, 9])
    }

    func testAnAppThatIsNoLongerRunningAtClickTimeSignalsNothing() async throws {
        let harness = makeModel(FakeBriefProvider())
        runHot(harness.model)
        await settle()
        harness.apps.running = []

        harness.model.perform(try action(.restartApp, in: harness.model), for: harness.model.entries[0].id)
        await settle()

        XCTAssertTrue(harness.apps.terminated.isEmpty)
        XCTAssertEqual(harness.model.entries.first?.run?.line, "ChatGPT is no longer running")
    }

    func testOpeningAnAppClosesThePopoverAndNeverSignalsAnything() async throws {
        let harness = makeModel(FakeBriefProvider())
        var closed = 0
        harness.model.closePopover = { closed += 1 }
        runHot(harness.model)
        await settle()

        harness.model.perform(try action(.openApp, in: harness.model), for: harness.model.entries[0].id)

        XCTAssertEqual(harness.apps.activated, ["/Applications/ChatGPT.app"])
        XCTAssertEqual(closed, 1)
        XCTAssertTrue(harness.apps.terminated.isEmpty)
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(harness.model.hasAttention, "looking at it fixes nothing by itself")
    }

    func testANotificationButtonRunsTheSameActionAsTheCardAndAConfirmingOneOpensThePopoverInstead() async {
        let harness = makeModel(FakeBriefProvider())
        runHot(harness.model)
        await settle()
        let key = harness.model.entries[0].id

        harness.model.performNotificationAction("restartApp:p1", for: key)
        XCTAssertEqual(harness.apps.terminated, ["/Applications/ChatGPT.app"])
        await settle()

        rendererPIDs = [7, 8, 9]
        let other = makeModel(FakeBriefProvider(picks: [("quitProcesses", "p1")]))
        var revealed: [AttentionKey] = []
        other.model.revealRequest = { revealed.append($0) }
        runHot(other.model)
        await settle()
        other.model.performNotificationAction("quitProcesses:p1", for: other.model.entries[0].id)
        XCTAssertEqual(revealed, [other.model.entries[0].id])
        XCTAssertNil(other.model.pendingConfirmation)
        XCTAssertTrue(signals.isEmpty)
    }

    func testSnoozeHidesTheItemForFifteenMinutesAndRemindsOnceIfItIsStillActive() async {
        let harness = makeModel(FakeBriefProvider())
        runHot(harness.model)
        await settle()
        let sent = harness.notifications.items.count

        harness.model.snooze(harness.model.entries[0].id)
        XCTAssertFalse(harness.model.hasAttention)
        for _ in 0..<10 {
            harness.model.ingestProcesses([renderer(cpu: 156)], frontmostAppPath: nil, ownPath: nil, at: clock)
            clock.addTimeInterval(60)
        }
        XCTAssertFalse(harness.model.hasAttention, "still snoozed after ten minutes")
        for _ in 0..<6 {
            harness.model.ingestProcesses([renderer(cpu: 156)], frontmostAppPath: nil, ownPath: nil, at: clock)
            clock.addTimeInterval(60)
        }
        XCTAssertTrue(harness.model.hasAttention)
        XCTAssertEqual(harness.notifications.items.count, sent + 1)
        XCTAssertEqual(harness.notifications.items.last?.title.hasPrefix("Still: Codex (Renderer) has used"), true)
    }

    func testAllowingAListenerStopsItRaisingAndSurvivesRelaunch() async throws {
        let node = ListenSocket(pid: 812, processName: "node", port: 3_000, bindAddress: "*", isTCP: true)
        ports = [node]
        let harness = makeModel(FakeBriefProvider(verdict: "unsure", picks: [("allowListener", "l1")]))
        harness.model.ingestListeners([], trusted: [], names: [:], at: clock)
        harness.model.ingestListeners([node], trusted: [], names: [:], at: clock)
        await settle()
        let allow = try action(.allowListener, in: harness.model)
        XCTAssertEqual(ActionLabel.title(allow), "Allow node on 3000")

        harness.model.perform(allow, for: harness.model.entries[0].id)
        XCTAssertFalse(harness.model.hasAttention)
        await settle()
        XCTAssertTrue(harness.model.entries.isEmpty)

        let relaunched = makeModel(FakeBriefProvider(), defaults: harness.defaults)
        relaunched.model.ingestListeners([], trusted: [], names: [:], at: clock)
        relaunched.model.ingestListeners([node], trusted: [], names: [:], at: clock)
        XCTAssertTrue(relaunched.model.entries.isEmpty)
        XCTAssertEqual(relaunched.model.allowedListeners.values.map(\.port), [3_000])
    }

    func testStorageSettingsOpensThePaneWithoutClaimingTheDiskIsFixed() async throws {
        let harness = makeModel(FakeBriefProvider(picks: []))
        harness.model.ingestDisk(freeGB: 30, totalGB: 1_800, at: clock)
        await settle()
        let open = try action(.openStorageSettings, in: harness.model)

        harness.model.perform(open, for: harness.model.entries[0].id)

        XCTAssertEqual(harness.settings.opened, [.openStorageSettings])
        XCTAssertEqual(harness.model.entries.first?.run?.phase, .info)
        XCTAssertTrue(harness.model.hasAttention)
    }

    // MARK: Stopping a listener (ADR-023)

    private let nodeSocket = ListenSocket(pid: 812, processName: "node", port: 3_000, bindAddress: "*", isTCP: true)

    /// `/opt/homebrew/bin/node` starts accepting LAN connections on *:3000.
    private func raiseNodeListener() async -> Harness {
        ports = [nodeSocket]
        listenerPaths = [812: ListenerStopTests.nodePath]
        let harness = makeModel(FakeBriefProvider(picks: []))
        harness.model.resolveIdentity = { $0 == 812 ? ListenerStopTests.node() : nil }
        harness.model.checkListenerOwner = { [unowned self] _, identity in
            self.ownerChecks.append(identity)
            return .confirmed
        }
        harness.model.ingestListeners([], trusted: [], names: [:], at: clock)
        harness.model.ingestListeners([nodeSocket], trusted: [], names: [:], at: clock)
        await settle()
        return harness
    }

    func testStoppingACommandLineListenerAlwaysAsksFirstThenSignalsOnlyTheConfirmedInstance() async throws {
        let harness = await raiseNodeListener()
        let key = harness.model.entries[0].id
        XCTAssertEqual(harness.model.entries[0].plan.buttons.map(\.allowed.action), [.stopListener, .allowListener])
        XCTAssertFalse(harness.notifications.items.flatMap(\.actions).contains { $0.id.hasPrefix("stopListener") })
        let stop = try action(.stopListener, in: harness.model)

        var revealed: [AttentionKey] = []
        harness.model.revealRequest = { revealed.append($0) }
        harness.model.performNotificationAction(stop.id, for: key)
        XCTAssertEqual(revealed, [key], "from a notification, Stop only opens the popover")
        XCTAssertNil(harness.model.pendingConfirmation)

        harness.model.perform(stop, for: key)
        let confirmation = try XCTUnwrap(harness.model.pendingConfirmation)
        XCTAssertEqual(confirmation.title, "Stop node?")
        XCTAssertEqual(confirmation.confirmTitle, "Stop")
        XCTAssertTrue(confirmation.message.contains("PID 812, /opt/homebrew/bin/node"), confirmation.message)
        XCTAssertTrue(confirmation.message.contains("*:3000"), confirmation.message)
        harness.model.cancelPending()
        await settle()
        XCTAssertTrue(signals.isEmpty, "nothing is signaled unless the owner confirms")
        XCTAssertTrue(ownerChecks.isEmpty, "nothing is re-scanned unless the owner confirms")

        harness.model.perform(stop, for: key)
        ports = []
        harness.model.confirmPending()
        await settle()

        XCTAssertEqual(ownerChecks, [ListenerStopTests.node()])
        XCTAssertEqual(signals.map(\.0), [.terminate])
        XCTAssertEqual(signals.first?.1, [ListenerStopTests.node()])
        XCTAssertTrue(harness.model.entries.isEmpty)
        XCTAssertEqual(harness.model.history.first?.resolution, "Stop node…")
        XCTAssertEqual(harness.notifications.items.last?.title, "Done · port 3000 closed")
    }

    func testStopIsRefusedWithoutASignalWhenThePortNowBelongsToADifferentProcess() async throws {
        let harness = await raiseNodeListener()
        var slowResamples = 0
        harness.model.resample = { if $0 { slowResamples += 1 } }
        harness.model.checkListenerOwner = { _, _ in .otherOwner }

        harness.model.perform(try action(.stopListener, in: harness.model), for: harness.model.entries[0].id)
        harness.model.confirmPending()
        await settle()

        let run = try XCTUnwrap(harness.model.entries.first?.run)
        XCTAssertEqual(run.phase, .failed)
        XCTAssertEqual(run.line, "Port 3000 now belongs to another process; nothing was stopped.")
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(harness.model.hasAttention)
        XCTAssertEqual(slowResamples, 1, "the card is refreshed from a new scan")
    }

    func testARecycledPIDIsNeverSignaledWhetherItIsReplacedBeforeOrAfterTheRescan() async throws {
        for moment in ["never", "beforeRescan", "afterRescan"] {
            let harness = await raiseNodeListener()
            let reader = FixedIdentityReader(ListenerStopTests.node())
            let sender = SignalRecorder()
            let service = ProcessActionService(identityReader: reader, signalSender: sender, selfPID: 99_999)
            let scan = ListenerScanStub.listening(pid: 812, name: "node", endpoint: "*:3000")
            let recycled = ListenerStopTests.node(startedAt: 2_000)
            harness.model.checkListenerOwner = { target, identity in
                if moment == "beforeRescan" { reader.replace(with: recycled) }
                let ownership = PortsAPI.ownership(of: target, expected: identity, runner: scan, reader: reader, timeout: 1)
                if moment == "afterRescan" { reader.replace(with: recycled) }
                return ownership
            }
            harness.model.signalProcesses = { signal, identities in await service.perform(signal, on: identities) }

            harness.model.perform(try action(.stopListener, in: harness.model), for: harness.model.entries[0].id)
            harness.model.confirmPending()
            await settle()

            XCTAssertEqual(scan.runs, 1, moment)
            if moment == "never" {
                XCTAssertEqual(sender.pids, [812], "the confirmed, still-owning instance is signaled")
            } else {
                XCTAssertTrue(sender.pids.isEmpty, "recycled \(moment): no signal")
                XCTAssertEqual(harness.model.entries.first?.run?.line, "A process changed; no signal was sent to it.", moment)
            }
        }
    }

    func testAStopWhoseProcessChangedOrExitedSinceTheScanIsRefusedBeforeAsking() async throws {
        let harness = await raiseNodeListener()
        let key = harness.model.entries[0].id
        let stop = try action(.stopListener, in: harness.model)

        harness.model.resolveIdentity = { _ in ListenerStopTests.node(path: "/tmp/node") }
        harness.model.perform(stop, for: key)
        XCTAssertNil(harness.model.pendingConfirmation)
        XCTAssertEqual(harness.model.entries.first?.run?.line, "A process changed; no signal was sent to it.")

        harness.model.clearRun(key)
        harness.model.resolveIdentity = { _ in nil }
        harness.model.perform(stop, for: key)
        XCTAssertNil(harness.model.pendingConfirmation)
        XCTAssertEqual(harness.model.entries.first?.run?.line, "node is no longer running")
        await settle()
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(ownerChecks.isEmpty)
    }

    func testAllowingFromTheNetworkSectionPersistsAndResolvesARaisedCardForThatListener() async throws {
        let harness = await raiseNodeListener()
        XCTAssertTrue(harness.model.hasAttention)

        harness.model.allow(nodeSocket)
        XCTAssertFalse(harness.model.hasAttention)
        XCTAssertEqual(harness.model.history.first?.resolution, "Allow node on 3000")
        XCTAssertEqual(harness.model.allowedListeners.values.map(\.port), [3_000])

        let other = ListenSocket(pid: 900, processName: "python3", port: 8_000, bindAddress: "*", isTCP: true)
        harness.model.allow(other)
        XCTAssertEqual(Set(harness.model.allowedListeners.values.map(\.port)), [3_000, 8_000])
        XCTAssertTrue(signals.isEmpty)
    }
}
