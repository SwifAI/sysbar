import XCTest
@testable import SysBar

final class AttentionActionsTests: XCTestCase {
    private let chatGPT = AppRef(
        bundlePath: "/Applications/ChatGPT.app", name: "ChatGPT", pid: 15_209,
        executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        bundleIdentifier: "com.openai.codex", isRegular: true, isFrontmost: false
    )
    private let renderer = "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)"

    private func group(_ name: String, path: String?, pids: [Int32] = [42]) -> ProcessGroup {
        let identities = pids.compactMap { pid in
            path.flatMap { ProcessIdentity(pid: pid, startTime: ProcessStartTime(seconds: 1, microseconds: 1), executablePath: $0) }
        }
        return ProcessGroup(
            id: path.map(ProcessGroupID.executablePath) ?? .executablePath(name),
            name: name, executablePath: path, pids: pids,
            expectedIdentities: identities, totalCPU: 150, totalMemMB: 900
        )
    }

    private func allowed(
        _ rule: AttentionRule,
        groups: [ProcessGroup] = [],
        listeners: [(ListenSocket, String?)] = [],
        apps: [AppRef]? = nil
    ) -> [AllowedAction] {
        ActionCatalog.allowed(
            rule: rule,
            groups: groups.enumerated().map { (ref: "p\($0 + 1)", group: $1) },
            apps: [],
            listeners: listeners.enumerated().map { (ref: "l\($0 + 1)", port: $1.0, path: $1.1) },
            triggerListenerRef: listeners.isEmpty ? nil : "l1",
            runningApps: apps ?? [chatGPT],
            ownPath: "/Applications/SysBar.app/Contents/MacOS/SysBar"
        )
    }

    private func defaults(_ rule: AttentionRule, _ allowed: [AllowedAction], trigger: String? = "p1") -> [AttentionActionID] {
        ActionPlanner.plan(
            picks: [], verdict: nil, rule: rule, triggerRef: trigger,
            topCPURefs: ["p1"], topMemoryRefs: ["p1"], allowed: allowed
        ).buttons.map(\.allowed.action)
    }

    func testAHelperResolvesToItsOwningAppByBundleLocationNotByPIDOrBundleIdentifier() {
        let impostor = AppRef(
            bundlePath: "/Applications/Other.app", name: "Other", pid: 15_209, executablePath: nil,
            bundleIdentifier: "com.openai.codex", isRegular: true, isFrontmost: false
        )
        XCTAssertEqual(SubjectResolver.kind(executablePath: renderer, ownPath: nil, apps: [impostor, chatGPT]), .helperOf(chatGPT))
        XCTAssertEqual(SubjectResolver.kind(executablePath: chatGPT.executablePath, ownPath: nil, apps: [chatGPT]), .app(chatGPT))
    }

    func testACommandLineProcessGetsQuitAndNeverRestartBecauseItCannotBeRelaunched() {
        let node = group("node", path: "/opt/homebrew/bin/node")
        XCTAssertEqual(SubjectResolver.kind(executablePath: node.executablePath, ownPath: nil, apps: [chatGPT]), .commandLine)
        XCTAssertEqual(defaults(.runawayProcess, allowed(.runawayProcess, groups: [node])), [.quitProcesses, .snooze15])
    }

    func testAToolInsideAnAppBundleThatIsNotRunningIsTreatedLikeACommandLineTool() {
        let path = "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude"
        XCTAssertEqual(SubjectResolver.kind(executablePath: path, ownPath: nil, apps: [chatGPT]), .bundledTool)
        XCTAssertFalse(allowed(.runawayProcess, groups: [group("claude", path: path)]).contains { $0.action == .restartApp })
    }

