import Darwin
import Foundation
import XCTest
@testable import SysBar

final class ProcessActionTests: XCTestCase {
    func testPIDReuseAtPreflightRejectsTheActionWithoutSendingASignal() async {
        let expected = identity(pid: 42, seconds: 100, path: "/bin/demo")
        let replacement = identity(pid: 42, seconds: 101, path: "/bin/demo")
        let harness = Harness(selfPID: 999)
        harness.reader.script(replacement, resolutionCount: 1)

        let report = await harness.service.perform(.terminate, on: [expected])

        XCTAssertEqual(report.results, [
            ProcessActionMemberResult(identity: expected, outcome: .notSignaled(.staleIdentity(observed: replacement)))
        ])
        XCTAssertTrue(harness.sender.calls.isEmpty)
    }

    func testExecutablePathChangeAtPreflightRejectsTheActionWithoutSendingASignal() async {
        let expected = identity(pid: 42, path: "/Applications/Old.app/Contents/MacOS/demo")
        let replacement = identity(pid: 42, path: "/Applications/New.app/Contents/MacOS/demo")
        let harness = Harness(selfPID: 999)
        harness.reader.script(replacement, resolutionCount: 1)

        let report = await harness.service.perform(.terminate, on: [expected])

        XCTAssertEqual(report.results.first?.outcome, .notSignaled(.staleIdentity(observed: replacement)))
        XCTAssertTrue(harness.sender.calls.isEmpty)
    }

    func testAnyStaleGroupMemberAbortsTheWholePreflightWithoutSignals() async {
        let first = identity(pid: 10, path: "/bin/demo")
        let second = identity(pid: 20, path: "/bin/demo")
        let replacement = identity(pid: 20, seconds: second.startTime.seconds + 1, path: "/bin/demo")
        let harness = Harness(selfPID: 999)
        harness.reader.script(first, resolutionCount: 1)
        harness.reader.script(replacement, resolutionCount: 1)

        let report = await harness.service.perform(.terminate, on: [first, second])

        XCTAssertEqual(report.results.map(\.outcome), [
            .notSignaled(.preflightAborted),
            .notSignaled(.staleIdentity(observed: replacement))
        ])
        XCTAssertTrue(harness.sender.calls.isEmpty)
    }

    func testEachMemberIsResolvedAgainImmediatelyBeforeItsSignal() async {
        let first = identity(pid: 10, path: "/bin/demo")
        let second = identity(pid: 20, path: "/bin/demo")
        let harness = Harness(selfPID: 999)
        harness.reader.script(first, resolutionCount: 2)
        harness.reader.script(second, resolutionCount: 2)

        let report = await harness.service.perform(.terminate, on: [first, second])

        XCTAssertEqual(report.results.map(\.outcome), [.signaled, .signaled])
        XCTAssertEqual(harness.log.events, [
            "bsd:10", "path:10", "bsd:10",
            "bsd:20", "path:20", "bsd:20",
            "bsd:10", "path:10", "bsd:10", "signal:term:10",
            "bsd:20", "path:20", "bsd:20", "signal:term:20"
        ])
    }

    func testSecondSignalFailurePreservesPriorSuccessAndReportsErrno() async {
        let first = identity(pid: 10, path: "/bin/demo")
        let second = identity(pid: 20, path: "/bin/demo")
        let harness = Harness(selfPID: 999)
        harness.reader.script(first, resolutionCount: 2)
        harness.reader.script(second, resolutionCount: 2)
        harness.sender.fail(pid: 20, with: ProcessSignalError(errnoCode: EPERM))

        let report = await harness.service.perform(.forceKill, on: [first, second])

        XCTAssertEqual(report.results.map(\.outcome), [
            .signaled,
            .notSignaled(.signalFailed(ProcessSignalError(errnoCode: EPERM)))
        ])
        XCTAssertEqual(harness.sender.calls, [
            SignalCall(signal: .forceKill, pid: 10),
            SignalCall(signal: .forceKill, pid: 20)
        ])
    }

