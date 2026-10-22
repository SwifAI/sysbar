import Foundation
import IOKit.pwr_mgt
import XCTest
@testable import SysBar

@MainActor
final class KeepAwakeTests: XCTestCase {
    // Off after init; turning on
    // creates exactly one PreventUserIdleDisplaySleep assertion and reads "on" on success.
    func testTurningKeepAwakeOnCreatesExactlyOneDisplaySleepAssertionAndReadsOn() {
        let power = RecordingPowerAssertionController(outcomes: [.success(assertionID: 42)])
        let monitor = makeMonitor(power)
        XCTAssertFalse(monitor.caffeinated)
        XCTAssertEqual(power.creations, [])

        monitor.toggleCaffeinate()

        XCTAssertTrue(monitor.caffeinated)
        XCTAssertEqual(power.creations, [
            .init(
                type: "PreventUserIdleDisplaySleep",
                level: IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name: "SysBar caffeinate",
                incomingID: 0
            )
        ])
        XCTAssertEqual(power.releases, [])
    }

    // A failed create that writes a nonzero ID stays off, and
    // shutdown() releases nothing, because the ID it does not own was reset.
    func testFailedCreateThatWritesANonzeroIDStaysOffAndShutdownReleasesNothing() {
        let power = RecordingPowerAssertionController(outcomes: [
            .failure(simulatedIOReturnError, writing: 0xBAD)
        ])
        let monitor = makeMonitor(power)

        monitor.toggleCaffeinate()

        XCTAssertFalse(monitor.caffeinated)
        XCTAssertEqual(power.creations.count, 1)
        monitor.shutdown()
        XCTAssertEqual(power.releases, [])
        XCTAssertFalse(monitor.caffeinated)
    }

    // A failed create that leaves the ID untouched stays off,
    // and shutdown() releases nothing.
    func testFailedCreateThatLeavesTheIDUntouchedStaysOffAndShutdownReleasesNothing() {
        let power = RecordingPowerAssertionController(outcomes: [
            .failure(simulatedIOReturnError, writing: nil)
        ])
        let monitor = makeMonitor(power)

        monitor.toggleCaffeinate()

        XCTAssertFalse(monitor.caffeinated)
        monitor.shutdown()
        XCTAssertEqual(power.creations.count, 1)
        XCTAssertEqual(power.releases, [])
    }

    // A retry after a failed create starts from a reset
    // ID of 0, and toggle-off releases only the assertion the successful create returned.
    func testRetryAfterAFailedCreateStartsFromAResetIDAndToggleOffReleasesOnlyTheOwnedAssertion() {
        let power = RecordingPowerAssertionController(outcomes: [
            .failure(simulatedIOReturnError, writing: 0xBAD),
            .success(assertionID: 42)
        ])
        let monitor = makeMonitor(power)

        monitor.toggleCaffeinate()
        XCTAssertFalse(monitor.caffeinated)
        monitor.toggleCaffeinate()
        XCTAssertTrue(monitor.caffeinated)
        monitor.toggleCaffeinate()

        XCTAssertFalse(monitor.caffeinated)
        XCTAssertEqual(power.creations.map(\.incomingID), [0, 0])
        XCTAssertEqual(power.releases, [42])
        monitor.shutdown()
        XCTAssertEqual(power.releases, [42])
    }

    // Toggle-off releases exactly the created
    // assertion once and resets the ID, so a later shutdown() releases nothing more.
    func testTurningKeepAwakeOffReleasesExactlyTheCreatedAssertionOnceAndShutdownReleasesNothingMore() {
        let power = RecordingPowerAssertionController(outcomes: [.success(assertionID: 42)])
        let monitor = makeMonitor(power)
        monitor.toggleCaffeinate()

        monitor.toggleCaffeinate()

        XCTAssertFalse(monitor.caffeinated)
        XCTAssertEqual(power.releases, [42])
        monitor.shutdown()
        XCTAssertEqual(power.creations.count, 1)
        XCTAssertEqual(power.releases, [42])
    }