    func testSystemProcessesAndSysBarItselfAreNeverOfferedADestructiveAction() {
        let windowServer = group("WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
        let sysBar = group("SysBar", path: "/Applications/SysBar.app/Contents/MacOS/SysBar")
        let actions = allowed(.runawayProcess, groups: [windowServer, sysBar])
        XCTAssertEqual(actions.map(\.action), [.snooze15])
        XCTAssertEqual(defaults(.runawayProcess, actions), [.snooze15])
    }

    func testEveryRuleProducesAtLeastOneButtonWithoutAnyAI() {
        for rule in AttentionRule.allCases {
            XCTAssertFalse(defaults(rule, allowed(rule)).isEmpty, "\(rule)")
        }
    }

    func testTheRunawayRuleDefaultsToRestartingTheOwningAppAndOpeningIt() {
        let actions = allowed(.runawayProcess, groups: [group("Codex (Renderer)", path: renderer)])
        XCTAssertEqual(defaults(.runawayProcess, actions), [.restartApp, .openApp])
        XCTAssertEqual(actions.first.map(ActionLabel.title), "Restart ChatGPT")
    }

    func testTheDiskRuleDefaultsToStorageSettingsAndAListenerWithNoKnownExecutableToAllow() {
        XCTAssertEqual(defaults(.disk, allowed(.disk)), [.openStorageSettings, .snooze15])
        let node = ListenSocket(pid: 812, processName: "node", port: 3_000, bindAddress: "*", isTCP: true)
        XCTAssertEqual(
            defaults(.newListener, allowed(.newListener, listeners: [(node, nil)]), trigger: "l1"),
            [.allowListener, .snooze15]
        )
    }

    func testACommandLineListenerIsOfferedAStopThatAlwaysConfirmsAndDefaultsAheadOfAllow() throws {
        let node = ListenSocket(pid: 812, processName: "node", port: 3_000, bindAddress: "*", isTCP: true)
        let actions = allowed(.newListener, listeners: [(node, "/opt/homebrew/bin/node")])
        let stop = try XCTUnwrap(actions.first { $0.action == .stopListener })

        XCTAssertTrue(stop.confirms)
        XCTAssertEqual(stop.ref, "l1")
        XCTAssertEqual(ActionLabel.title(stop), "Stop node…")
        XCTAssertEqual(stop.subject, .listenerProcess(ListenerStopTarget(port: node, executablePath: "/opt/homebrew/bin/node")))
        XCTAssertEqual(defaults(.newListener, actions, trigger: "l1"), [.stopListener, .allowListener])
        XCTAssertTrue(AttentionActionID.aiSelectable.contains(.stopListener))
        XCTAssertTrue(AttentionActionID.stopListener.isDestructive)
        XCTAssertFalse(AttentionActionID.stopListener.isNotificationSafe, "a confirming action never rides on a notification")

        let bundled = "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude"
        let tool = ListenSocket(pid: 900, processName: "claude", port: 8_123, bindAddress: "*", isTCP: true)
        XCTAssertTrue(allowed(.newListener, listeners: [(tool, bundled)]).contains { $0.action == .stopListener })
    }

    func testStopIsNeverOfferedForAListenerInsideARunningAppUnderASystemPathOrInSysBarItself() {
        let helper = ListenSocket(pid: 77, processName: "ChatGPT", port: 9_000, bindAddress: "*", isTCP: true)
        let daemon = ListenSocket(pid: 90, processName: "smbd", port: 445, bindAddress: "*", isTCP: true)
        let sysBar = ListenSocket(pid: 91, processName: "SysBar", port: 9_999, bindAddress: "*", isTCP: true)
        let unknown = ListenSocket(pid: 92, processName: "mystery", port: 7_000, bindAddress: "*", isTCP: true)
        for (socket, path) in [
            (helper, chatGPT.executablePath),
            (daemon, "/usr/sbin/smbd"),
            (sysBar, "/Applications/SysBar.app/Contents/MacOS/SysBar"),
            (unknown, nil)
        ] as [(ListenSocket, String?)] {
            XCTAssertFalse(allowed(.newListener, listeners: [(socket, path)]).contains { $0.action == .stopListener }, socket.processName)
        }
    }

    func testOnlyTheTriggeringListenerCanBeStoppedAndAnExpectedVerdictNeverOffersStop() {
        let node = ListenSocket(pid: 812, processName: "node", port: 3_000, bindAddress: "*", isTCP: true)
        let python = ListenSocket(pid: 813, processName: "python3", port: 8_000, bindAddress: "*", isTCP: true)
        let actions = allowed(.newListener, listeners: [(node, "/opt/homebrew/bin/node"), (python, "/opt/homebrew/bin/python3")])
        XCTAssertEqual(actions.filter { $0.action == .stopListener }.map(\.ref), ["l1"])

        let expected = ActionPlanner.plan(
            picks: [ActionPick(id: "stopListener", subjectRef: "l1", reason: "")],
            verdict: .expected, rule: .newListener, triggerRef: "l1",
            topCPURefs: [], topMemoryRefs: [], allowed: actions
        )
        XCTAssertEqual(expected.buttons.map(\.allowed.action), [.allowListener])

        let unsure = ActionPlanner.plan(
            picks: [
                ActionPick(id: "stopListener", subjectRef: "l1", reason: ""),
                ActionPick(id: "allowListener", subjectRef: "l1", reason: "")
            ],
            verdict: .unsure, rule: .newListener, triggerRef: "l1",
            topCPURefs: [], topMemoryRefs: [], allowed: actions
        )
        XCTAssertEqual(unsure.buttons.map(\.allowed.action), [.allowListener, .stopListener])

        let wrongRef = ActionPlanner.plan(
            picks: [ActionPick(id: "stopListener", subjectRef: "l2", reason: "")],
            verdict: .attention, rule: .newListener, triggerRef: "l1",
            topCPURefs: [], topMemoryRefs: [], allowed: actions
        )
        XCTAssertEqual(wrongRef.droppedPicks, 1)
    }

    func testAnAppleListenerOutsideTheAllowlistGetsOpenSharingSettings() {
        let daemon = ListenSocket(pid: 90, processName: "smbd", port: 445, bindAddress: "*", isTCP: true)
        let actions = allowed(.newListener, listeners: [(daemon, "/usr/sbin/smbd")])
        XCTAssertEqual(defaults(.newListener, actions, trigger: "l1"), [.openSharingSettings, .allowListener])
    }

    func testAListenerUnderUsrLocalIsOfferedStopAndNotSharingSettingsBecauseSIPLeavesUsrLocalToTheOwner() {
        let node = ListenSocket(pid: 812, processName: "node", port: 3_000, bindAddress: "*", isTCP: true)
        let actions = allowed(.newListener, listeners: [(node, "/usr/local/bin/node")])

        XCTAssertEqual(SubjectResolver.kind(executablePath: "/usr/local/bin/node", ownPath: nil, apps: [chatGPT]), .commandLine)
        XCTAssertFalse(actions.contains { $0.action == .openSharingSettings })
        XCTAssertEqual(defaults(.newListener, actions, trigger: "l1"), [.stopListener, .allowListener])
    }

    func testTheRestOfUsrStaysProtectedSoAnAppleDaemonGetsSharingSettingsAndNoStop() {
        let daemon = ListenSocket(pid: 90, processName: "smbd", port: 445, bindAddress: "*", isTCP: true)
        for path in [
            "/usr/sbin/smbd",
            "/usr/libexec/smbd",
            "/usr/bin/smbd",
            "/usr/localized/smbd",
            "/usr/local/../sbin/smbd",
            "/usr/local/bin/../../sbin/smbd"
        ] {
            let actions = allowed(.newListener, listeners: [(daemon, path)])
            XCTAssertEqual(SubjectResolver.kind(executablePath: path, ownPath: nil, apps: [chatGPT]), .system, path)
            XCTAssertFalse(actions.contains { $0.action == .stopListener }, path)
            XCTAssertEqual(defaults(.newListener, actions, trigger: "l1"), [.openSharingSettings, .allowListener], path)
        }
    }

    func testARunawayProcessUnderUsrLocalCanBeQuitButOneUnderUsrBinCannot() {
        let node = group("node", path: "/usr/local/bin/node")
        let python = group("python3", path: "/usr/bin/python3")

        XCTAssertEqual(defaults(.runawayProcess, allowed(.runawayProcess, groups: [node])), [.quitProcesses, .snooze15])
        XCTAssertEqual(defaults(.runawayProcess, allowed(.runawayProcess, groups: [python])), [.snooze15])
    }

    func testTheBriefsQuittableFlagAndTheActionCatalogAgreeOnWhichPathsAreProtected() {
        for path in [
            "/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/python3", "/usr/sbin/smbd",
            "/usr/libexec/rapportd", "/bin/zsh", "/sbin/launchd", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect", "/usr/local/../sbin/smbd"
        ] {
            let quittable = BriefEvidence.isQuittable(group("tool", path: path), ownPath: nil)
            XCTAssertEqual(quittable, !SubjectResolver.isProtected(path), path)
            XCTAssertEqual(quittable, SubjectResolver.kind(executablePath: path, ownPath: nil, apps: []) != .system, path)
        }
    }

    func testAListenerInsideARunningAppDefaultsToQuittingThatApp() {
        let helper = ListenSocket(pid: 77, processName: "ChatGPT", port: 9_000, bindAddress: "*", isTCP: true)
        let actions = allowed(.newListener, listeners: [(helper, chatGPT.executablePath)])
        XCTAssertEqual(defaults(.newListener, actions, trigger: "l1"), [.quitApp, .allowListener])
    }

    func testMemoryWithNothingAttributableOnlyOffersARemindLater() {
        let webContent = group("com.apple.WebKit.WebContent", path: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent")
        XCTAssertEqual(defaults(.memory, allowed(.memory, groups: [webContent])), [.snooze15])
    }

    func testForceQuitIsNeverOfferedToTheAIOrPlannedAsAFirstClick() {
        XCTAssertFalse(AttentionActionID.aiSelectable.contains(.forceQuit))
        let actions = allowed(.runawayProcess, groups: [group("Codex (Renderer)", path: renderer)])
        let plan = ActionPlanner.plan(
            picks: [ActionPick(id: "forceQuit", subjectRef: "p1", reason: "")],
            verdict: .attention, rule: .runawayProcess, triggerRef: "p1",
            topCPURefs: ["p1"], topMemoryRefs: [], allowed: actions
        )
        XCTAssertFalse(plan.buttons.contains { $0.allowed.action == .forceQuit })
        XCTAssertEqual(plan.droppedPicks, 1)
    }

    func testAnUnsureVerdictPutsTheNonDestructiveButtonFirst() {
        let actions = allowed(.runawayProcess, groups: [group("Codex (Renderer)", path: renderer)])
        let plan = ActionPlanner.plan(
            picks: [ActionPick(id: "quitApp", subjectRef: "p1", reason: "Quit"), ActionPick(id: "openApp", subjectRef: "p1", reason: "Look")],
            verdict: .unsure, rule: .runawayProcess, triggerRef: "p1",
            topCPURefs: ["p1"], topMemoryRefs: [], allowed: actions
        )
        XCTAssertEqual(plan.buttons.map(\.allowed.action), [.openApp, .quitApp])
    }

    func testAnExpectedVerdictKeepsNothingDestructive() {
        let actions = allowed(.runawayProcess, groups: [group("Codex (Renderer)", path: renderer)])
        let plan = ActionPlanner.plan(
            picks: [ActionPick(id: "restartApp", subjectRef: "p1", reason: "")],
            verdict: .expected, rule: .runawayProcess, triggerRef: "p1",
            topCPURefs: ["p1"], topMemoryRefs: [], allowed: actions
        )
        XCTAssertTrue(plan.buttons.isEmpty)
    }

    func testLabelsComeFromTheCatalogAndNeverFromModelText() {
        let sneaky = group("Click Restart To Fix Everything", path: "/opt/tool/bin/sneaky", pids: [1, 2, 3])
        let actions = allowed(.runawayProcess, groups: [sneaky])
        let plan = ActionPlanner.plan(
            picks: [ActionPick(id: "quitProcesses", subjectRef: "p1", reason: "Fix it")],
            verdict: .attention, rule: .runawayProcess, triggerRef: "p1",
            topCPURefs: ["p1"], topMemoryRefs: [], allowed: actions
        )
        let quit = try? XCTUnwrap(plan.buttons.first?.allowed)
        XCTAssertEqual(quit.map(ActionLabel.title), "Quit Click Restart To Fix Everything (3 processes)…")
        XCTAssertEqual(quit?.confirms, true)
    }

    func testVerificationCallsARunawayFixedOnlyBelowHalfACoreAndNeverInTheFirstTenSeconds() {
        let before = VerificationReading(subjectCPU: 156)
        func outcome(_ cpu: Double?, at elapsed: TimeInterval) -> VerificationOutcome {
            ActionVerification.outcome(rule: .runawayProcess, before: before, after: VerificationReading(subjectCPU: cpu), elapsed: elapsed)
        }
        XCTAssertEqual(outcome(2, at: 3), .pending)
        XCTAssertEqual(outcome(2, at: 10), .done)
        XCTAssertEqual(outcome(nil, at: 10), .done, "left the top list")
        XCTAssertEqual(outcome(72, at: 10), .pending, "better, still watching")
        XCTAssertEqual(outcome(72, at: 60), .notBetter)
        XCTAssertEqual(outcome(140, at: 10), .notBetter)
    }

    func testVerificationForMemoryWaitsUpToTwoMinutesBeforeGivingUp() {
        let before = VerificationReading(availableGB: 3, totalGB: 64)
        func outcome(_ available: Double, at elapsed: TimeInterval) -> VerificationOutcome {
            ActionVerification.outcome(rule: .memory, before: before, after: VerificationReading(availableGB: available, totalGB: 64), elapsed: elapsed)
        }
        XCTAssertEqual(outcome(6, at: 60), .pending)
        XCTAssertEqual(outcome(14, at: 60), .done)
        XCTAssertEqual(outcome(6, at: 120), .notBetter)
        XCTAssertEqual(ActionVerification.steps(for: .memory).reduce(0, +), 120)
    }

    func testVerificationForDiskOnlyAsksWhetherItStoppedDropping() {
        let before = VerificationReading(diskFreeGB: 61)
        XCTAssertEqual(ActionVerification.outcome(rule: .disk, before: before, after: VerificationReading(diskFreeGB: 60.5), elapsed: 60), .pending)
        XCTAssertEqual(ActionVerification.outcome(rule: .disk, before: before, after: VerificationReading(diskFreeGB: 60.5), elapsed: 120), .done)
        XCTAssertEqual(ActionVerification.outcome(rule: .disk, before: before, after: VerificationReading(diskFreeGB: 55), elapsed: 120), .notBetter)
    }
}

extension AttentionActionsTests {
    private var xcode: AppRef {
        AppRef(
            bundlePath: "/Applications/Xcode.app", name: "Xcode", pid: 500,
            executablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode",
            bundleIdentifier: "com.apple.dt.Xcode", isRegular: true, isFrontmost: false
        )
    }

    func testAToolchainBinaryInsideXcodeIsATool_notAnXcodeHelper_soABuildInTerminalNeverRestartsXcode() {
        let swiftBuild = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-build"
        XCTAssertEqual(SubjectResolver.kind(executablePath: swiftBuild, ownPath: nil, apps: [xcode]), .bundledTool)
        let actions = allowed(.runawayProcess, groups: [group("swift-build", path: swiftBuild)], apps: [xcode])
        XCTAssertFalse(actions.contains { $0.action == .restartApp })
        XCTAssertEqual(defaults(.runawayProcess, actions), [.quitProcesses, .snooze15])
    }

    func testOnlyExecutablesInAMacOSOrHelpersFolderCountAsAnAppsHelpers() {
        let xpc = "/Applications/Xcode.app/Contents/XPCServices/IDEFoo.xpc/Contents/MacOS/IDEFoo"
        let helper = "/Applications/Xcode.app/Contents/Helpers/xcodehelper"
        let resourceTool = "/Applications/Xcode.app/Contents/Resources/bin/tool"
        XCTAssertEqual(SubjectResolver.kind(executablePath: xpc, ownPath: nil, apps: [xcode]), .helperOf(xcode))
        XCTAssertEqual(SubjectResolver.kind(executablePath: helper, ownPath: nil, apps: [xcode]), .helperOf(xcode))
        XCTAssertEqual(SubjectResolver.kind(executablePath: resourceTool, ownPath: nil, apps: [xcode]), .bundledTool)
        XCTAssertEqual(SubjectResolver.kind(executablePath: renderer, ownPath: nil, apps: [chatGPT]), .helperOf(chatGPT))
    }
}