    func testConcurrentRequestedActionsSerializeSignalSending() async {
        let expected = identity(pid: 42, path: "/bin/demo")
        let sender = BlockingProcessSignalSender()
        let service = ProcessActionService(
            identityReader: ConstantProcessIdentityReader(identity: expected),
            signalSender: sender,
            selfPID: 999
        )

        let firstTask = Task.detached {
            await service.perform(.terminate, on: [expected])
        }
        XCTAssertEqual(sender.firstSignalEntered.wait(timeout: .now() + 1), .success)

        let secondRequestStarted = DispatchSemaphore(value: 0)
        let secondTask = Task.detached {
            secondRequestStarted.signal()
            return await service.perform(.terminate, on: [expected])
        }
        XCTAssertEqual(secondRequestStarted.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(sender.secondSignalEntered.wait(timeout: .now() + 0.25), .timedOut)
        XCTAssertEqual(sender.maxInFlight, 1)

        sender.releaseFirstSignal.signal()
        let firstReport = await firstTask.value
        let secondReport = await secondTask.value

        XCTAssertEqual(firstReport.results.map(\.outcome), [.signaled])
        XCTAssertEqual(secondReport.results.map(\.outcome), [.signaled])
        XCTAssertEqual(sender.maxInFlight, 1)
    }

    func testSystemAndSelfPIDsAreRejectedBeforeIdentityReads() async {
        let system = identity(pid: 1, path: "/sbin/launchd")
        let ownProcess = identity(pid: 42, path: "/Applications/SysBar.app/Contents/MacOS/SysBar")
        let harness = Harness(selfPID: 42)

        let report = await harness.service.perform(.terminate, on: [system, ownProcess])

        XCTAssertEqual(report.results.map(\.outcome), [
            .notSignaled(.unsafePID),
            .notSignaled(.unsafePID)
        ])
        XCTAssertTrue(harness.log.events.isEmpty)
        XCTAssertTrue(harness.sender.calls.isEmpty)
    }

    func testIdleZombieAndInExitProcessesAreRejectedWithoutSignals() async {
        let cases: [(ProcessUnsafeState, UInt32, UInt32)] = [
            (.idle, UInt32(SIDL), 0),
            (.zombie, UInt32(SZOMB), 0),
            (.inExit, UInt32(SRUN), UInt32(PROC_FLAG_INEXIT))
        ]

        for (unsafeState, status, flags) in cases {
            let expected = identity(pid: 42, path: "/bin/demo")
            let harness = Harness(selfPID: 999)
            harness.reader.script(
                expected,
                resolutionCount: 1,
                status: status,
                flags: flags
            )

            let report = await harness.service.perform(.terminate, on: [expected])

            XCTAssertEqual(
                report.results.first?.outcome,
                .notSignaled(.identityReadFailed(.unsafeState(pid: 42, state: unsafeState)))
            )
            XCTAssertTrue(harness.sender.calls.isEmpty)
        }
    }

    func testIdentityChangingBetweenBSDReadsIsRejected() async {
        let expected = identity(pid: 42, seconds: 100, path: "/bin/demo")
        let replacement = identity(pid: 42, seconds: 101, path: "/bin/demo")
        let harness = Harness(selfPID: 999)
        harness.reader.setBSDResponses([
            .value(ProcessBSDIdentitySnapshot(identity: expected)),
            .value(ProcessBSDIdentitySnapshot(identity: replacement))
        ], for: 42)
        harness.reader.setPathResponses([.value(expected.executablePath)], for: 42)

        let report = await harness.service.perform(.terminate, on: [expected])

        XCTAssertEqual(
            report.results.first?.outcome,
            .notSignaled(.identityReadFailed(.changedDuringRead(pid: 42)))
        )
        XCTAssertTrue(harness.sender.calls.isEmpty)
    }

    func testSocketCollectionAttachesPreCapturedIdentityAfterMatchingPostvalidation() throws {
        let expected = identity(pid: 77, path: "/Applications/Demo.app/Contents/MacOS/Demo")
        let log = CallLog()
        let reader = ScriptedProcessIdentityReader(log: log)
        reader.script(expected, resolutionCount: 1)
        let runner = StaticLsofRunner(output: """
        p77
        cDemo
        f1
        PTCP
        n*:8080
        f2
        PTCP
        n127.0.0.1:8081
        """)

        let sockets = try PortsAPI.fetchResult(
            runner: runner,
            expectedIdentities: [77: expected],
            postValidationReader: reader,
            timeout: 1
        ).get()

        XCTAssertEqual(sockets.count, 2)
        XCTAssertTrue(sockets.allSatisfy { $0.processIdentity == expected })
        XCTAssertEqual(log.events, ["bsd:77", "path:77", "bsd:77"])
    }

    func testSocketCollectionDoesNotAttachReplacementObservedAfterLsof() throws {
        let expected = identity(pid: 77, seconds: 100, path: "/Applications/Old.app/Contents/MacOS/Demo")
        let replacement = identity(pid: 77, seconds: 101, path: "/Applications/New.app/Contents/MacOS/Demo")
        let log = CallLog()
        let reader = ScriptedProcessIdentityReader(log: log)
        reader.script(replacement, resolutionCount: 1)

        let sockets = try PortsAPI.fetchResult(
            runner: StaticLsofRunner(output: """
            p77
            cDemo
            f1
            PTCP
            n*:8080
            """),
            expectedIdentities: [77: expected],
            postValidationReader: reader,
            timeout: 1
        ).get()

        XCTAssertNil(sockets.first?.processIdentity)
        XCTAssertEqual(log.events, ["bsd:77", "path:77", "bsd:77"])
    }

    func testParsedOrUnreadableSocketIsNonActionable() throws {
        let parsed = PortsAPI.parseLsofOutput("""
        p77
        cDemo
        f1
        PTCP
        n*:8080
        """)
        XCTAssertNil(parsed.first?.processIdentity)

        let log = CallLog()
        let reader = ScriptedProcessIdentityReader(log: log)
        reader.setBSDResponses([.missing], for: 77)
        let collected = try PortsAPI.fetchResult(
            runner: StaticLsofRunner(output: """
            p77
            cDemo
            f1
            PTCP
            n*:8080
            """),
            expectedIdentities: [77: identity(pid: 77, path: "/Applications/Demo.app/Contents/MacOS/Demo")],
            postValidationReader: reader,
            timeout: 1
        ).get()

        XCTAssertNil(collected.first?.processIdentity)
        XCTAssertEqual(log.events, ["bsd:77"])
    }

    // ADR-019: the named production ports collector
    // never attaches a process identity. Pinned against this test process's own
    // real loopback listener, which must be found first, so an empty or failed
    // scan can never pass. If the factory were rewired to an identity-attaching
    // overload with a real reader, our own PID would resolve and this would fail.
    func testDefaultPortsCollectorLeavesARealLoopbackListenerOwnedByThisProcessWithoutIdentity() async throws {
        try requireSystemLsof()
        let listener = try LoopbackTCPListener()
        defer { listener.close() }

        let sockets = try await SystemMonitor.defaultPortsCollector().get()

        let ours = try XCTUnwrap(
            sockets.first {
                $0.pid == getpid() && $0.port == listener.port && $0.isTCP && $0.bindAddress == "127.0.0.1"
            },
            "lsof must observe this test's own listener, otherwise the identity assertion would be vacuous"
        )
        XCTAssertNil(ours.processIdentity)
        XCTAssertTrue(sockets.allSatisfy { $0.processIdentity == nil })
    }

    // ADR-019: a SystemMonitor built with no injected
    // portsCollector (exactly how the app builds it) publishes identity-free
    // listener rows. Fails if init ever stops installing defaultPortsCollector.
    @MainActor
    func testMonitorBuiltWithoutAnInjectedPortsCollectorPublishesIdentityFreeListenerRows() async throws {
        try requireSystemLsof()
        let listener = try LoopbackTCPListener()
        defer { listener.close() }
        // portsCollector is deliberately omitted so init installs the production
        // default. Alerts off selects transient app services (no real
        // notification center or login item).
        let monitor = SystemMonitor(
            autoStart: false,
            initialAlertsEnabled: false,
            summaryCollector: {
                SummarySample(
                    cpu: .success(0),
                    memory: .success(.empty),
                    swap: .success(.empty),
                    network: .success(.empty),
                    sampledAt: Date()
                )
            },
            processCollector: { .success([]) },
            diskCollector: { .success(.empty) }
        )
        defer { monitor.shutdown() }

        // Ports are due on the first panel open.
        monitor.panelDidOpen(at: .zero)
        let settled = await waitForFirstPortsResult(on: monitor, within: 30)
        guard settled else {
            XCTFail("The production ports collector did not publish within 30 s")
            return
        }
        await monitor.waitForIdle()

        let state = monitor.panelModel.snapshot.listenPorts
        guard case let .available(sockets, _) = state else {
            XCTFail("Expected an available listener scan, got \(state)")
            return
        }
        let ours = try XCTUnwrap(
            sockets.first {
                $0.pid == getpid() && $0.port == listener.port && $0.isTCP && $0.bindAddress == "127.0.0.1"
            },
            "lsof must observe this test's own listener, otherwise the identity assertion would be vacuous"
        )
        XCTAssertNil(ours.processIdentity)
        XCTAssertTrue(sockets.allSatisfy { $0.processIdentity == nil })
    }

    /// Skips only when the real scanner is absent. A failed scan or a missing
    /// socket stays a hard failure; skipping on those would reintroduce vacuity.
    private func requireSystemLsof() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else {
            throw XCTSkip("/usr/sbin/lsof is not available; ADR-019 pinning needs the real scanner")
        }
    }

