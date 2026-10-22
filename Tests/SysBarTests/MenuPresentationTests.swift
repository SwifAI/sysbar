import XCTest
@testable import SysBar

final class MenuPresentationTests: XCTestCase {
    func testPanelHealthPrioritizesUnavailableThenStaleThenLoadingThenCurrent() {
        XCTAssertEqual(PanelHealthPresentation.resolve(hasUnavailable: true, hasStale: true, hasLoading: true), .unavailable)
        XCTAssertEqual(PanelHealthPresentation.resolve(hasUnavailable: false, hasStale: true, hasLoading: true), .stale)
        XCTAssertEqual(PanelHealthPresentation.resolve(hasUnavailable: false, hasStale: false, hasLoading: true), .loading)
        XCTAssertEqual(PanelHealthPresentation.resolve(hasUnavailable: false, hasStale: false, hasLoading: false), .current)
    }

    func testCurrentFreshnessCopySaysDataCurrentInsteadOfOverallHealth() {
        XCTAssertEqual(PanelHealthPresentation.current.title, "Data current")
        XCTAssertEqual(AppResources.localized(PanelHealthPresentation.current.title), "Data current")
    }

    func testProcessActionPolicyConfirmsMultiTerminateAndEveryForceQuit() {
        XCTAssertFalse(ProcessActionPolicy.requiresConfirmation(signal: .terminate, processCount: 1))
        XCTAssertTrue(ProcessActionPolicy.requiresConfirmation(signal: .terminate, processCount: 2))
        XCTAssertTrue(ProcessActionPolicy.requiresConfirmation(signal: .forceKill, processCount: 1))
        XCTAssertTrue(ProcessActionPolicy.requiresConfirmation(signal: .forceKill, processCount: 2))
    }

    func testExposureVerdictFlagsOnlyLANListenersThatAreNeitherLoopbackNorEphemeralUDPNoise() {
        let loopback = ListenSocket(pid: 1, processName: "local", port: 80, bindAddress: "127.0.0.1", isTCP: true)
        let web = ListenSocket(pid: 2, processName: "web", port: 8080, bindAddress: "*", isTCP: true)
        let quic = ListenSocket(pid: 3, processName: "quic", port: 55_000, bindAddress: "*", isTCP: false)
        let verdict = ExposureVerdict([loopback, web, quic], trusted: [], allowedSubjects: [])

        XCTAssertEqual(verdict.needsLook, [web])
        XCTAssertEqual(verdict.normalCount, 2)
    }

    // The full panel order is Security,
    // System Overview, Top CPU, Top Memory, Ports, System Services; a dropped, reordered or
    // extra section (e.g. a revived aggregate health brief) fails.
    func testPanelOrderIsSecurityThenSystemOverviewThenTopCPUTopMemoryPortsAndSystemServices() {
        XCTAssertEqual(
            MenuSection.panelOrder,
            [.security, .metrics, .cpu, .memory, .ports, .systemServices]
        )
    }

    // Boundary: panelOrder has no duplicate (two ForEach rows would share
    // one identity) and leaves out no MenuSection case, so it is the one complete order source.
    func testPanelOrderListsEveryMenuSectionExactlyOnce() {
        XCTAssertEqual(
            Set(MenuSection.panelOrder).count,
            MenuSection.panelOrder.count,
            "A duplicate would give two ForEach rows the same identity"
        )
        XCTAssertEqual(Set(MenuSection.panelOrder), Set(MenuSection.allCases))
    }

