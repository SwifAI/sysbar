import Darwin
import Foundation
import XCTest
@testable import SysBar

/// A fixed lsof result, recording how often the scan ran.
final class ListenerScanStub: LsofCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let output: String
    private let failure: LsofCommandRunnerError?
    private var recordedRuns = 0

    init(_ output: String, failure: LsofCommandRunnerError? = nil) {
        self.output = output
        self.failure = failure
    }

    var runs: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRuns
    }

    func run(timeout: TimeInterval) throws -> LsofCommandOutput {
        lock.lock()
        recordedRuns += 1
        lock.unlock()
        if let failure { throw failure }
        return LsofCommandOutput(stdout: Data(output.utf8), terminationStatus: output.isEmpty ? 1 : 0)
    }

    static func listening(pid: Int32, name: String, endpoint: String, transport: String = "TCP") -> ListenerScanStub {
        ListenerScanStub("p\(pid)\nc\(name)\nf5\nP\(transport)\nn\(endpoint)\n")
    }
}

/// Whatever process currently holds a PID, as libproc would report it.
final class FixedIdentityReader: ProcessIdentityReading, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ProcessIdentity?

    init(_ identity: ProcessIdentity?) {
        current = identity
    }

    func replace(with identity: ProcessIdentity?) {
        lock.lock()
        current = identity
        lock.unlock()
    }

    private var identity: ProcessIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func readBSDInfo(for pid: Int32) -> ProcessBSDIdentitySnapshot? {
        guard let identity, identity.pid == pid else { return nil }
        return ProcessBSDIdentitySnapshot(identity: identity)
    }

    func readExecutablePath(for pid: Int32) -> String? {
        guard let identity, identity.pid == pid else { return nil }
        return identity.executablePath
    }
}

final class SignalRecorder: ProcessSignalSending, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int32] = []

    var pids: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ signal: ProcessSignal, to pid: Int32) -> Result<Void, ProcessSignalError> {
        lock.lock()
        recorded.append(pid)
        lock.unlock()
        return .success(())
    }
}

final class ListenerStopTests: XCTestCase {
    static let nodePath = "/opt/homebrew/bin/node"

    static func node(pid: Int32 = 812, startedAt seconds: UInt64 = 1_000, path: String = nodePath) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: ProcessStartTime(seconds: seconds, microseconds: 1), executablePath: path)!
    }

    static let target = ListenerStopTarget(
        port: ListenSocket(pid: 812, processName: "node", port: 3_000, bindAddress: "*", isTCP: true),
        executablePath: nodePath
    )

    private func ownership(
        scan: ListenerScanStub,
        expected: ProcessIdentity = node(),
        nowHoldingPID: ProcessIdentity? = node()
    ) -> ListenerOwnership {
        PortsAPI.ownership(
            of: Self.target,
            expected: expected,
            runner: scan,
            reader: FixedIdentityReader(nowHoldingPID),
            timeout: 1
        )
    }

    func testTheSameProcessInstanceStillOnTheExactEndpointIsConfirmed() {
        XCTAssertEqual(ownership(scan: .listening(pid: 812, name: "node", endpoint: "*:3000 (LISTEN)")), .confirmed)
    }

    func testARecycledPIDOnTheSamePortIsNeverConfirmedBecauseItsStartTimeDiffers() {
        let recycled = Self.node(startedAt: 2_000)
        XCTAssertEqual(
            ownership(scan: .listening(pid: 812, name: "node", endpoint: "*:3000"), nowHoldingPID: recycled),
            .changed
        )
        XCTAssertEqual(
            ownership(scan: .listening(pid: 812, name: "node", endpoint: "*:3000"), nowHoldingPID: nil),
            .changed,
            "a PID that exited during the scan proves nothing"
        )
    }

    func testAnEndpointNowOwnedByADifferentProcessIsRefused() {
        XCTAssertEqual(ownership(scan: .listening(pid: 999, name: "node", endpoint: "*:3000")), .otherOwner)
    }

    func testAClosedEndpointIsReportedClosedEvenWhenTheProcessListensElsewhere() {
        XCTAssertEqual(ownership(scan: ListenerScanStub("")), .closed)
        XCTAssertEqual(ownership(scan: .listening(pid: 812, name: "node", endpoint: "*:3001")), .closed)
        XCTAssertEqual(ownership(scan: .listening(pid: 812, name: "node", endpoint: "127.0.0.1:3000")), .closed)
        XCTAssertEqual(ownership(scan: .listening(pid: 812, name: "node", endpoint: "*:3000", transport: "UDP")), .closed)
    }

    func testAFailedOrOversizedScanProvesNothing() {
        XCTAssertEqual(ownership(scan: ListenerScanStub("", failure: .timedOut)), .unverified)
        XCTAssertEqual(ownership(scan: ListenerScanStub("", failure: .outputTooLarge)), .unverified)
    }

    func testAProcessThatIsNotTheOneTheOwnerConfirmedIsNeverConfirmed() {
        let scan = ListenerScanStub.listening(pid: 812, name: "node", endpoint: "*:3000")
        let moved = Self.node(path: "/tmp/node")
        XCTAssertEqual(ownership(scan: scan, expected: moved, nowHoldingPID: moved), .changed, "path differs from the scan's")
        XCTAssertEqual(
            ownership(scan: .listening(pid: 812, name: "python3", endpoint: "*:3000")),
            .changed,
            "lsof names a different program"
        )

        let otherPID = ListenerScanStub.listening(pid: 812, name: "node", endpoint: "*:3000")
        XCTAssertEqual(ownership(scan: otherPID, expected: Self.node(pid: 813)), .changed)
        XCTAssertEqual(otherPID.runs, 0, "a mismatched identity never even starts lsof")
    }
}