    /// Bounded wait for the monitor's first ports result. The production runner
    /// is itself bounded (5 s timeout plus reap ladder and drain grace); the
    /// generous ceiling only turns a wedged pipeline into a failure, not a hang.
    @MainActor
    private func waitForFirstPortsResult(
        on monitor: SystemMonitor,
        within seconds: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while monitor.panelModel.snapshot.listenPorts.isLoading {
            guard Date() < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    private func identity(
        pid: Int32,
        seconds: UInt64 = 1_700_000_000,
        microseconds: UInt64 = 123_456,
        path: String
    ) -> ProcessIdentity {
        guard let identity = ProcessIdentity(
            pid: pid,
            startTime: ProcessStartTime(seconds: seconds, microseconds: microseconds),
            executablePath: path
        ) else {
            XCTFail("Test identity should be valid")
            fatalError("Invalid test identity")
        }
        return identity
    }
}

private final class Harness {
    let log = CallLog()
    let reader: ScriptedProcessIdentityReader
    let sender: RecordingProcessSignalSender
    let service: ProcessActionService

    init(selfPID: Int32) {
        reader = ScriptedProcessIdentityReader(log: log)
        sender = RecordingProcessSignalSender(log: log)
        service = ProcessActionService(
            identityReader: reader,
            signalSender: sender,
            selfPID: selfPID
        )
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func append(_ event: String) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private enum ScriptedValue<Value> {
    case value(Value)
    case missing

    var optional: Value? {
        switch self {
        case let .value(value): return value
        case .missing: return nil
        }
    }
}

private final class ScriptedProcessIdentityReader: ProcessIdentityReading, @unchecked Sendable {
    private let lock = NSLock()
    private var bsdResponses: [Int32: [ScriptedValue<ProcessBSDIdentitySnapshot>]] = [:]
    private var pathResponses: [Int32: [ScriptedValue<String>]] = [:]
    private let log: CallLog

    init(log: CallLog) {
        self.log = log
    }

    func script(
        _ identity: ProcessIdentity,
        resolutionCount: Int,
        status: UInt32 = UInt32(SRUN),
        flags: UInt32 = 0
    ) {
        let bsd = ProcessBSDIdentitySnapshot(
            pid: identity.pid,
            startTime: identity.startTime,
            status: status,
            flags: flags
        )
        lock.lock()
        for _ in 0..<resolutionCount {
            bsdResponses[identity.pid, default: []].append(contentsOf: [.value(bsd), .value(bsd)])
            pathResponses[identity.pid, default: []].append(.value(identity.executablePath))
        }
        lock.unlock()
    }

    func setBSDResponses(
        _ responses: [ScriptedValue<ProcessBSDIdentitySnapshot>],
        for pid: Int32
    ) {
        lock.lock()
        bsdResponses[pid] = responses
        lock.unlock()
    }

    func setPathResponses(_ responses: [ScriptedValue<String>], for pid: Int32) {
        lock.lock()
        pathResponses[pid] = responses
        lock.unlock()
    }

    func readBSDInfo(for pid: Int32) -> ProcessBSDIdentitySnapshot? {
        log.append("bsd:\(pid)")
        lock.lock()
        defer { lock.unlock() }
        return pop(&bsdResponses, pid: pid)?.optional
    }

    func readExecutablePath(for pid: Int32) -> String? {
        log.append("path:\(pid)")
        lock.lock()
        defer { lock.unlock() }
        return pop(&pathResponses, pid: pid)?.optional
    }

    private func pop<Value>(
        _ scripts: inout [Int32: [ScriptedValue<Value>]],
        pid: Int32
    ) -> ScriptedValue<Value>? {
        guard var values = scripts[pid], !values.isEmpty else { return nil }
        let next = values.removeFirst()
        scripts[pid] = values
        return next
    }
}

private struct SignalCall: Equatable {
    let signal: ProcessSignal
    let pid: Int32
}

private final class RecordingProcessSignalSender: ProcessSignalSending, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Int32: ProcessSignalError] = [:]
    private var recordedCalls: [SignalCall] = []
    private let log: CallLog

    var calls: [SignalCall] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    init(log: CallLog) {
        self.log = log
    }

    func fail(pid: Int32, with error: ProcessSignalError) {
        lock.lock()
        failures[pid] = error
        lock.unlock()
    }

    func send(_ signal: ProcessSignal, to pid: Int32) -> Result<Void, ProcessSignalError> {
        lock.lock()
        recordedCalls.append(SignalCall(signal: signal, pid: pid))
        let failure = failures[pid]
        lock.unlock()
        log.append("signal:\(signal == .terminate ? "term" : "kill"):\(pid)")
        if let failure {
            return .failure(failure)
        }
        return .success(())
    }
}

private struct StaticLsofRunner: LsofCommandRunning {
    let output: String

    func run(timeout: TimeInterval) throws -> LsofCommandOutput {
        LsofCommandOutput(stdout: Data(output.utf8), terminationStatus: 0)
    }
}

/// A real IPv4 TCP listener bound to 127.0.0.1 on an ephemeral port. It never
/// binds INADDR_ANY, so there is no LAN exposure and no firewall prompt. The
/// owning test closes it explicitly; `deinit` is only a backstop.
private final class LoopbackTCPListener {
    let port: UInt16
    private var descriptor: Int32

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            let error = Self.currentPOSIXError()
            Darwin.close(descriptor)
            throw error
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            let error = Self.currentPOSIXError()
            Darwin.close(descriptor)
            throw error
        }
        let port = UInt16(bigEndian: assigned.sin_port)
        guard port != 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }

