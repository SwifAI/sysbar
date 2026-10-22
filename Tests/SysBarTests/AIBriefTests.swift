import Foundation
import XCTest
@testable import SysBar

private actor RecordingRunner: BoundedProcessRunning {
    private(set) var commands: [BoundedProcessCommand] = []
    private let reply: @Sendable (BoundedProcessCommand) -> BoundedProcessOutput

    init(reply: @escaping @Sendable (BoundedProcessCommand) -> BoundedProcessOutput) {
        self.reply = reply
    }

    func run(_ command: BoundedProcessCommand) async throws -> BoundedProcessOutput {
        commands.append(command)
        return reply(command)
    }
}

final class AIProviderTests: XCTestCase {
    private let call = AIBriefCall(
        systemPrompt: BriefPrompt.system,
        userMessage: "Snapshot JSON: {}",
        schema: BriefPrompt.attentionSchema
    )

    private func alwaysVerified(_ path: String = "/bin/echo") -> SignedCLILocator {
        SignedCLILocator(candidates: [URL(fileURLWithPath: path)], requirement: "x") { _, _ in true }
    }

    func testClaudeRunsOpusAtLowEffortWithNoToolsSettingsOrSavedSession() {
        let arguments = ClaudeCodeProvider.arguments(for: call)
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        XCTAssertEqual(arguments.first, "-p")
        XCTAssertEqual(value(after: "--model"), "opus")
        XCTAssertEqual(value(after: "--effort"), "low")
        XCTAssertEqual(value(after: "--tools"), "")
        XCTAssertEqual(value(after: "--setting-sources"), "")
        XCTAssertEqual(value(after: "--permission-mode"), "dontAsk")
        XCTAssertEqual(value(after: "--output-format"), "json")
        XCTAssertEqual(value(after: "--system-prompt"), BriefPrompt.system)
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
        XCTAssertFalse(arguments.contains("--bare"), "--bare skips OAuth and would break the subscription login")
        XCTAssertFalse(arguments.contains("haiku"))
    }

