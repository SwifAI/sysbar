import XCTest
@testable import SysBar

final class ProcessGroupingTests: XCTestCase {
    func testProcessIdentityUsesTheExactStartTimeTuple() {
        let first = identity(pid: 42, seconds: 1_700_000_000, microseconds: 123_456, path: "/Applications/Demo.app/Contents/MacOS/Demo")
        let oneMicrosecondLater = identity(pid: 42, seconds: 1_700_000_000, microseconds: 123_457, path: "/Applications/Demo.app/Contents/MacOS/Demo")

        XCTAssertNotEqual(first, oneMicrosecondLater)
        XCTAssertNotEqual(first.instanceID, oneMicrosecondLater.instanceID)
    }

    func testProcessIdentityRejectsUntrustworthyIdentityParts() {
        let start = ProcessStartTime(seconds: 1_700_000_000, microseconds: 123_456)

        XCTAssertNil(ProcessIdentity(pid: 0, startTime: start, executablePath: "/bin/demo"))
        XCTAssertNil(ProcessIdentity(pid: -1, startTime: start, executablePath: "/bin/demo"))
        XCTAssertNil(ProcessIdentity(pid: 42, startTime: .unknown, executablePath: "/bin/demo"))
        XCTAssertNil(ProcessIdentity(pid: 42, startTime: start, executablePath: ""))
        XCTAssertNil(ProcessIdentity(
            pid: 42,
            startTime: ProcessStartTime(seconds: 1_700_000_000, microseconds: 1_000_000),
            executablePath: "/bin/demo"
        ))
    }

    func testRowsWithAReusedPIDHaveDifferentInstanceIDs() {
        let old = ProcSample(
            pid: 42,
            startTime: ProcessStartTime(seconds: 100, microseconds: 1),
            executablePath: "/bin/demo",
            name: "demo",
            cpuPercent: 1,
            residentMB: 10
        )
        let replacement = ProcSample(
            pid: 42,
            startTime: ProcessStartTime(seconds: 101, microseconds: 1),
            executablePath: "/bin/demo",
            name: "demo",
            cpuPercent: 2,
            residentMB: 20
        )

        XCTAssertNotEqual(old.id, replacement.id)
    }

    func testSameBasenameAtDifferentExecutablePathsFormsSeparateGroups() {
        let groups = ProcessOverview(samples: [
            sample(identity: identity(pid: 10, path: "/Applications/Alpha.app/Contents/MacOS/worker"), name: "worker", cpu: 2, memory: 10),
            sample(identity: identity(pid: 11, path: "/Users/example/bin/worker"), name: "worker", cpu: 3, memory: 20)
        ], limit: 10).topCPU

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.name)), ["worker"])
        XCTAssertEqual(Set(groups.compactMap(\.executablePath)), [
            "/Applications/Alpha.app/Contents/MacOS/worker",
            "/Users/example/bin/worker"
        ])
        XCTAssertEqual(Set(groups.map(\.id)).count, 2)
        XCTAssertTrue(groups.allSatisfy(\.isActionable))
    }

    func testProcessesAtTheSameExecutablePathAggregateWithTheirExpectedIdentities() {
        let first = identity(pid: 10, seconds: 100, path: "/Applications/Demo.app/Contents/MacOS/Demo")
        let second = identity(pid: 11, seconds: 101, path: "/Applications/Demo.app/Contents/MacOS/Demo")
        let group = ProcessOverview(samples: [
            sample(identity: first, name: "Demo", cpu: 2, memory: 10),
            sample(identity: second, name: "Demo", cpu: 3, memory: 20)
        ], limit: 10).topCPU.first

        XCTAssertEqual(group?.pids, [10, 11])
        XCTAssertEqual(group?.expectedIdentities, [first, second])
        XCTAssertEqual(group?.totalCPU, 5)
        XCTAssertEqual(group?.totalMemMB, 30)
        XCTAssertEqual(group?.isActionable, true)
    }

    func testProcessWithoutAPathRemainsDisplayableButIsNotActionable() {
        let group = ProcessOverview(samples: [ProcSample(
            pid: 42,
            startTime: ProcessStartTime(seconds: 100, microseconds: 1),
            executablePath: nil,
            name: "restricted",
            cpuPercent: 1,
            residentMB: 10
        )], limit: 10).topCPU.first

        XCTAssertEqual(group?.name, "restricted")
        XCTAssertEqual(group?.pids, [42])
        XCTAssertEqual(group?.expectedIdentities, [])
        XCTAssertEqual(group?.isActionable, false)
    }

    func testEqualUsageHasStableOrderingAcrossDifferentInputOrders() {
        let samples = [
            sample(identity: identity(pid: 30, path: "/z/worker"), name: "worker", cpu: 2, memory: 10),
            sample(identity: identity(pid: 20, path: "/a/worker"), name: "worker", cpu: 2, memory: 10),
            sample(identity: identity(pid: 10, path: "/bin/alpha"), name: "alpha", cpu: 2, memory: 10),
            ProcSample(pid: 50, name: "worker", cpuPercent: 2, residentMB: 10),
            ProcSample(pid: 40, name: "worker", cpuPercent: 2, residentMB: 10)
        ]
        let expectedPIDs: [[Int32]] = [[10], [20], [30], [40], [50]]
        for offset in samples.indices {
            let reordered = Array(samples[offset...]) + samples[..<offset]
            let overview = ProcessOverview(samples: reordered)
            XCTAssertEqual(overview.topCPU.map(\.pids), expectedPIDs)
            XCTAssertEqual(overview.topMemory.map(\.pids), expectedPIDs)
        }
    }

    private func sample(
        identity: ProcessIdentity,
        name: String,
        cpu: Double,
        memory: Int
    ) -> ProcSample {
        ProcSample(
            pid: identity.pid,
            startTime: identity.startTime,
            executablePath: identity.executablePath,
            name: name,
            cpuPercent: cpu,
            residentMB: memory
        )
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
