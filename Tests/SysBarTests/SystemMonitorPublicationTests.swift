import Combine
import Foundation
import XCTest
@testable import SysBar

@MainActor
final class SystemMonitorPublicationTests: XCTestCase {
    func testClosedChangingSummariesPublishStatusWithoutPublishingPanelOrSamplingProcesses() async {
        let samples = SummaryQueue([
            .success(cpu: 12, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 10)),
            .success(cpu: 34, freeMB: 7_168, sampledAt: Date(timeIntervalSince1970: 13))
        ])
        let processCounter = InvocationCounter()
        let monitor = SystemMonitor(
            autoStart: false,
            initialAlertsEnabled: false,
            summaryCollector: { await samples.next() },
            processCollector: {
                await processCounter.increment()
                return .success([])
            },
            portsCollector: { .success([]) },
            diskCollector: { .success(.empty) }
        )
        var statusPublications = 0
        var panelPublications = 0
        var cancellables: Set<AnyCancellable> = []
        monitor.statusModel.$summary.dropFirst().sink { _ in
            statusPublications += 1
        }.store(in: &cancellables)
        monitor.panelModel.$snapshot.dropFirst().sink { _ in
            panelPublications += 1
        }.store(in: &cancellables)

        monitor.tick(at: .zero)
        await monitor.waitForIdle()
        monitor.tick(at: .seconds(3))
        await monitor.waitForIdle()

