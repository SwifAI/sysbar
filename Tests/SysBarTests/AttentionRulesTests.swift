import XCTest
@testable import SysBar

final class AttentionRulesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let renderer = "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)"

    private func group(_ path: String, name: String, cpu: Double) -> ProcessGroup {
        ProcessGroup(
            id: .executablePath(path),
            name: name,
            executablePath: path,
            pids: [42],
            expectedIdentities: [],
            totalCPU: cpu,
            totalMemMB: 1_139
        )
    }

    /// Feeds one sample every `step` seconds for `minutes`, returning every change.
    private func feed(
        _ tracker: inout AttentionTracker,
        cpu: (Int) -> Double,
        minutes: Int,
        step: TimeInterval = 60,
        frontmost: String? = nil,
        from offset: TimeInterval = 0
    ) -> AttentionChanges {
        var all = AttentionChanges()
        let count = Int(Double(minutes) * 60 / step)
        for index in 0...count {
            let now = start.addingTimeInterval(offset + Double(index) * step)
            all.merge(tracker.ingestProcesses(
                [group(renderer, name: "Codex (Renderer)", cpu: cpu(index))],
                frontmostAppPath: frontmost,
                at: now
            ))
        }
        return all
    }

    func testRunawayRuleNeedsFiveMinutesAboveOneCoreWhenTheAppIsInTheBackground() {
        var tracker = AttentionTracker()
        XCTAssertTrue(feed(&tracker, cpu: { _ in 156 }, minutes: 4).raised.isEmpty)

        var later = feed(&tracker, cpu: { _ in 156 }, minutes: 1, from: 5 * 60)
        later.raised = later.raised.filter { $0.rule == .runawayProcess }
        XCTAssertEqual(later.raised.count, 1)
        guard case let .runaway(name, cpu, minutes)? = later.raised.first?.fact else {
            return XCTFail("expected a runaway fact")
        }
        XCTAssertEqual(name, "Codex (Renderer)")
        XCTAssertEqual(cpu, 156, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(minutes, 5)
        XCTAssertEqual(later.raised.first?.executablePath, renderer)
    }

    func testRunawayRuleWaitsTwentyMinutesWhenTheAppIsFrontmost() {
        var tracker = AttentionTracker()
        let chatGPT = "/Applications/ChatGPT.app"
        XCTAssertTrue(feed(&tracker, cpu: { _ in 156 }, minutes: 15, frontmost: chatGPT).raised.isEmpty)
        XCTAssertEqual(
            feed(&tracker, cpu: { _ in 156 }, minutes: 6, frontmost: chatGPT, from: 15 * 60 + 60).raised.count,
            1
        )
    }

    func testRunawayRuleResetsWhenAnySampleDropsBelowHalfACore() {
        var tracker = AttentionTracker()
        let changes = feed(&tracker, cpu: { $0 == 3 ? 20 : 180 }, minutes: 7)
        XCTAssertTrue(changes.raised.isEmpty, "a dip below 50% inside the window must restart the clock")
    }

    func testRunawayRuleNeverRaisesAcrossAGapInSampling() {
        var tracker = AttentionTracker()
        _ = feed(&tracker, cpu: { _ in 156 }, minutes: 1)
        // An hour without samples (popover closed, watch off), then one hot sample.
        let changes = tracker.ingestProcesses(
            [group(renderer, name: "Codex (Renderer)", cpu: 156)],
            frontmostAppPath: nil,
            at: start.addingTimeInterval(3_600)
        )
        XCTAssertTrue(changes.raised.isEmpty)
    }

    func testRunawayItemClearsAfterTwoQuietMinutesOrWhenTheAppLeavesTheList() {
        var tracker = AttentionTracker()
        XCTAssertEqual(feed(&tracker, cpu: { _ in 156 }, minutes: 6).raised.count, 1)
        var cleared: [AttentionKey] = []
        for index in 1...3 {
            cleared += tracker.ingestProcesses([], frontmostAppPath: nil, at: start.addingTimeInterval(360 + Double(index) * 60)).cleared
        }
        XCTAssertEqual(cleared, [AttentionKey(rule: .runawayProcess, subject: renderer)])
        XCTAssertTrue(tracker.active.isEmpty)
    }

    func testOrdinaryBusyAppsAndSysBarItselfNeverRaise() {
        var tracker = AttentionTracker()
        var raised: [AttentionItem] = []
        for index in 0...30 {
            raised += tracker.ingestProcesses(
                [
                    group("/System/Library/WindowServer", name: "WindowServer", cpu: 39),
                    group("/Applications/SysBar.app/Contents/MacOS/SysBar", name: "SysBar", cpu: 300)
                ],
                frontmostAppPath: nil,
                excludedPaths: ["/Applications/SysBar.app/Contents/MacOS/SysBar"],
                at: start.addingTimeInterval(Double(index) * 60)
            ).raised
        }
        XCTAssertTrue(raised.isEmpty)
    }

    func testHostCPURuleUsesTheWholeThreeMinuteWindowSoTheLaneAndTheStripAgree() {
        var tracker = AttentionTracker()
        XCTAssertTrue(tracker.ingestHost(cpuHistory: Array(repeating: 90, count: 40), memory: nil, swap: nil, at: start).raised.isEmpty)
        XCTAssertEqual(tracker.ingestHost(cpuHistory: Array(repeating: 65, count: 60), memory: nil, swap: nil, at: start).raised.count, 1)
        XCTAssertEqual(
            tracker.ingestHost(cpuHistory: Array(repeating: 65, count: 20) + Array(repeating: 10, count: 40), memory: nil, swap: nil, at: start).cleared,
            [AttentionKey(rule: .hostCPU, subject: "host")]
        )
    }

    func testMemoryRuleRaisesAfterTwoMinutesBelowTheLaneWarningAndClearsAfterFiveHealthyMinutes() {
        var tracker = AttentionTracker()
        let low = MemorySnapshot(usedGB: 60, freeMB: 3_000, totalGB: 64)
        let healthy = MemorySnapshot(usedGB: 30, freeMB: 30_000, totalGB: 64)
        XCTAssertTrue(tracker.ingestHost(cpuHistory: [], memory: low, swap: nil, at: start).raised.isEmpty)
        XCTAssertEqual(tracker.ingestHost(cpuHistory: [], memory: low, swap: nil, at: start.addingTimeInterval(121)).raised.count, 1)
        XCTAssertTrue(tracker.ingestHost(cpuHistory: [], memory: healthy, swap: nil, at: start.addingTimeInterval(200)).cleared.isEmpty)
        XCTAssertEqual(
            tracker.ingestHost(cpuHistory: [], memory: healthy, swap: nil, at: start.addingTimeInterval(501)).cleared,
            [AttentionKey(rule: .memory, subject: "host")]
        )
    }

    func testSwapLevelAloneNeverRaisesOnlyGrowthDoes() {
        var tracker = AttentionTracker()
        for index in 0...20 {
            XCTAssertTrue(tracker.ingestHost(
                cpuHistory: [],
                memory: nil,
                swap: SwapSnapshot(usedMB: 4_000, totalMB: 8_192),
                at: start.addingTimeInterval(Double(index) * 60)
            ).raised.isEmpty)
        }
        let grown = tracker.ingestHost(
            cpuHistory: [],
            memory: nil,
            swap: SwapSnapshot(usedMB: 4_700, totalMB: 8_192),
            at: start.addingTimeInterval(21 * 60)
        )
        XCTAssertEqual(grown.raised.map(\.rule), [.swapGrowth])
    }

    func testDiskRuleRaisesOnAFastDropLongBeforeTheFiftyGigabyteLine() {
        var tracker = AttentionTracker()
        XCTAssertTrue(tracker.ingestDisk(freeGB: 1_300, totalGB: 1_800, at: start).raised.isEmpty)
        let fast = tracker.ingestDisk(freeGB: 1_275, totalGB: 1_800, at: start.addingTimeInterval(600))
        XCTAssertEqual(fast.raised.count, 1)
        guard case .diskFast? = fast.raised.first?.fact else { return XCTFail("expected a fast-fill fact") }

        var lowTracker = AttentionTracker()
        guard case .diskLow? = lowTracker.ingestDisk(freeGB: 38, totalGB: 994, at: start).raised.first?.fact else {
            return XCTFail("expected a low-disk fact")
        }
    }

    func testNewListenerRuleIgnoresTheBaselineVerifiedAppleServicesAndDiscoveryNoise() {
        var tracker = AttentionTracker()
        let logitech = ListenSocket(pid: 830, processName: "logioptio", port: 59_869, bindAddress: "*", isTCP: true)
        let airPlay = ListenSocket(pid: 668, processName: "ControlCe", port: 7_000, bindAddress: "*", isTCP: true)
        let bonjour = ListenSocket(pid: 15_239, processName: "Codex", port: 5_353, bindAddress: "*", isTCP: false)
        let devServer = ListenSocket(pid: 812, processName: "node", port: 3_000, bindAddress: "*", isTCP: true)

        XCTAssertTrue(tracker.ingestListeners([logitech, airPlay], trusted: [airPlay.endpointKey], at: start).raised.isEmpty)
        let later = tracker.ingestListeners(
            [logitech, airPlay, bonjour, devServer],
            trusted: [airPlay.endpointKey],
            displayNames: [812: "node"],
            at: start.addingTimeInterval(60)
        )
        XCTAssertEqual(later.raised.map(\.fact), [.listener(name: "node", isTCP: true, port: 3_000)])

        let gone = tracker.ingestListeners([logitech, airPlay], trusted: [airPlay.endpointKey], at: start.addingTimeInterval(120))
        XCTAssertEqual(gone.cleared.map(\.rule), [.newListener])
    }

    func testFactsReadAsPlainSentencesWithSysBarsNumbers() {
        XCTAssertEqual(
            AttentionFact.runaway(name: "Codex (Renderer)", cpuPercent: 155.7, minutes: 22).text,
            "Codex (Renderer) has used 156% CPU for 22 min"
        )
        XCTAssertEqual(
            AttentionFact.listener(name: "node", isTCP: true, port: 3_000).text,
            "node started accepting TCP connections on port 3000"
        )
    }

    func testForgettingASubjectLetsAGenuineRecurrenceRaiseAgainFromScratch() {
        var tracker = AttentionTracker()
        let first = feed(&tracker, cpu: { _ in 156 }, minutes: 6)
        let key = try? XCTUnwrap(first.raised.first?.id)
        XCTAssertNotNil(key)

        tracker.forget(key!)
        XCTAssertNil(tracker.active[key!])
        // A fix that held: the series starts empty, so one hot minute is not enough.
        XCTAssertTrue(feed(&tracker, cpu: { _ in 156 }, minutes: 1, from: 7 * 60).raised.isEmpty)
        XCTAssertEqual(feed(&tracker, cpu: { _ in 156 }, minutes: 5, from: 9 * 60).raised.map(\.id), [key!])
    }
}
