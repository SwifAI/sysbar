import Foundation
import XCTest
@testable import SysBar

final class TelemetryStateTests: XCTestCase {
    func testAvailableFailureBecomesStaleWithOriginalValueAndTimestamp() {
        let sampledAt = Date(timeIntervalSince1970: 100)
        let state = TelemetryState.available(42, sampledAt: sampledAt)

        let failed = state.recordingFailure(.collector("lsof failed"))

        XCTAssertEqual(
            failed,
            .stale(42, sampledAt: sampledAt, error: .collector("lsof failed"))
        )
        XCTAssertEqual(failed.value, 42)
        XCTAssertEqual(failed.sampledAt, sampledAt)
        XCTAssertTrue(failed.isStale)
    }

    func testRepeatedStaleFailurePreservesValueAndTimestampButReplacesError() {
        let sampledAt = Date(timeIntervalSince1970: 100)
        let state = TelemetryState.stale(
            42,
            sampledAt: sampledAt,
            error: .collector("first failure")
        )

        let failed = state.recordingFailure(.timedOut("newest failure"))

        XCTAssertEqual(
            failed,
            .stale(42, sampledAt: sampledAt, error: .timedOut("newest failure"))
        )
    }

    func testLoadingFailureBecomesUnavailableWithoutAValue() {
        let failed = TelemetryState<Int>.loading.recordingFailure(.collector("failed"))

        XCTAssertEqual(failed, .unavailable(.collector("failed")))
        XCTAssertNil(failed.value)
        XCTAssertNil(failed.sampledAt)
        XCTAssertTrue(failed.isUnavailable)
    }

    func testUnavailableFailureRemainsUnavailableWithNewestError() {
        let state = TelemetryState<Int>.unavailable(.permission("first failure"))

        let failed = state.recordingFailure(.collector("newest failure"))

        XCTAssertEqual(failed, .unavailable(.collector("newest failure")))
    }

    func testAvailableEmptyCollectionIsAValidSample() {
        let sampledAt = Date(timeIntervalSince1970: 200)
        let state = TelemetryState<[Int]>.available([], sampledAt: sampledAt)

        XCTAssertEqual(state.value, [])
        XCTAssertEqual(state.sampledAt, sampledAt)
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.isStale)
        XCTAssertFalse(state.isUnavailable)
    }

    func testNewAvailableSampleRepresentsRecovery() {
        let staleAt = Date(timeIntervalSince1970: 200)
        let recoveredAt = Date(timeIntervalSince1970: 300)
        var state = TelemetryState.stale(
            42,
            sampledAt: staleAt,
            error: TelemetryError.collector("failed")
        )

        state = .available(84, sampledAt: recoveredAt)

        XCTAssertEqual(state, .available(84, sampledAt: recoveredAt))
        XCTAssertEqual(state.value, 84)
        XCTAssertEqual(state.sampledAt, recoveredAt)
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.isStale)
        XCTAssertFalse(state.isUnavailable)
    }

    func testEquatableAndSendableConformancesAreConditionalOnValue() {
        let state = TelemetryState.available(42, sampledAt: Date(timeIntervalSince1970: 400))

        requireEquatable(state)
        requireSendable(state)
    }

    func testPanelLoadingExposesNoValues() {
        let panel = PanelSnapshot.loading

        XCTAssertNil(panel.memory.value)
        XCTAssertNil(panel.swap.value)
        XCTAssertNil(panel.network.value)
        XCTAssertNil(panel.listenPorts.value)
        XCTAssertNil(panel.disk.value)
        XCTAssertTrue(panel.memory.isLoading)
        XCTAssertTrue(panel.swap.isLoading)
        XCTAssertTrue(panel.network.isLoading)
        XCTAssertTrue(panel.listenPorts.isLoading)
        XCTAssertTrue(panel.disk.isLoading)
    }
}

final class TelemetryStateContentTests: XCTestCase {
    func testACurrentSampleWithTheSameValueShowsTheSameContentWhenTakenLater() {
        let earlier = TelemetryState<Int>.available(3, sampledAt: Date(timeIntervalSince1970: 10))

        XCTAssertTrue(earlier.hasSameContent(as: .available(3, sampledAt: Date(timeIntervalSince1970: 25))))
        XCTAssertFalse(earlier.hasSameContent(as: .available(4, sampledAt: Date(timeIntervalSince1970: 10))))
    }

    func testAChangeOfStateIsAlwaysAChangeOfContent() {
        let failure = TelemetryError.collector("lsof failed")
        let current = TelemetryState<Int>.available(3, sampledAt: Date(timeIntervalSince1970: 10))

        XCTAssertFalse(TelemetryState<Int>.loading.hasSameContent(as: current))
        XCTAssertFalse(current.hasSameContent(as: current.recordingFailure(failure)))
        XCTAssertFalse(TelemetryState<Int>.unavailable(failure).hasSameContent(as: .loading))
        XCTAssertTrue(current.recordingFailure(failure).hasSameContent(as: current.recordingFailure(failure)))
    }
}

private func requireEquatable<Value: Equatable>(_: Value) {}
private func requireSendable<Value: Sendable>(_: Value) {}