        XCTAssertEqual(statusPublications, 2)
        XCTAssertEqual(panelPublications, 0)
        let processInvocations = await processCounter.currentValue()
        XCTAssertEqual(processInvocations, 0)
        XCTAssertEqual(monitor.statusModel.summary.title, " 34%  7.0G")
        XCTAssertEqual(
            monitor.statusModel.summary.accessibilityValue,
            "CPU 34 percent, 7.0 gigabytes memory available"
        )
    }

    func testOpeningPublishesCachedPanelImmediatelyAndStartsOneProcessSample() async {
        let sampledAt = Date(timeIntervalSince1970: 20)
        let samples = SummaryQueue([.success(cpu: 21, freeMB: 6_144, sampledAt: sampledAt)])
        let processCounter = InvocationCounter()
        let monitor = makeMonitor(
            summary: { await samples.next() },
            processes: {
                await processCounter.increment()
                return .success([])
            }
        )
        monitor.tick(at: .zero)
        await monitor.waitForIdle()
        var published: [PanelSnapshot] = []
        let cancellable = monitor.panelModel.$snapshot.dropFirst().sink { published.append($0) }

        monitor.panelDidOpen(at: .seconds(3), sampledAt: sampledAt)

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].cpu.value, 21)
        XCTAssertTrue(published[0].processes.isLoading)
        await monitor.waitForIdle()
        let processInvocations = await processCounter.currentValue()
        XCTAssertEqual(processInvocations, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testClosedTicksAfterOpenDoNotPublishPanelOrSampleProcesses() async {
        let samples = SummaryQueue([
            .success(cpu: 10, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 10)),
            .success(cpu: 20, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 20)),
            .success(cpu: 30, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 30)),
            .success(cpu: 40, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 40)),
            .success(cpu: 50, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 50))
        ])
        let processCounter = InvocationCounter()
        let monitor = makeMonitor(
            summary: { await samples.next() },
            processes: {
                await processCounter.increment()
                return .success([])
            }
        )
        monitor.panelDidOpen(at: .zero)
        await monitor.waitForIdle()
        monitor.panelDidClose(at: .seconds(1))
        var panelPublications = 0
        let cancellable = monitor.panelModel.$snapshot.dropFirst().sink { _ in
            panelPublications += 1
        }
        let before = await processCounter.currentValue()

        for second in [3, 6, 9] {
            monitor.tick(at: .seconds(Int64(second)))
            await monitor.waitForIdle()
        }

        XCTAssertEqual(panelPublications, 0)
        let after = await processCounter.currentValue()
        XCTAssertEqual(after, before)
        withExtendedLifetime(cancellable) {}
    }

    func testCloseAndReopenRejectsOldSessionProcessResult() async {
        let processProbe = ProcessProbe()
        let monitor = makeMonitor(processes: { await processProbe.collect() })
        monitor.panelDidOpen(at: .zero, sampledAt: Date(timeIntervalSince1970: 10))
        await processProbe.waitForInvocations(1)

        monitor.panelDidClose(at: .seconds(1))
        monitor.panelDidOpen(at: .seconds(2), sampledAt: Date(timeIntervalSince1970: 20))
        await processProbe.resolveNext(.success([Self.sample(pid: 111, name: "Old")]))
        await processProbe.waitForInvocations(2)

        XCTAssertTrue(monitor.panelModel.snapshot.processes.isLoading)
        await processProbe.resolveNext(.success([Self.sample(pid: 222, name: "New")]))
        await monitor.waitForIdle()

        XCTAssertEqual(monitor.panelModel.snapshot.processes.value?.topMemory.first?.pids, [222])
    }

    func testTenProcessRequestsCoalesceToOneActiveAndOneRepeat() async {
        let processProbe = ProcessProbe()
        let monitor = makeMonitor(processes: { await processProbe.collect() })
        monitor.panelDidOpen(at: .zero)
        await processProbe.waitForInvocations(1)

        for second in 1...10 {
            monitor.tick(at: .seconds(Int64(second)))
        }
        let activeCount = await processProbe.invocationCount()
        XCTAssertEqual(activeCount, 1)

        await processProbe.resolveNext(.success([]))
        await processProbe.waitForInvocations(2)
        await processProbe.resolveNext(.success([]))
        await monitor.waitForIdle()
        let finalCount = await processProbe.invocationCount()
        XCTAssertEqual(finalCount, 2)
    }

    func testClosingDrainsPendingProcessRequestWithoutStartingIt() async {
        let processProbe = ProcessProbe()
        let monitor = makeMonitor(processes: { await processProbe.collect() })
        monitor.panelDidOpen(at: .zero)
        await processProbe.waitForInvocations(1)
        for second in 1...10 {
            monitor.tick(at: .seconds(Int64(second)))
        }

        monitor.panelDidClose(at: .seconds(11))
        await processProbe.resolveNext(.success([]))
        await monitor.waitForIdle()

        let count = await processProbe.invocationCount()
        XCTAssertEqual(count, 1)
    }

    func testSuspendedPortsDoNotBlockSummaryOrProcessPipelines() async {
        let summaries = SummaryQueue([
            .success(cpu: 10, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 10)),
            .success(cpu: 20, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 20))
        ])
        let processCounter = InvocationCounter()
        let ports = PortsProbe()
        let monitor = SystemMonitor(
            autoStart: false,
            initialAlertsEnabled: false,
            summaryCollector: { await summaries.next() },
            processCollector: {
                await processCounter.increment()
                return .success([])
            },
            portsCollector: { await ports.collect() },
            diskCollector: { .success(.empty) }
        )
        monitor.panelDidOpen(at: .zero)
        await ports.waitForInvocations(1)
        monitor.tick(at: .seconds(3))

        await processCounter.waitForValue(2)
        XCTAssertEqual(monitor.statusModel.summary.title, " 20%  8.0G")
        let portCount = await ports.invocationCount()
        XCTAssertEqual(portCount, 1)

        await ports.resolveNext(.success([]))
        await monitor.waitForIdle()
    }

    func testCloseAndReopenRejectsOldSessionSlowResultBeforeQueuedRepeat() async {
        let ports = PortsProbe()
        let monitor = SystemMonitor(
            autoStart: false,
            initialAlertsEnabled: false,
            summaryCollector: {
                .success(cpu: 10, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 10))
            },
            processCollector: { .success([]) },
            portsCollector: { await ports.collect() },
            diskCollector: { .success(.empty) }
        )
        let oldSessionSocket = ListenSocket(
            pid: 42,
            processName: "Old Session",
            port: 8_080,
            bindAddress: "*",
            isTCP: true
        )
        monitor.panelDidOpen(at: .zero, sampledAt: Date(timeIntervalSince1970: 10))
        await ports.waitForInvocations(1)

        monitor.panelDidClose(at: .seconds(1))
        monitor.panelDidOpen(at: .seconds(15), sampledAt: Date(timeIntervalSince1970: 25))
        await ports.resolveNext(.success([oldSessionSocket]))
        await ports.waitForInvocations(2)

        XCTAssertTrue(monitor.panelModel.snapshot.listenPorts.isLoading)
        await ports.resolveNext(.success([]))
        await monitor.waitForIdle()
        XCTAssertEqual(
            monitor.panelModel.snapshot.listenPorts,
            .available([], sampledAt: Date(timeIntervalSince1970: 25))
        )
    }

    func testSummaryFailureRetainsLastGoodTimestampAndHistories() async {
        let sampledAt = Date(timeIntervalSince1970: 100)
        let failure = TelemetryError.collector("summary failed")
        let summaries = SummaryQueue([
            .success(cpu: 42, freeMB: 4_096, sampledAt: sampledAt),
            SummarySample(
                cpu: .failure(failure),
                memory: .failure(failure),
                swap: .failure(failure),
                network: .failure(failure),
                sampledAt: Date(timeIntervalSince1970: 103)
            )
        ])
        let monitor = makeMonitor(summary: { await summaries.next() })
        monitor.panelDidOpen(at: .zero)
        await monitor.waitForIdle()
        let histories = (
            monitor.panelModel.snapshot.cpuHistory,
            monitor.panelModel.snapshot.memoryHistory,
            monitor.panelModel.snapshot.swapHistory
        )

        monitor.tick(at: .seconds(3))
        await monitor.waitForIdle()

        XCTAssertEqual(
            monitor.panelModel.snapshot.cpu,
            .stale(42, sampledAt: sampledAt, error: failure)
        )
        XCTAssertEqual(monitor.panelModel.snapshot.memory.sampledAt, sampledAt)
        XCTAssertEqual(monitor.panelModel.snapshot.cpuHistory, histories.0)
        XCTAssertEqual(monitor.panelModel.snapshot.memoryHistory, histories.1)
        XCTAssertEqual(monitor.panelModel.snapshot.swapHistory, histories.2)
    }

    func testFirstSummaryFailureIsUnavailable() async {
        let failure = TelemetryError.permission("denied")
        let summaries = SummaryQueue([SummarySample(
            cpu: .failure(failure),
            memory: .failure(failure),
            swap: .failure(failure),
            network: .failure(failure),
            sampledAt: Date(timeIntervalSince1970: 100)
        )])
        let monitor = makeMonitor(summary: { await summaries.next() })

        monitor.panelDidOpen(at: .zero)
        await monitor.waitForIdle()

        XCTAssertEqual(monitor.panelModel.snapshot.cpu, .unavailable(failure))
        XCTAssertEqual(monitor.panelModel.snapshot.memory, .unavailable(failure))
        XCTAssertTrue(monitor.panelModel.snapshot.cpuHistory.isEmpty)
    }

    func testEmptyPortsAreAvailableAndFailureKeepsLastGoodBaseline() async {
        let ports = PortsQueue([
            .success([]),
            .failure(.collector("lsof failed"))
        ])
        let monitor = SystemMonitor(
            autoStart: false,
            initialAlertsEnabled: false,
            summaryCollector: { .success(cpu: 10, freeMB: 8_192, sampledAt: Date()) },
            processCollector: { .success([]) },
            portsCollector: { await ports.next() },
            diskCollector: { .success(.empty) }
        )
        monitor.panelDidOpen(at: .zero, sampledAt: Date(timeIntervalSince1970: 10))
        await monitor.waitForIdle()
        XCTAssertEqual(
            monitor.panelModel.snapshot.listenPorts,
            .available([], sampledAt: Date(timeIntervalSince1970: 10))
        )

        monitor.tick(at: .seconds(15), sampledAt: Date(timeIntervalSince1970: 25))
        await monitor.waitForIdle()
        XCTAssertEqual(
            monitor.panelModel.snapshot.listenPorts,
            .stale(
                [],
                sampledAt: Date(timeIntervalSince1970: 10),
                error: .collector("lsof failed")
            )
        )
    }

    func testQuickReopenRetriesDiscardedPortsAndDiskImmediately() async {
        let ports = PortsProbe()
        let disks = InvocationCounter()
        let monitor = SystemMonitor(
            autoStart: false,
            initialAlertsEnabled: false,
            summaryCollector: { .success(cpu: 10, freeMB: 8_192, sampledAt: Date()) },
            processCollector: { .success([]) },
            portsCollector: { await ports.collect() },
            diskCollector: {
                await disks.increment()
                return .success(.empty)
            }
        )
        monitor.panelDidOpen(at: .zero)
        await ports.waitForInvocations(1)
        monitor.panelDidClose(at: .seconds(1))
        monitor.panelDidOpen(at: .seconds(2))
        await ports.resolveNext(.success([]))
        await ports.waitForInvocations(2)
        await ports.resolveNext(.success([]))
        await monitor.waitForIdle()

        XCTAssertFalse(monitor.panelModel.snapshot.listenPorts.isLoading)
        XCTAssertFalse(monitor.panelModel.snapshot.disk.isLoading)
        let diskCount = await disks.currentValue()
        XCTAssertEqual(diskCount, 2)
    }

    func testStaleCloseDoesNotDiscardTheActiveSessionProcessSample() async {
        let processes = ProcessProbe()
        let monitor = makeMonitor(processes: { await processes.collect() })
        monitor.panelDidOpen(at: .seconds(10))
        await processes.waitForInvocations(1)

        monitor.panelDidClose(at: .seconds(9))
        await processes.resolveNext(.success([Self.sample(pid: 42, name: "Current")]))
        await monitor.waitForIdle()

        XCTAssertEqual(monitor.panelModel.snapshot.processes.value?.topMemory.first?.pids, [42])
    }

    func testShutdownRejectsLateResultsAndDrainsCoalescedWorkWithoutRestarting() async {
        let summaries = SummaryProbe()
        let processes = ProcessProbe()
        let ports = PortsProbe()
        let monitor = SystemMonitor(
            autoStart: false,
            initialAlertsEnabled: false,
            summaryCollector: { await summaries.collect() },
            processCollector: { await processes.collect() },
            portsCollector: { await ports.collect() },
            diskCollector: { .success(.empty) }
        )
        monitor.panelDidOpen(at: .zero)
        await summaries.waitForInvocations(1)
        await processes.waitForInvocations(1)
        await ports.waitForInvocations(1)
        monitor.tick(at: .seconds(3))
        let before = monitor.panelModel.snapshot
        let statusBefore = monitor.statusModel.summary
        var publications = 0
        let cancellable = monitor.panelModel.$snapshot.dropFirst().sink { _ in publications += 1 }

        monitor.shutdown()
        monitor.shutdown()
        monitor.tick(at: .seconds(6))
        monitor.panelDidClose(at: .seconds(7))
        monitor.panelDidOpen(at: .seconds(8))
        await summaries.resolveNext(.success(cpu: 99, freeMB: 100, sampledAt: Date()))
        await processes.resolveNext(.success([Self.sample(pid: 42, name: "Late")]))
        await ports.resolveNext(.success([]))
        await monitor.waitForIdle()

        let summaryCount = await summaries.invocationCount()
        let processCount = await processes.invocationCount()
        let portCount = await ports.invocationCount()
        XCTAssertEqual(summaryCount, 1)
        XCTAssertEqual(processCount, 1)
        XCTAssertEqual(portCount, 1)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(monitor.panelModel.snapshot, before)
        XCTAssertEqual(monitor.statusModel.summary, statusBefore)
        withExtendedLifetime(cancellable) {}
    }

    func testAnOpenTickPublishesThePanelOnceWithItsSummaryAndProcessesTogether() async {
        let summaries = SummaryQueue([
            .success(cpu: 11, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 10)),
            .success(cpu: 22, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 13))
        ])
        let processes = ProcessProbe()
        let monitor = makeMonitor(summary: { await summaries.next() }, processes: { await processes.collect() })
        var published: [PanelSnapshot] = []
        var monitorChanges = 0
        var cancellables: Set<AnyCancellable> = []
        monitor.panelModel.$snapshot.dropFirst().sink { published.append($0) }.store(in: &cancellables)
        monitor.objectWillChange.sink { monitorChanges += 1 }.store(in: &cancellables)

        monitor.panelDidOpen(at: .zero)
        await processes.waitForInvocations(1)
        await Self.waitForStatus(of: monitor) { $0.title.contains("11%") }

        XCTAssertEqual(published.count, 1, "only the cached panel shown on open; the summary waits for processes")
        XCTAssertNil(published[0].cpu.value)
        await processes.resolveNext(.success([Self.sample(pid: 42, name: "First")]))
        await monitor.waitForIdle()
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(published[1].cpu.value, 11)
        XCTAssertEqual(published[1].processes.value?.topCPU.first?.pids, [42])

        monitor.tick(at: .seconds(3))
        await processes.waitForInvocations(2)
        await Self.waitForStatus(of: monitor) { $0.title.contains("22%") }
        XCTAssertEqual(published.count, 2)
        await processes.resolveNext(.success([Self.sample(pid: 43, name: "Second")]))
        await monitor.waitForIdle()

        XCTAssertEqual(published.count, 3, "one publication per tick")
        XCTAssertEqual(published[2].cpu.value, 22)
        XCTAssertEqual(published[2].processes.value?.topCPU.first?.pids, [43])
        XCTAssertEqual(monitorChanges, 0, "panel publications never invalidate observers of the monitor itself")
    }

    func testARepeatPortScanThatFindsTheSameListenersRidesAlongWithTheNextTick() async {
        let socket = ListenSocket(pid: 42, processName: "node", port: 3_000, bindAddress: "127.0.0.1", isTCP: true)
        let monitor = SystemMonitor(
            autoStart: false,
            initialAlertsEnabled: false,
            summaryCollector: { .success(cpu: 10, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 10)) },
            processCollector: { .success([]) },
            portsCollector: { .success([socket]) },
            diskCollector: { .success(.empty) }
        )
        monitor.panelDidOpen(at: .zero, sampledAt: Date(timeIntervalSince1970: 10))
        await monitor.waitForIdle()
        XCTAssertEqual(monitor.panelModel.snapshot.listenPorts, .available([socket], sampledAt: Date(timeIntervalSince1970: 10)))
        var publications = 0
        let cancellable = monitor.panelModel.$snapshot.dropFirst().sink { _ in publications += 1 }

        monitor.tick(at: .seconds(15), sampledAt: Date(timeIntervalSince1970: 25))
        await monitor.waitForIdle()
        XCTAssertEqual(publications, 1, "the unchanged scan never publishes on its own")

        monitor.tick(at: .seconds(18), sampledAt: Date(timeIntervalSince1970: 28))
        await monitor.waitForIdle()
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(
            monitor.panelModel.snapshot.listenPorts,
            .available([socket], sampledAt: Date(timeIntervalSince1970: 25)),
            "the next publication carries the repeat scan"
        )
        withExtendedLifetime(cancellable) {}
    }

    func testASummaryHeldBehindAStuckProcessSamplePublishesAtTheNextTick() async {
        let summaries = SummaryQueue([
            .success(cpu: 31, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 10)),
            .success(cpu: 32, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 13))
        ])
        let processes = ProcessProbe()
        let monitor = makeMonitor(summary: { await summaries.next() }, processes: { await processes.collect() })
        monitor.panelDidOpen(at: .zero)
        await processes.waitForInvocations(1)
        await Self.waitForStatus(of: monitor) { $0.title.contains("31%") }
        XCTAssertNil(monitor.panelModel.snapshot.cpu.value)

        monitor.tick(at: .seconds(3))

        XCTAssertEqual(monitor.panelModel.snapshot.cpu.value, 31, "a stuck sample holds the panel for at most one tick")
        await processes.resolveNext(.success([]))
        await processes.waitForInvocations(2)
        await processes.resolveNext(.success([]))
        await monitor.waitForIdle()
        XCTAssertEqual(monitor.panelModel.snapshot.cpu.value, 32)
    }

    private static func waitForStatus(
        of monitor: SystemMonitor,
        _ condition: (StatusSummary) -> Bool
    ) async {
        while !condition(monitor.statusModel.summary) { await Task.yield() }
    }

    private func makeMonitor(
        summary: @escaping SummaryCollector = {
            .success(cpu: 10, freeMB: 8_192, sampledAt: Date(timeIntervalSince1970: 10))
        },
        processes: @escaping ProcessCollector = { .success([]) }
    ) -> SystemMonitor {
        SystemMonitor(
            autoStart: false,
            initialAlertsEnabled: false,
            summaryCollector: summary,
            processCollector: processes,
            portsCollector: { .success([]) },
            diskCollector: { .success(.empty) }
        )
    }

    private static func sample(pid: Int32, name: String) -> ProcSample {
        ProcSample(
            pid: pid,
            startTime: ProcessStartTime(seconds: UInt64(pid), microseconds: 0),
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            name: name,
            cpuPercent: 1,
            residentMB: 100
        )
    }
}