    func testClaudeEnvironmentCarriesOnlyTheLoginIdentityAndARestrictedPath() {
        let environment = ClaudeCodeProvider.environment(from: [
            "HOME": "/Users/example", "USER": "example", "LOGNAME": "example", "LANG": "en_US.UTF-8",
            "PATH": "/opt/evil/bin:/usr/bin", "ANTHROPIC_API_KEY": "sk-should-not-pass", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"
        ])
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["USER"], "example")
        XCTAssertEqual(environment["LOGNAME"], "example")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
    }

    func testClaudeEnvelopeYieldsTheStructuredObjectAndTheModelUsed() throws {
        let envelope = #"{"type":"result","is_error":false,"duration_ms":6300,"result":"{}","structured_output":{"verdict":"attention"},"modelUsage":{"claude-opus-5-5":{}}}"#
        let parsed = try ClaudeCodeProvider.parseEnvelope(Data(envelope.utf8), exitStatus: 0)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: parsed.object) as? [String: String], ["verdict": "attention"])
        XCTAssertEqual(parsed.modelLabel, "Opus")
        XCTAssertEqual(parsed.durationSeconds ?? 0, 6.3, accuracy: 0.01)
    }

    func testClaudeNotLoggedInAndOverloadMapToSignInAndBusy() {
        let notLoggedIn = #"{"is_error":true,"result":"Not logged in · Please run /login"}"#
        XCTAssertThrowsError(try ClaudeCodeProvider.parseEnvelope(Data(notLoggedIn.utf8), exitStatus: 1)) {
            XCTAssertEqual($0 as? AIProviderError, .signInNeeded)
        }
        let overloaded = #"{"is_error":true,"result":"API Error: 529 Overloaded"}"#
        XCTAssertThrowsError(try ClaudeCodeProvider.parseEnvelope(Data(overloaded.utf8), exitStatus: 1)) {
            XCTAssertEqual($0 as? AIProviderError, .busy)
        }
    }

    func testCodexUsesTheCLIDefaultModelAtLowReasoningOnThePriorityTierWithoutUserConfig() {
        let arguments = CodexBriefProvider.arguments(
            schemaPath: "/tmp/s.json", lastMessagePath: "/tmp/o.json", workspacePath: "/tmp/w", priorityTier: true
        )
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains(#"model_reasoning_effort="low""#))
        XCTAssertTrue(arguments.contains(#"service_tier="priority""#))
        XCTAssertFalse(arguments.contains("-m"), "named models are refused for ChatGPT accounts")
        XCTAssertEqual(arguments.firstIndex(of: "-o").map { arguments[$0 + 1] }, "/tmp/o.json")

        let withoutTier = CodexBriefProvider.arguments(
            schemaPath: "/tmp/s.json", lastMessagePath: "/tmp/o.json", workspacePath: "/tmp/w", priorityTier: false
        )
        XCTAssertFalse(withoutTier.contains(#"service_tier="priority""#))
    }

    func testCodexRunsInAReadOnlySandboxWithEveryToolFeatureDisabled() {
        let arguments = CodexBriefProvider.arguments(
            schemaPath: "/tmp/s.json", lastMessagePath: "/tmp/o.json", workspacePath: "/tmp/w", priorityTier: true
        )
        XCTAssertEqual(arguments.firstIndex(of: "--sandbox").map { arguments[$0 + 1] }, "read-only")
        XCTAssertTrue(arguments.contains("--ignore-rules"))
        let disabled = arguments.indices.dropLast().filter { arguments[$0] == "--disable" }.map { arguments[$0 + 1] }
        XCTAssertEqual(disabled, CodexBriefProvider.disabledToolFeatures)
        for feature in ["shell_tool", "unified_exec", "browser_use", "apps", "plugins", "hooks", "computer_use", "multi_agent"] {
            XCTAssertTrue(disabled.contains(feature), "\(feature) must stay disabled")
        }
    }

    func testCodexDiscoveryUsesOnlyFixedExplicitCandidates() {
        XCTAssertEqual(
            CodexBriefProvider.candidateURLs(home: URL(fileURLWithPath: "/Users/example", isDirectory: true)).map(\.path),
            ["/Users/example/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        )
    }

    func testCodexLastMessageToleratesACodeFence() throws {
        let fenced = Data("```json\n{\"verdict\":\"expected\"}\n```".utf8)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: CodexBriefProvider.extractObject(from: fenced)) as? [String: String],
            ["verdict": "expected"]
        )
        XCTAssertThrowsError(try CodexBriefProvider.extractObject(from: Data("not json".utf8)))
    }

    func testVersionsAreReadFromTheResolvedInstallPaths() {
        XCTAssertEqual(ClaudeCodeProvider.version(fromResolvedPath: "/Users/example/.local/share/claude/versions/2.1.283"), "2.1.283")
        XCTAssertEqual(
            CodexBriefProvider.version(fromResolvedPath: "/Users/example/.codex/packages/standalone/releases/0.153.4-aarch64-apple-darwin/bin/codex"),
            "0.153.4"
        )
        XCTAssertNil(ClaudeCodeProvider.version(fromResolvedPath: "/opt/homebrew/bin/claude"))
    }

    func testValidatorRejectsAScriptShimNamedClaude() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shim = folder.appendingPathComponent("claude")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        // Resolve through the same signature cache the providers use, so the
        // real designated-requirement check runs against the shim.
        let signatures = SignatureCache()
        let locator = SignedCLILocator(candidates: [shim], requirement: ClaudeCodeProvider.designatedRequirement)
        let located = await signatures.location(for: locator)
        XCTAssertEqual(located, .unverified(shim.resolvingSymlinksInPath().standardizedFileURL))

        let missing = await signatures.location(
            for: SignedCLILocator(candidates: [folder.appendingPathComponent("missing")], requirement: "x")
        )
        XCTAssertEqual(missing, .notFound)
    }

    func testDefaultProviderIsClaudeWhenBothAreInstalledAndTheOnlyOneOtherwise() {
        XCTAssertEqual(AIProviderPolicy.defaultKind(claude: .ready(version: nil), codex: .ready(version: nil)), .claude)
        XCTAssertEqual(AIProviderPolicy.defaultKind(claude: .notInstalled, codex: .signInNeeded(version: nil)), .codex)
        XCTAssertEqual(AIProviderPolicy.defaultKind(claude: .unverified, codex: .notInstalled), .off)
    }

    func testBothProvidersReceiveTheSameSystemPromptAndSchema() async throws {
        let claudeRunner = RecordingRunner { _ in
            BoundedProcessOutput(
                stdout: Data(#"{"is_error":false,"structured_output":{"ok":true},"modelUsage":{"claude-opus-5-5":{}}}"#.utf8),
                stderr: Data(),
                terminationStatus: 0
            )
        }
        let claude = ClaudeCodeProvider(runner: claudeRunner, locator: alwaysVerified(), environment: [:])
        _ = try await claude.run(call)
        let claudeCommands = await claudeRunner.commands
        let claudeCommand = try XCTUnwrap(claudeCommands.first)
        XCTAssertTrue(claudeCommand.arguments.contains(BriefPrompt.system))
        XCTAssertTrue(claudeCommand.arguments.contains(String(data: call.schema, encoding: .utf8) ?? "?"))
        XCTAssertEqual(claudeCommand.standardInput, Data(call.userMessage.utf8))
        XCTAssertEqual(claudeCommand.timeout, 30)

        let codexRunner = RecordingRunner { command in
            if let index = command.arguments.firstIndex(of: "-o") {
                try? Data(#"{"ok":true}"#.utf8).write(to: URL(fileURLWithPath: command.arguments[index + 1]))
            }
            return BoundedProcessOutput(stdout: Data(), stderr: Data(), terminationStatus: 0)
        }
        let codex = CodexBriefProvider(runner: codexRunner, locator: alwaysVerified(), environment: [:])
        let result = try await codex.run(call)
        XCTAssertEqual(result.modelLabel, "Codex")
        let codexCommands = await codexRunner.commands
        let codexCommand = try XCTUnwrap(codexCommands.first)
        let stdin = String(data: codexCommand.standardInput, encoding: .utf8) ?? ""
        XCTAssertTrue(stdin.contains(BriefPrompt.system))
        XCTAssertTrue(stdin.contains(call.userMessage))
    }

    func testCodexRetriesOnceOnTheDefaultTierWhenThePriorityTierIsRefused() async throws {
        let runner = RecordingRunner { command in
            if command.arguments.contains(#"service_tier="priority""#) {
                return BoundedProcessOutput(stdout: Data(), stderr: Data("error: service_tier not allowed".utf8), terminationStatus: 1)
            }
            if let index = command.arguments.firstIndex(of: "-o") {
                try? Data(#"{"ok":true}"#.utf8).write(to: URL(fileURLWithPath: command.arguments[index + 1]))
            }
            return BoundedProcessOutput(stdout: Data(), stderr: Data(), terminationStatus: 0)
        }
        let codex = CodexBriefProvider(runner: runner, locator: alwaysVerified(), environment: [:])
        _ = try await codex.run(call)
        let count = await runner.commands.count
        XCTAssertEqual(count, 2)
    }

    func testUnverifiedOrMissingCLIsAreNeverLaunched() async {
        let runner = RecordingRunner { _ in BoundedProcessOutput(stdout: Data(), stderr: Data(), terminationStatus: 0) }
        let rejecting = SignedCLILocator(candidates: [URL(fileURLWithPath: "/bin/echo")], requirement: "x") { _, _ in false }
        let claude = ClaudeCodeProvider(runner: runner, locator: rejecting, environment: [:])
        do {
            _ = try await claude.run(call)
            XCTFail("an unverified binary must not run")
        } catch {
            XCTAssertEqual(error as? AIProviderError, .unverified)
        }
        let status = await claude.status()
        XCTAssertEqual(status, .unverified)
        let launched = await runner.commands.count
        XCTAssertEqual(launched, 0)
    }
}

final class BriefEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func group(_ name: String, path: String, cpu: Double, actionable: Bool = true) -> ProcessGroup {
        let identity = ProcessIdentity(
            pid: 42,
            startTime: ProcessStartTime(seconds: UInt64(now.timeIntervalSince1970) - 22 * 60, microseconds: 1),
            executablePath: path
        )
        return ProcessGroup(
            id: .executablePath(path),
            name: name,
            executablePath: path,
            pids: [42],
            expectedIdentities: actionable ? [identity].compactMap { $0 } : [],
            totalCPU: cpu,
            totalMemMB: 1_139
        )
    }

    private func inputs(trigger: AttentionItem? = nil, ports: [ListenSocket] = [], trusted: Set<ListenerEndpointKey> = []) -> BriefInputs {
        let renderer = group("Codex (Renderer)", path: "/Applications/ChatGPT.app/Contents/MacOS/Codex (Renderer)", cpu: 155.7)
        let server = group("WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", cpu: 39.4)
        var snapshot = PanelSnapshot.loading
        snapshot.cpu = .available(15, sampledAt: now)
        snapshot.listenPorts = .available(ports, sampledAt: now)
        snapshot.trustedListenerKeys = trusted
        return BriefInputs(
            now: now,
            mac: BriefMachineFacts(chip: "Apple M5 Max", cores: 18, ramGB: 64, macOS: "27.0.1", uptimeHours: 28.4, frontmostApp: "Claude"),
            snapshot: snapshot,
            processes: ProcessOverview(topCPU: [renderer, server], topMemory: [renderer]),
            trigger: trigger,
            activeItems: trigger.map { [$0] } ?? [],
            appNames: ["/Applications/ChatGPT.app/Contents/MacOS/Codex (Renderer)": "ChatGPT"],
            listenerAppNames: [:],
            ownExecutablePath: "/Applications/SysBar.app/Contents/MacOS/SysBar",
            frontmostAppPath: "/Applications/Claude.app"
        )
    }

    private func reviewJSON(summary: String, findings: Int, detail: String = "About 32% CPU combined; nothing to do.") -> Data {
        let items = (0..<findings).map { index in
            "{\"severity\":\"info\",\"title\":\"Finding \(index)\",\"detail\":\"\(detail)\",\"subjectRef\":null}"
        }.joined(separator: ",")
        return Data("{\"overall\":\"healthy\",\"summary\":\"\(summary)\",\"findings\":[\(items)]}".utf8)
    }

    func testAReviewLongerThanAGlanceIsRejectedAndTheSchemaAsksForOneSentence() throws {
        let evidence = BriefEvidence.make(inputs(), kind: "review")
        let glance = "Nothing needs doing; AI tools are the main load."
        XCTAssertNoThrow(try BriefValidation.review(reviewJSON(summary: glance, findings: 3), evidence: evidence))
        XCTAssertThrowsError(try BriefValidation.review(reviewJSON(summary: glance, findings: 4), evidence: evidence))
        XCTAssertThrowsError(try BriefValidation.review(
            reviewJSON(summary: String(repeating: "The Mac is fine. ", count: 12), findings: 1), evidence: evidence
        ))
        XCTAssertThrowsError(try BriefValidation.review(
            reviewJSON(summary: glance, findings: 1, detail: String(repeating: "More detail. ", count: 15)), evidence: evidence
        ))

        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: BriefPrompt.reviewSchema) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["summary"] as? [String: Any])?["maxLength"] as? Int, 120)
        XCTAssertEqual((properties["findings"] as? [String: Any])?["maxItems"] as? Int, 3)
        XCTAssertTrue(BriefPrompt.review(evidenceJSON: "{}").contains("one short sentence"))
    }

    func testAHealthyReviewSaysNothingToDoAndFoldsEveryFindingUnderDetails() {
        let healthy = ReviewBrief(overall: .healthy, summary: "Nothing needs doing.", findings: [
            .init(severity: .info, title: "Logi Options+ listens", detail: "TCP 59869; usually harmless.", subjectRef: "l1"),
            .init(severity: .info, title: "AI apps are the main load", detail: "About 32% CPU.", subjectRef: "p1")
        ])
        XCTAssertEqual(ReviewPresentation.title(healthy), "Healthy · nothing to do")
        XCTAssertTrue(ReviewPresentation.needsAction(healthy).isEmpty)
        XCTAssertEqual(ReviewPresentation.folded(healthy).count, 2)

        let attention = ReviewBrief(overall: .attention, summary: "One thing needs doing.", findings: [
            .init(severity: .info, title: "AI apps are the main load", detail: "About 32% CPU.", subjectRef: "p2"),
            .init(severity: .attention, title: "node is open to the network", detail: "Port 3000; stop it if unused.", subjectRef: "l1")
        ])
        XCTAssertEqual(ReviewPresentation.title(attention), "Needs attention")
        XCTAssertEqual(ReviewPresentation.needsAction(attention).map(\.title), ["node is open to the network"])
        XCTAssertEqual(
            ["p2", "m1", "l1", "a1", nil].map(ReviewPresentation.route(for:)),
            [.topCPU, .topMemory, .network, nil, nil]
        )
    }

    func testEvidenceNamesTheTriggerSubjectAndMarksOnlyUserAppsQuittable() throws {
        let item = AttentionItem(
            id: AttentionKey(rule: .runawayProcess, subject: "/Applications/ChatGPT.app/Contents/MacOS/Codex (Renderer)"),
            subjectName: "Codex (Renderer)",
            executablePath: "/Applications/ChatGPT.app/Contents/MacOS/Codex (Renderer)",
            fact: .runaway(name: "Codex (Renderer)", cpuPercent: 155.7, minutes: 22),
            raisedAt: now,
            magnitudeBucket: 3
        )
        let evidence = BriefEvidence.make(inputs(trigger: item), kind: "attention")
        XCTAssertEqual(evidence.trigger?.subjectRef, "p1")
        XCTAssertEqual(evidence.trigger?.observed, "Codex (Renderer) has used 156% CPU for 22 min")
        XCTAssertEqual(evidence.topCPU.map(\.quittable), [true, false])
        XCTAssertEqual(evidence.topCPU.first?.app, "ChatGPT")
        XCTAssertEqual(evidence.topCPU.first?.runningMinutes, 22)
        XCTAssertTrue(evidence.quittableRefs.contains("p1"))
        XCTAssertFalse(evidence.quittableRefs.contains("p2"))
        XCTAssertLessThanOrEqual(try evidence.json().utf8.count, BriefEvidence.maximumBytes)
    }

    func testReviewEvidenceIncludesVerifiedAppleListenersButAttentionEvidenceDoesNot() {
        let airPlay = ListenSocket(pid: 668, processName: "ControlCe", port: 7_000, bindAddress: "*", isTCP: true)
        let node = ListenSocket(pid: 812, processName: "node", port: 3_000, bindAddress: "*", isTCP: true)
        let review = BriefEvidence.make(inputs(ports: [airPlay, node], trusted: [airPlay.endpointKey]), kind: "review")
        let attention = BriefEvidence.make(inputs(ports: [airPlay, node], trusted: [airPlay.endpointKey]), kind: "attention")
        XCTAssertEqual(review.lanListeners.map(\.process), ["ControlCe", "node"])
        XCTAssertEqual(review.lanListeners.map(\.appleVerified), [true, false])
        XCTAssertEqual(attention.lanListeners.map(\.process), ["node"])
    }

    private func brief(
        picks: [(String, String?)] = [],
        verdict: String = "attention",
        headline: String = "Codex's renderer has been running hot"
    ) -> Data {
        let actions = picks.map { id, ref in
            "{\"id\":\"\(id)\",\"subjectRef\":\(ref.map { "\"\($0)\"" } ?? "null"),\"reason\":\"Only an unsent draft is lost.\"}"
        }.joined(separator: ",")
        return Data("""
        {"verdict":"\(verdict)","headline":"\(headline)","why":"It has held 1.5 cores for 22 minutes.",
         "detail":"The Codex view keeps rendering with nothing streaming.","likelyCause":"A stuck render loop.",
         "confidence":"medium","actions":[\(actions)],"manualStep":null}
        """.utf8)
    }

    private let chatGPT = AppRef(
        bundlePath: "/Applications/ChatGPT.app",
        name: "ChatGPT",
        pid: 15_209,
        executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        bundleIdentifier: "com.openai.codex",
        isRegular: true,
        isFrontmost: false
    )

    private let safari = AppRef(
        bundlePath: "/Applications/Safari.app",
        name: "Safari",
        pid: 900,
        executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
        bundleIdentifier: "com.apple.Safari",
        isRegular: true,
        isFrontmost: true
    )

    private var renderer: AttentionItem {
        AttentionItem(
            id: AttentionKey(rule: .runawayProcess, subject: "/Applications/ChatGPT.app/Contents/MacOS/Codex (Renderer)"),
            subjectName: "Codex (Renderer)",
            executablePath: "/Applications/ChatGPT.app/Contents/MacOS/Codex (Renderer)",
            fact: .runaway(name: "Codex (Renderer)", cpuPercent: 155.7, minutes: 22),
            raisedAt: now,
            magnitudeBucket: 3
        )
    }

    private func evidence(apps: [AppRef]? = nil) -> BriefEvidence {
        var value = inputs(trigger: renderer)
        value.runningApps = apps ?? [chatGPT]
        return BriefEvidence.make(value, kind: "attention")
    }

    private func plan(_ data: Data, _ evidence: BriefEvidence) throws -> ActionPlan {
        let brief = try BriefValidation.attention(data, evidence: evidence)
        return ActionPlanner.plan(
            picks: brief.actions, verdict: brief.verdict, rule: .runawayProcess, triggerRef: evidence.triggerRef,
            topCPURefs: evidence.topCPURefs, topMemoryRefs: evidence.topMemoryRefs, allowed: evidence.allowedActions
        )
    }

    func testAHelperIsOfferedRestartOfItsOwningAppAndQuitOfItsOwnProcesses() {
        let evidence = evidence()
        let pairs = evidence.actions.map { "\($0.id):\($0.subjectRef ?? "-")" }
        XCTAssertTrue(pairs.contains("restartApp:p1"))
        XCTAssertTrue(pairs.contains("openApp:p1"))
        XCTAssertTrue(pairs.contains("quitProcesses:p1"))
        XCTAssertEqual(evidence.actions.first { $0.id == "restartApp" }?.target, "ChatGPT")
        XCTAssertFalse(pairs.contains { $0.hasSuffix(":p2") }, "WindowServer gets nothing")
        XCTAssertEqual(pairs.last, "snooze15:-")
    }

    func testAPickForAnActionSysBarDidNotSendIsDroppedButTheBriefIsKept() throws {
        let evidence = evidence()
        let plan = try plan(brief(picks: [("openStorageSettings", nil), ("restartApp", "p1")]), evidence)
        XCTAssertEqual(plan.buttons.map(\.allowed.action), [.restartApp, .snooze15])
        XCTAssertEqual(plan.droppedPicks, 1)
        XCTAssertEqual(plan.buttons.first?.reason, "Only an unsent draft is lost.")
    }

    func testAPickOnARefNotListedWithThatActionIsDropped() throws {
        let plan = try plan(brief(picks: [("quitProcesses", "p2"), ("restartApp", "p9")]), evidence())
        XCTAssertEqual(plan.droppedPicks, 2)
        XCTAssertEqual(plan.buttons.map(\.allowed.action), [.restartApp, .openApp], "falls back to SysBar's defaults")
    }

    func testMoreThanTwoPicksFailValidationAndASecondDestructivePickIsDropped() throws {
        let evidence = evidence()
        let three = brief(picks: [("restartApp", "p1"), ("openApp", "p1"), ("snooze15", nil)])
        XCTAssertThrowsError(try BriefValidation.attention(three, evidence: evidence))
        let plan = try plan(brief(picks: [("restartApp", "p1"), ("quitProcesses", "p1")]), evidence)
        XCTAssertEqual(plan.buttons.map(\.allowed.action), [.restartApp, .snooze15])
        XCTAssertEqual(plan.droppedPicks, 1)
    }

    func testEvidenceListsRunningAppsSoSafariCanBeRestartedWhenOnlyWebContentIsInTheLists() {
        let evidence = evidence(apps: [chatGPT, safari])
        XCTAssertEqual(evidence.apps.map(\.name), ["Safari", "ChatGPT"], "frontmost first")
        let safariRef = try? XCTUnwrap(evidence.apps.first { $0.name == "Safari" }?.ref)
        XCTAssertTrue(evidence.actions.contains { $0.id == "restartApp" && $0.subjectRef == safariRef })
        XCTAssertEqual(evidence.apps.first { $0.name == "ChatGPT" }?.ownsRefs, ["p1", "m1"])
    }

    func testTheSameAppIsListedOnceEvenWhenItAppearsAsAProcessAndAsARunningApp() {
        let restarts = evidence().actions.filter { $0.id == "restartApp" }
        XCTAssertEqual(restarts.count, 1)
        XCTAssertEqual(restarts.first?.subjectRef, "p1")
    }

    func testEvidenceWithFortyAllowedActionsStaysUnderTwentyKilobytes() throws {
        let apps = (0..<12).map { index in
            AppRef(
                bundlePath: "/Applications/App \(index) With A Long Descriptive Name.app",
                name: "App \(index) With A Long Descriptive Name",
                pid: Int32(1_000 + index),
                executablePath: "/Applications/App \(index) With A Long Descriptive Name.app/Contents/MacOS/App",
                bundleIdentifier: "com.example.app\(index)",
                isRegular: true,
                isFrontmost: index == 0
            )
        }
        let evidence = evidence(apps: apps + [chatGPT])
        XCTAssertGreaterThanOrEqual(evidence.actions.count, 35)
        XCTAssertLessThanOrEqual(evidence.actions.count, ActionCatalog.maximumEntries + 1, "at most forty plus snooze")
        XCTAssertLessThanOrEqual(try evidence.json().utf8.count, BriefEvidence.maximumBytes)
    }

    func testBriefsWithLinksOrCodeAreRejectedButNumbersAreFine() {
        let evidence = BriefEvidence.make(inputs(), kind: "attention")
        XCTAssertThrowsError(try BriefValidation.attention(brief(headline: "See https://example.com"), evidence: evidence))
        XCTAssertNoThrow(try BriefValidation.attention(brief(headline: "156% CPU for 22 minutes"), evidence: evidence))
    }
}