    // The full-bleed (0-pt) scroll stack renders sections only through
    // ForEach(MenuSection.panelOrder); each sectionView(for:) case keeps its builder, SectionKey,
    // sort, expansion request and .id(HealthBriefActionRoute…) anchor; no builder is used elsewhere.
    // Only the telemetry sections read the panel, each through its own PanelReader.
    func testMenuContentViewRendersItsSectionsOnlyByIteratingThePanelOrder() throws {
        let view = try source("Sources/SysBar/MenuView.swift")

        XCTAssertNotNil(
            view.range(
                of: #"VStack\(alignment: \.leading, spacing: 0\) \{\s*ForEach\(MenuSection\.panelOrder, id: \\\.self\) \{ section in\s*sectionView\(for: section\)\s*\}\s*\}"#,
                options: .regularExpression
            ),
            "The scroll view's full-bleed section stack must contain only the ForEach over MenuSection.panelOrder"
        )

        let signature = "private func sectionView(for section: MenuSection) -> some View {"
        XCTAssertEqual(occurrences(of: signature, in: view), 1)
        guard let start = view.range(of: signature),
              let end = view.range(of: "\n    }\n", range: start.upperBound..<view.endIndex) else {
            return XCTFail("sectionView(for:) not found")
        }
        let dispatch = String(view[start.upperBound..<end.lowerBound])

        let reader = "PanelReader(panel: monitor.panelModel)"
        let expectedCases: [(label: String, contents: [String], readsPanel: Bool)] = [
            ("case .security:", ["securitySection"], false),
            ("case .metrics:", ["metricsSection(snapshot)"], true),
            ("case .cpu:", ["title: \"Top CPU\"", "key: .topCPU", "sort: .cpu", "processes: snapshot.processes",
                            "expansionRequest: topCPUExpansionRequest", ".id(HealthBriefActionRoute.topCPU)"], true),
            ("case .memory:", ["title: \"Top Memory\"", "key: .topMem", "sort: .memory", "processes: snapshot.processes",
                               "expansionRequest: topMemoryExpansionRequest", ".id(HealthBriefActionRoute.topMemory)"], true),
            ("case .ports:", ["portsSection(snapshot, expansionRequest: portsExpansionRequest)",
                              ".id(HealthBriefActionRoute.listeningPorts)"], true),
            ("case .systemServices:", ["systemServicesSection"], false)
        ]
        XCTAssertEqual(occurrences(of: "case .", in: dispatch), expectedCases.count)
        for expected in expectedCases {
            guard let label = dispatch.range(of: expected.label) else {
                XCTFail("missing \(expected.label)")
                continue
            }
            let next = dispatch.range(of: "case .", range: label.upperBound..<dispatch.endIndex)
            let segment = dispatch[label.upperBound..<(next?.lowerBound ?? dispatch.endIndex)]
            for content in expected.contents {
                XCTAssertTrue(segment.contains(content), "\(expected.label) must render \(content)")
            }
            XCTAssertEqual(
                segment.contains(reader),
                expected.readsPanel,
                "\(expected.label) must \(expected.readsPanel ? "" : "not ")read the panel through its own PanelReader"
            )
        }
        XCTAssertFalse(
            view.contains("monitor.panelModel.snapshot"),
            "MenuContentView must not read the panel directly; that re-renders the whole popover every tick"
        )

        let builders: [(token: String, uses: Int)] = [
            ("securitySection", 1), ("metricsSection", 1), ("processSection(", 2),
            ("portsSection(", 1), ("systemServicesSection", 1)
        ]
        for builder in builders {
            XCTAssertEqual(occurrences(of: builder.token, in: dispatch), builder.uses, builder.token)
            XCTAssertEqual(
                occurrences(of: builder.token, in: view),
                builder.uses + 1,
                "\(builder.token) must be used only inside sectionView(for:), besides its declaration"
            )
        }
    }

    func testVerifiedMacOSServicesAreCountedSeparatelyFromReviewableLANListeners() {
        let airPlay = ListenSocket(pid: 501, processName: "ControlCe", port: 7000, bindAddress: "*", isTCP: true)
        let devServer = ListenSocket(pid: 812, processName: "node", port: 3000, bindAddress: "*", isTCP: true)
        let loopback = ListenSocket(pid: 813, processName: "postgres", port: 5432, bindAddress: "127.0.0.1", isTCP: true)
        let ports = [airPlay, devServer, loopback]
        let trusted: Set = [airPlay.endpointKey]

        let verified = ExposureVerdict(ports, trusted: trusted, allowedSubjects: [])
        XCTAssertEqual(verified.needsLook, [devServer])
        XCTAssertEqual(verified.normalCount, 2)

        let unverified = ExposureVerdict(ports, trusted: [], allowedSubjects: [])
        XCTAssertEqual(unverified.needsLook, [airPlay, devServer])
        XCTAssertEqual(unverified.normalCount, 1)
    }

    func testProcessIconsComeFromTheOutermostAppBundleSoHelpersShowTheirApp() {
        XCTAssertEqual(
            ProcessIconPath.bundlePath(
                containing: "/Applications/Codex.app/Contents/Frameworks/Codex Helper (Renderer).app/Contents/MacOS/Codex Helper (Renderer)"
            ),
            "/Applications/Codex.app"
        )
        XCTAssertEqual(
            ProcessIconPath.bundlePath(containing: "/Applications/Safari.app/Contents/MacOS/Safari"),
            "/Applications/Safari.app"
        )
        XCTAssertNil(ProcessIconPath.bundlePath(containing: "/usr/local/bin/node"))
    }

    func testProgressiveDisclosureKeepsOnlyTopCPUExpandedByDefault() {
        XCTAssertTrue(SectionKey.topCPU.defaultExpanded)
        XCTAssertFalse(SectionKey.topMem.defaultExpanded)
        XCTAssertFalse(SectionKey.ports.defaultExpanded)
    }

    func testConfirmationCopyIncludesNameCountAndPIDs() {
        let identities = [identity(pid: 10), identity(pid: 11)]
        let message = ProcessActionPolicy.confirmationMessage(
            name: "Demo",
            signal: .terminate,
            identities: identities
        )
        XCTAssertTrue(message.contains("Demo"))
        XCTAssertTrue(message.contains("2 processes"))
        XCTAssertTrue(message.contains("10, 11"))
    }

    func testPartialActionFeedbackListsFailedPID() {
        let success = identity(pid: 10)
        let failure = identity(pid: 11)
        let report = ProcessActionReport(
            signal: .terminate,
            results: [
                ProcessActionMemberResult(identity: success, outcome: .signaled),
                ProcessActionMemberResult(
                    identity: failure,
                    outcome: .notSignaled(.signalFailed(ProcessSignalError(errnoCode: 1)))
                )
            ]
        )
        let feedback = ProcessActionFeedback.make(from: report)
        XCTAssertEqual(feedback.title, "Action partially completed")
        XCTAssertEqual(feedback.failedPIDs, [11])
        XCTAssertTrue(feedback.message.contains("11"))
    }