private actor InvocationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
    func currentValue() -> Int { value }

    func waitForValue(_ target: Int) async {
        while value < target { await Task.yield() }
    }
}

private actor SummaryQueue {
    private var values: [SummarySample]

    init(_ values: [SummarySample]) {
        self.values = values
    }

    func next() -> SummarySample {
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}

private actor ProcessProbe {
    private var continuations: [CheckedContinuation<Result<[ProcSample], TelemetryError>, Never>] = []
    private var invocations = 0

    func collect() async -> Result<[ProcSample], TelemetryError> {
        invocations += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func waitForInvocations(_ target: Int) async {
        while invocations < target { await Task.yield() }
    }

    func invocationCount() -> Int { invocations }

    func resolveNext(_ result: Result<[ProcSample], TelemetryError>) {
        continuations.removeFirst().resume(returning: result)
    }
}

private actor PortsProbe {
    private var continuations: [CheckedContinuation<Result<[ListenSocket], TelemetryError>, Never>] = []
    private var invocations = 0

    func collect() async -> Result<[ListenSocket], TelemetryError> {
        invocations += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func waitForInvocations(_ target: Int) async {
        while invocations < target { await Task.yield() }
    }

    func invocationCount() -> Int { invocations }

    func resolveNext(_ result: Result<[ListenSocket], TelemetryError>) {
        continuations.removeFirst().resume(returning: result)
    }
}

private actor PortsQueue {
    private var values: [Result<[ListenSocket], TelemetryError>]

    init(_ values: [Result<[ListenSocket], TelemetryError>]) {
        self.values = values
    }

    func next() -> Result<[ListenSocket], TelemetryError> {
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}

private extension SummarySample {
    static func success(cpu: Double, freeMB: Int, sampledAt: Date) -> SummarySample {
        SummarySample(
            cpu: .success(cpu),
            memory: .success(MemorySnapshot(usedGB: 8, freeMB: freeMB, totalGB: 16)),
            swap: .success(.empty),
            network: .success(.empty),
            sampledAt: sampledAt
        )
    }
}

private actor SummaryProbe {
    private var continuations: [CheckedContinuation<SummarySample, Never>] = []
    private var invocations = 0

    func collect() async -> SummarySample {
        invocations += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func waitForInvocations(_ target: Int) async {
        while invocations < target { await Task.yield() }
    }

    func invocationCount() -> Int { invocations }

    func resolveNext(_ result: SummarySample) {
        continuations.removeFirst().resume(returning: result)
    }
}