    // A shutdown() while on releases the assertion once,
    // and a second shutdown() releases nothing.
    func testShutdownWhileOnReleasesTheAssertionOnceAndASecondShutdownReleasesNothing() {
        let power = RecordingPowerAssertionController(outcomes: [.success(assertionID: 42)])
        let monitor = makeMonitor(power)
        monitor.toggleCaffeinate()

        monitor.shutdown()

        XCTAssertFalse(monitor.caffeinated)
        XCTAssertEqual(power.releases, [42])
        monitor.shutdown()
        XCTAssertEqual(power.releases, [42])
    }

    // Boundary: after shutdown() a toggle creates no assertion, so nothing can
    // be created after teardown and then leak.
    func testTogglingKeepAwakeAfterShutdownCreatesNoAssertion() {
        let power = RecordingPowerAssertionController(outcomes: [.success(assertionID: 42)])
        let monitor = makeMonitor(power)
        monitor.shutdown()

        monitor.toggleCaffeinate()

        XCTAssertFalse(monitor.caffeinated)
        XCTAssertEqual(power.creations, [])
        XCTAssertEqual(power.releases, [])
    }

    private func makeMonitor(_ power: RecordingPowerAssertionController) -> SystemMonitor {
        SystemMonitor(
            autoStart: false,
            initialAlertsEnabled: false,
            summaryCollector: {
                SummarySample(
                    cpu: .success(10),
                    memory: .success(MemorySnapshot(usedGB: 8, freeMB: 8_192, totalGB: 16)),
                    swap: .success(.empty),
                    network: .success(.empty),
                    sampledAt: Date(timeIntervalSince1970: 10)
                )
            },
            processCollector: { .success([]) },
            portsCollector: { .success([]) },
            diskCollector: { .success(.empty) },
            powerAssertions: power
        )
    }
}

/// `kIOReturnError` (0xE00002BC); the C macro is not imported into Swift.
private let simulatedIOReturnError = IOReturn(bitPattern: 0xE000_02BC)

private enum PowerAssertionOutcome {
    case success(assertionID: IOPMAssertionID)
    /// `writing: nil` leaves the out-parameter untouched (IOKit's usual
    /// behavior); a value simulates an API that writes it despite failing.
    case failure(IOReturn, writing: IOPMAssertionID?)
}

private final class RecordingPowerAssertionController: PowerAssertionControlling, @unchecked Sendable {
    struct Creation: Equatable {
        let type: String
        let level: IOPMAssertionLevel
        let name: String
        /// The out-parameter value `SystemMonitor` passed in.
        let incomingID: IOPMAssertionID
    }

    private let lock = NSLock()
    private var pendingOutcomes: [PowerAssertionOutcome]
    private var recordedCreations: [Creation] = []
    private var recordedReleases: [IOPMAssertionID] = []

    init(outcomes: [PowerAssertionOutcome]) {
        pendingOutcomes = outcomes
    }

    var creations: [Creation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCreations
    }

    var releases: [IOPMAssertionID] {
        lock.lock()
        defer { lock.unlock() }
        return recordedReleases
    }

    func create(
        type: String,
        level: IOPMAssertionLevel,
        name: String,
        assertionID: inout IOPMAssertionID
    ) -> IOReturn {
        lock.lock()
        defer { lock.unlock() }
        recordedCreations.append(
            Creation(type: type, level: level, name: name, incomingID: assertionID)
        )
        guard !pendingOutcomes.isEmpty else {
            XCTFail("Unexpected power-assertion create")
            return simulatedIOReturnError
        }
        switch pendingOutcomes.removeFirst() {
        case let .success(id):
            assertionID = id
            return kIOReturnSuccess
        case let .failure(code, written):
            if let written { assertionID = written }
            return code
        }
    }

    func release(_ assertionID: IOPMAssertionID) {
        lock.lock()
        recordedReleases.append(assertionID)
        lock.unlock()
    }
}