    private func identity(pid: Int32) -> ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            startTime: ProcessStartTime(seconds: 100, microseconds: UInt64(pid)),
            executablePath: "/bin/demo"
        )!
    }

    private func source(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func occurrences(of token: String, in text: String) -> Int {
        text.components(separatedBy: token).count - 1
    }

    func testTheNetworkSectionSaysNothingIsRiskyWhenOnlyMacOSServicesAndLocalPortsAreOpen() {
        let rapportd = ListenSocket(pid: 679, processName: "rapportd", port: 50_536, bindAddress: "*", isTCP: true)
        let airPlay = ListenSocket(pid: 700, processName: "ControlCe", port: 7_000, bindAddress: "*", isTCP: true)
        let devServer = ListenSocket(pid: 812, processName: "node", port: 3_111, bindAddress: "127.0.0.1", isTCP: true)
        let quic = ListenSocket(pid: 900, processName: "Safari", port: 61_000, bindAddress: "*", isTCP: false)
        let verdict = ExposureVerdict(
            [rapportd, airPlay, devServer, quic],
            trusted: [rapportd.endpointKey, airPlay.endpointKey],
            allowedSubjects: []
        )
        XCTAssertTrue(verdict.isClear)
        XCTAssertEqual(verdict.title(names: [:]), "Nothing risky is open")
        XCTAssertEqual(verdict.detail, "4 ports belong to macOS or only this Mac can reach them. Nothing to do.")
    }

    func testTheNetworkSectionNamesTheAppOtherDevicesCanReachAndAllowingItClearsTheVerdict() {
        let logi = ListenSocket(pid: 1_234, processName: "logioptio", port: 59_869, bindAddress: "*", isTCP: true)
        let rapportd = ListenSocket(pid: 679, processName: "rapportd", port: 50_536, bindAddress: "*", isTCP: true)
        let flagged = ExposureVerdict([logi, rapportd], trusted: [rapportd.endpointKey], allowedSubjects: [])
        XCTAssertEqual(flagged.needsLook, [logi])
        XCTAssertEqual(flagged.title(names: [1_234: "Logi Options+"]), "Other devices can connect to Logi Options+")
        XCTAssertEqual(flagged.title(names: [:]), "Other devices can connect to logioptio")
        XCTAssertTrue(flagged.detail.hasPrefix("Fine if you use it."))

        let allowed = ExposureVerdict(
            [logi, rapportd], trusted: [rapportd.endpointKey], allowedSubjects: [AttentionTracker.subject(for: logi)]
        )
        XCTAssertTrue(allowed.isClear)
    }

    // Rows re-render only when what they show changes, not because the
    // panel rebuilt their action closures.
    @MainActor
    func testAProcessRowIsUnchangedByFreshActionClosuresButChangesWithItsValueOrActions() {
        let group = ProcessGroup(
            id: .executablePath("/Applications/Mail.app/Contents/MacOS/Mail"),
            name: "Mail",
            executablePath: "/Applications/Mail.app/Contents/MacOS/Mail",
            pids: [42],
            expectedIdentities: [],
            totalCPU: 12,
            totalMemMB: 300
        )
        let row = ProcessRow(group: group, metric: .percent, value: 12, terminateAction: { _ in }, forceKillAction: { _ in })

        XCTAssertEqual(row, ProcessRow(group: group, metric: .percent, value: 12, terminateAction: { _ in }, forceKillAction: { _ in }))
        XCTAssertNotEqual(row, ProcessRow(group: group, metric: .percent, value: 13, terminateAction: { _ in }, forceKillAction: { _ in }))
        XCTAssertNotEqual(row, ProcessRow(group: group, metric: .percent, value: 12))
        XCTAssertNotEqual(row, ProcessRow(group: group, metric: .megabytes, value: 12, terminateAction: { _ in }, forceKillAction: { _ in }))
    }

    @MainActor
    func testAListenerListIsUnchangedByFreshActionClosuresButChangesWithItsPortsOrRequests() {
        let node = ListenSocket(pid: 42, processName: "node", port: 3_000, bindAddress: "*", isTCP: true)
        let list = ListenerList(ports: [node], resetRequest: 1, terminateAction: { _, _ in })

        XCTAssertEqual(list, ListenerList(ports: [node], resetRequest: 1, terminateAction: { _, _ in }))
        XCTAssertNotEqual(list, ListenerList(ports: [], resetRequest: 1, terminateAction: { _, _ in }))
        XCTAssertNotEqual(list, ListenerList(ports: [node], resetRequest: 2, terminateAction: { _, _ in }))
        XCTAssertNotEqual(list, ListenerList(ports: [node], resetRequest: 1, searchFocusRequest: 1, terminateAction: { _, _ in }))
        XCTAssertNotEqual(list, ListenerList(ports: [node], resetRequest: 1))
    }
}