        self.descriptor = descriptor
        self.port = port
    }

    deinit {
        close()
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private struct ConstantProcessIdentityReader: ProcessIdentityReading {
    let identity: ProcessIdentity

    func readBSDInfo(for pid: Int32) -> ProcessBSDIdentitySnapshot? {
        guard pid == identity.pid else { return nil }
        return ProcessBSDIdentitySnapshot(identity: identity)
    }

    func readExecutablePath(for pid: Int32) -> String? {
        pid == identity.pid ? identity.executablePath : nil
    }
}

private final class BlockingProcessSignalSender: ProcessSignalSending, @unchecked Sendable {
    let firstSignalEntered = DispatchSemaphore(value: 0)
    let secondSignalEntered = DispatchSemaphore(value: 0)
    let releaseFirstSignal = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var callCount = 0
    private var inFlight = 0
    private var recordedMaxInFlight = 0

    var maxInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedMaxInFlight
    }

    func send(_ signal: ProcessSignal, to pid: Int32) -> Result<Void, ProcessSignalError> {
        lock.lock()
        callCount += 1
        let ordinal = callCount
        inFlight += 1
        recordedMaxInFlight = max(recordedMaxInFlight, inFlight)
        lock.unlock()

        if ordinal == 1 {
            firstSignalEntered.signal()
            _ = releaseFirstSignal.wait(timeout: .now() + 2)
        } else if ordinal == 2 {
            secondSignalEntered.signal()
        }

        lock.lock()
        inFlight -= 1
        lock.unlock()
        return .success(())
    }
}
