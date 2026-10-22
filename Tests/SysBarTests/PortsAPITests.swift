import Foundation
import Darwin
import XCTest
@testable import SysBar

final class PortsAPITests: XCTestCase {
    func testListenerIdentityDistinguishesBindAddressesForSameProcessEndpoint() {
        let loopback = ListenSocket(
            pid: 12,
            processName: "demo",
            port: 8080,
            bindAddress: "127.0.0.1",
            isTCP: true
        )
        let wildcard = ListenSocket(
            pid: 12,
            processName: "demo",
            port: 8080,
            bindAddress: "0.0.0.0",
            isTCP: true
        )

        XCTAssertNotEqual(loopback.id, wildcard.id)
    }

    func testEndpointIdentityIncludesNormalizedBindProtocolPIDAndPort() {
        let endpoint = socket(pid: 12, port: 8080, bind: " [::1] ", isTCP: true)

        XCTAssertEqual(endpoint.bindAddress, "::1")
        XCTAssertEqual(endpoint.id, endpoint.endpointKey)
        XCTAssertEqual(endpoint.endpointKey, socket(pid: 12, port: 8080, bind: "::1", isTCP: true).endpointKey)
        XCTAssertNotEqual(endpoint.endpointKey, socket(pid: 13, port: 8080, bind: "::1", isTCP: true).endpointKey)
        XCTAssertNotEqual(endpoint.endpointKey, socket(pid: 12, port: 8081, bind: "::1", isTCP: true).endpointKey)
        XCTAssertNotEqual(endpoint.endpointKey, socket(pid: 12, port: 8080, bind: "::1", isTCP: false).endpointKey)
        XCTAssertNotEqual(endpoint.endpointKey, socket(pid: 12, port: 8080, bind: "::", isTCP: true).endpointKey)
        XCTAssertNotEqual(
            socket(pid: 12, port: 8080, bind: "0.0.0.0", isTCP: true).endpointKey,
            socket(pid: 12, port: 8080, bind: "::", isTCP: true).endpointKey
        )
    }

    func testEmptyAndUnspecifiedWildcardsNormalizeWithoutMergingIPFamilies() {
        XCTAssertEqual(socket(bind: "").bindAddress, "*")
        XCTAssertEqual(socket(bind: " [*] ").bindAddress, "*")
        XCTAssertEqual(socket(bind: " [::] ").bindAddress, "::")
        XCTAssertEqual(socket(bind: " 0.0.0.0 ").bindAddress, "0.0.0.0")
        XCTAssertNotEqual(socket(bind: "0.0.0.0").endpointKey, socket(bind: "::").endpointKey)
    }

    func testParserHandlesIPv4AndBracketedIPv6ListenerAddresses() {
        let output = """
        p42
        cdemo
        f10
        PTCP
        n*:8080
        f11
        PTCP
        n127.0.0.1:8081 (LISTEN)
        f12
        PTCP
        n[::]:8082
        f13
        PTCP
        n[::1]:8083 (LISTEN)
        """

        let sockets = PortsAPI.parseLsofOutput(output)

        XCTAssertEqual(
            sockets.map { "\($0.bindAddress):\($0.port)" },
            ["*:8080", ":::8082", "127.0.0.1:8081", "::1:8083"]
        )
        XCTAssertTrue(sockets.allSatisfy(\.isTCP))
    }

    func testParserSkipsConnectedInvalidAndContextlessRecordsAndDeduplicatesEndpoints() {
        let output = """
        n*:1000
        pnot-a-pid
        cbad
        f1
        PTCP
        n*:1001
        p42
        cdemo
        n*:1002
        f2
        PTCP
        n127.0.0.1:8080 (LISTEN)
        n127.0.0.1:8080 (LISTEN)
        n127.0.0.1:70000 (LISTEN)
        n127.0.0.1:not-a-port (LISTEN)
        n127.0.0.1:8080->127.0.0.1:60000
        f3
        n*:1003
        PUDP
        n*:1900
        p43
        cnext
        n*:1004
        f4
        PSCTP
        n*:1005
        p44
        f5
        PTCP
        n*:1006
        """

        let sockets = PortsAPI.parseLsofOutput(output)

        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(sockets[0], socket(pid: 42, port: 1900, bind: "*", isTCP: false))
        XCTAssertEqual(sockets[1], socket(pid: 42, port: 8080, bind: "127.0.0.1", isTCP: true))
    }

    func testOnlyHighEphemeralUDPIsNoise() {
        XCTAssertTrue(socket(port: 60_000, bind: "*", isTCP: false).isNoiseUDP)
        XCTAssertFalse(socket(port: 60_000, bind: "*", isTCP: true).isNoiseUDP)
        XCTAssertFalse(socket(port: 49_151, bind: "*", isTCP: false).isNoiseUDP)
        XCTAssertTrue(socket(port: 5_353, bind: "*", isTCP: false).isNoiseUDP, "Bonjour mDNS is discovery, not a service")
        XCTAssertFalse(socket(port: 5_353, bind: "*", isTCP: true).isNoiseUDP)
    }

    func testConcreteInterfaceAddressesAreLANExposedWhileLoopbackRangesAreLocal() {
        XCTAssertTrue(socket(bind: "192.168.1.20").isLanExposed)
        XCTAssertTrue(socket(bind: "10.0.0.8").isLanExposed)
        XCTAssertTrue(socket(bind: "fe80::1234").isLanExposed)
        XCTAssertFalse(socket(bind: "127.0.0.2").isLanExposed)
        XCTAssertFalse(socket(bind: "::1").isLanExposed)
        XCTAssertFalse(socket(bind: "::ffff:127.0.0.42").isLanExposed)
    }

    func testNoisyWildcardUDPIsLANReachableButNotActionableExposure() {
        let listener = socket(port: 60_000, bind: "*", isTCP: false)
        XCTAssertTrue(listener.isLanExposed)
        XCTAssertEqual(listener.exposure, .lanReachable)
    }

    func testParserSortsActionableExposureThenLoopbackThenNoiseUDP() {
        let output = """
        p42
        cdemo
        f1
        PUDP
        n*:60000
        f2
        PTCP
        n127.0.0.1:1000 (LISTEN)
        f3
        PTCP
        n*:9000 (LISTEN)
        """

        let sockets = PortsAPI.parseLsofOutput(output)

        XCTAssertEqual(sockets.map(\.port), [9000, 1000, 60000])
    }

    func testExposureDiffFindsWildcardAddedBesideExistingLoopback() {
        let loopback = socket(pid: 12, port: 8080, bind: "127.0.0.1", isTCP: true)
        let wildcard = socket(pid: 12, port: 8080, bind: "0.0.0.0", isTCP: true)

        XCTAssertEqual(ListenerDiff.exposuresAdded(from: [loopback], to: [loopback, wildcard]), [wildcard])
    }

    func testExposureDiffDoesNotReportUnchangedNormalizedExposure() {
        let previous = socket(pid: 12, port: 8080, bind: "[::]", isTCP: true)
        let current = socket(pid: 12, port: 8080, bind: "::", isTCP: true)

        XCTAssertEqual(ListenerDiff.exposuresAdded(from: [previous], to: [current]), [])
    }

    func testFetchResultReportsLaunchFailure() {
        let runner = StubLsofCommandRunner(.failure(.launchFailed("not found")))

        assertFailure(
            PortsAPI.fetchResult(runner: runner),
            equals: .collector("lsof launch failed: not found")
        )
    }

    func testFetchResultReportsTimeout() {
        let runner = StubLsofCommandRunner(.failure(.timedOut))

        assertFailure(
            PortsAPI.fetchResult(runner: runner),
            equals: .timedOut("lsof timed out")
        )
    }

    func testFetchResultReportsNonzeroExitWithOutput() {
        let runner = StubLsofCommandRunner(
            .success(LsofCommandOutput(stdout: Data("problem".utf8), terminationStatus: 2))
        )

        assertFailure(
            PortsAPI.fetchResult(runner: runner),
            equals: .collector("lsof exited with status 2")
        )
    }

    func testFetchResultReportsInvalidUTF8() {
        let runner = StubLsofCommandRunner(
            .success(LsofCommandOutput(stdout: Data([0xC3, 0x28]), terminationStatus: 0))
        )

        assertFailure(
            PortsAPI.fetchResult(runner: runner),
            equals: .collector("lsof output was not valid UTF-8")
        )
    }

    func testFetchResultTreatsValidZeroListenerOutputAsSuccess() throws {
        let runner = StubLsofCommandRunner(
            .success(LsofCommandOutput(stdout: Data(), terminationStatus: 0))
        )

        XCTAssertEqual(try PortsAPI.fetchResult(runner: runner).get(), [])
    }

    func testFetchResultTreatsDarwinLsofStatusOneWithNoOutputAsSuccess() throws {
        let runner = StubLsofCommandRunner(
            .success(LsofCommandOutput(stdout: Data(), terminationStatus: 1))
        )

        XCTAssertEqual(try PortsAPI.fetchResult(runner: runner).get(), [])
    }

    func testProcessRunnerDrainsOutputLargerThanPipeCapacity() throws {
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print 'x' x 262144"]
        )

        let output = try runner.run(timeout: 2)

        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertEqual(output.stdout.count, 262_144)
    }

    func testProcessRunnerNonzeroExitBecomesFetchFailure() {
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print 'problem'; exit 7"]
        )

        assertFailure(
            PortsAPI.fetchResult(runner: runner, timeout: 2),
            equals: .collector("lsof exited with status 7")
        )
    }

    func testProcessRunnerInvalidUTF8BecomesFetchFailure() {
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "binmode STDOUT; print pack('C', 255)"]
        )

        assertFailure(
            PortsAPI.fetchResult(runner: runner, timeout: 2),
            equals: .collector("lsof output was not valid UTF-8")
        )
    }

    func testProcessRunnerTimeoutForceKillsAndReapsTermIgnoringChild() {
        let process = Process()
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "$SIG{TERM} = 'IGNORE'; select(undef, undef, undef, 10)"],
            process: process
        )
        let startedAt = Date()

        XCTAssertThrowsError(try runner.run(timeout: 0.25)) { error in
            XCTAssertEqual(error as? LsofCommandRunnerError, .timedOut)
        }

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    // MARK: Bounded, fail-closed lsof output (ADR-020)

    // Stdout is held in a capped accumulator; retained bytes never
    // exceed the budget, whatever the child writes.
    func testOutputBufferRetainsAtMostItsLimitWhateverTheChildWrites() {
        let buffer = LsofOutputBuffer(limit: 10)
        let chunks = "abcdefghij".map { Data(String(repeating: $0, count: 4).utf8) }

        for chunk in chunks {
            buffer.append(chunk)
            XCTAssertLessThanOrEqual(buffer.snapshot.data.count, 10)
        }

        let captured = buffer.snapshot
        XCTAssertEqual(captured.data, Data("aaaabbbbcc".utf8))
        XCTAssertTrue(captured.exceededLimit)

        buffer.append(Data("zzzz".utf8))
        XCTAssertEqual(buffer.snapshot.data, Data("aaaabbbbcc".utf8))
        XCTAssertTrue(buffer.snapshot.exceededLimit)
    }

    // Boundary: output landing exactly on the budget is kept
    // whole and is not an overflow; an empty read at the cap is not one either.
    func testOutputBufferExactlyAtItsLimitIsNotAnOverflow() {
        let buffer = LsofOutputBuffer(limit: 8)

        buffer.append(Data("abcd".utf8))
        buffer.append(Data("efgh".utf8))
        buffer.append(Data())

        let captured = buffer.snapshot
        XCTAssertEqual(captured.data, Data("abcdefgh".utf8))
        XCTAssertFalse(captured.exceededLimit)
    }

    // Boundary: one byte past the budget flags overflow and keeps
    // only the fitting prefix, never more than the budget.
    func testOutputBufferOneByteOverItsLimitKeepsTheFittingPrefixAndFlagsOverflow() {
        let buffer = LsofOutputBuffer(limit: 8)

        buffer.append(Data("abcdef".utf8))
        buffer.append(Data("ghi".utf8))

        let captured = buffer.snapshot
        XCTAssertEqual(captured.data, Data("abcdefgh".utf8))
        XCTAssertTrue(captured.exceededLimit)
    }

    // Boundary: a zero or negative budget is clamped to zero, so
    // nothing is retained and any byte at all is an overflow.
    func testOutputBufferWithNonPositiveLimitRetainsNothingAndFlagsAnyByte() {
        for limit in [0, -5] {
            let buffer = LsofOutputBuffer(limit: limit)

            buffer.append(Data())
            XCTAssertFalse(buffer.snapshot.exceededLimit, "limit \(limit)")
            XCTAssertTrue(buffer.snapshot.data.isEmpty, "limit \(limit)")

            buffer.append(Data("a".utf8))
            XCTAssertTrue(buffer.snapshot.exceededLimit, "limit \(limit)")
            XCTAssertEqual(buffer.snapshot.data.count, 0, "limit \(limit)")
        }
    }

    // The production budget is 4 MiB drained in 4 KiB chunks, so
    // retained memory is bounded by budget + one read chunk (ADR-020 numbers).
    func testProductionLsofOutputBudgetIsFourMebibytesReadInFourKibibyteChunks() {
        XCTAssertEqual(ProcessLsofCommandRunner.defaultOutputLimit, 4_194_304)
        XCTAssertEqual(ProcessLsofCommandRunner.readChunkSize, 4_096)
    }

    // Failure: a child writing 16x the pipe buffer past the budget
    // is rejected once it reaches EOF, well before the timeout: draining past
    // the cap means the child never blocks on a full pipe.
    func testProcessRunnerRejectsAChildThatWritesPastTheOutputBudgetWithoutDeadlocking() {
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print 'x' x 1048576"],
            outputLimit: 65_536
        )
        let startedAt = Date()

        XCTAssertThrowsError(try runner.run(timeout: 3)) { error in
            XCTAssertEqual(error as? LsofCommandRunnerError, .outputTooLarge)
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }

    // Failure: over-budget output from a real child is a typed
    // collector failure, never a truncated listener list. The fixed message
    // echoes none of the lsof output (no PIDs, commands, or addresses).
    func testFetchResultReportsOversizedOutputAsCollectorFailureInsteadOfATruncatedList() {
        var records = "p4242\ncdemo\n"
        for index in 0..<5_000 {
            records += "f\(index)\nPTCP\nn127.0.0.1:\(1_000 + index)\n"
        }
        XCTAssertGreaterThan(records.utf8.count, 65_536)
        // Non-vacuity: the fitting prefix alone parses into rows, so a
        // truncate-then-parse implementation would have returned a list.
        XCTAssertFalse(PortsAPI.parseLsofOutput(
            String(decoding: Data(records.utf8).prefix(65_536), as: UTF8.self)
        ).isEmpty)
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print $ARGV[0]", records],
            outputLimit: 65_536
        )

        assertFailure(
            PortsAPI.fetchResult(runner: runner, timeout: 3),
            equals: .collector("lsof output exceeded the size limit")
        )
    }

    // The runner's overflow error maps to a typed collector failure.
    func testFetchResultReportsRunnerOverflowAsCollectorFailure() {
        let runner = StubLsofCommandRunner(.failure(.outputTooLarge))

        assertFailure(
            PortsAPI.fetchResult(runner: runner),
            equals: .collector("lsof output exceeded the size limit")
        )
    }

    // Boundary: even a runner that did not cap its output is
    // rejected by PortsAPI one byte over the production budget, before its
    // otherwise-valid, status-0 output is decoded or parsed.
    func testFetchResultRejectsRunnerOutputOneByteOverTheProductionBudget() {
        let stdout = paddedListenerOutput(byteCount: ProcessLsofCommandRunner.defaultOutputLimit + 1)
        XCTAssertEqual(stdout.count, 4_194_305)
        XCTAssertFalse(PortsAPI.parseLsofOutput(validListenerRecord()).isEmpty)
        let runner = StubLsofCommandRunner(
            .success(LsofCommandOutput(stdout: stdout, terminationStatus: 0))
        )

        assertFailure(
            PortsAPI.fetchResult(runner: runner),
            equals: .collector("lsof output exceeded the size limit")
        )
    }

    // The overflow failure leaves previous listeners
    // visible as stale, or reports unavailable when there were none.
    func testOversizedScanLeavesPreviousListenersVisibleAsStaleOrReportsUnavailableWithoutThem() {
        let result = PortsAPI.fetchResult(runner: StubLsofCommandRunner(.failure(.outputTooLarge)))
        guard case let .failure(error) = result else {
            XCTFail("An over-budget scan must fail, got \(result)")
            return
        }
        let previous = socket(pid: 42, port: 8080, bind: "127.0.0.1")
        let sampledAt = Date(timeIntervalSince1970: 10)

        XCTAssertEqual(error, .collector("lsof output exceeded the size limit"))
        XCTAssertEqual(
            TelemetryState<[ListenSocket]>.available([previous], sampledAt: sampledAt)
                .recordingFailure(error),
            .stale([previous], sampledAt: sampledAt, error: error)
        )
        XCTAssertEqual(
            TelemetryState<[ListenSocket]>.loading.recordingFailure(error),
            .unavailable(error)
        )
    }

    // Boundary: output of exactly the production budget is
    // accepted and parsed as before; blank padding lines add no rows.
    func testFetchResultParsesRunnerOutputOfExactlyTheProductionBudget() throws {
        let expected = PortsAPI.parseLsofOutput(validListenerRecord())
        XCTAssertEqual(expected, [ListenSocket(
            pid: 4242,
            processName: "demo",
            port: 8080,
            bindAddress: "127.0.0.1",
            isTCP: true
        )])
        let stdout = paddedListenerOutput(byteCount: ProcessLsofCommandRunner.defaultOutputLimit)
        XCTAssertEqual(stdout.count, 4_194_304)
        let runner = StubLsofCommandRunner(
            .success(LsofCommandOutput(stdout: stdout, terminationStatus: 0))
        )

        XCTAssertEqual(try PortsAPI.fetchResult(runner: runner).get(), expected)
    }

    // Boundary: a real child writing exactly the budget is
    // returned whole, not flagged as an overflow.
    func testProcessRunnerReturnsOutputOfExactlyTheBudgetWhole() throws {
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print 'x' x 65536"],
            outputLimit: 65_536
        )

        let output = try runner.run(timeout: 3)

        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertEqual(output.stdout, Data(repeating: UInt8(ascii: "x"), count: 65_536))
    }

    // Real output exactly at the budget goes through the chunked
    // drain and parses exactly as the same text parses directly.
    func testProcessRunnerOutputAtExactlyTheBudgetParsesExactlyAsBefore() {
        let records = """
        p42
        cdemo
        f10
        PTCP
        n*:8080
        f11
        PTCP
        n127.0.0.1:8081 (LISTEN)
        f12
        PUDP
        n[::1]:5353

        """
        let expected = PortsAPI.parseLsofOutput(records)
        XCTAssertEqual(
            Set(expected.map { "\($0.bindAddress):\($0.port)" }),
            ["*:8080", "127.0.0.1:8081", "::1:5353"]
        )
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print $ARGV[0]", records],
            outputLimit: records.utf8.count
        )

        XCTAssertEqual(PortsAPI.fetchResult(runner: runner, timeout: 3), .success(expected))
    }

    // Failure: when a descendant keeps stdout open and
    // writing after the child exits, the existing forced reader close still
    // ends the run as a bounded timeout, and the chunked drain survives
    // reading from the closed handle instead of crashing the process.
    func testProcessRunnerSurvivesClosingItsReaderWhileADescendantKeepsWriting() {
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(i=0; while [ $i -lt 100 ]; do echo x; sleep 0.05; i=$((i+1)); done) &"]
        )
        let startedAt = Date()

        XCTAssertThrowsError(try runner.run(timeout: 2)) { error in
            XCTAssertEqual(error as? LsofCommandRunnerError, .timedOut)
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    // Failure: a child still writing past the budget at the
    // deadline gets the unchanged SIGTERM ladder, is reaped, and is reported
    // as too large (overflow takes precedence over the timeout).
    func testOverflowingChildStillWritingAtTheDeadlineIsTerminatedReapedAndReportedTooLarge() {
        let process = Process()
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            process: process,
            outputLimit: 65_536
        )
        let startedAt = Date()

        XCTAssertThrowsError(try runner.run(timeout: 0.25)) { error in
            XCTAssertEqual(error as? LsofCommandRunnerError, .outputTooLarge)
        }

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGTERM)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    // Failure: an overflowing child that ignores SIGTERM is
    // still force-killed and reaped by the unchanged ladder.
    func testOverflowingChildThatIgnoresTermIsStillForceKilledAndReaped() {
        let process = Process()
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "$SIG{TERM} = 'IGNORE'; $| = 1; while (1) { print 'x' x 4096 }"],
            process: process,
            outputLimit: 65_536
        )
        let startedAt = Date()

        XCTAssertThrowsError(try runner.run(timeout: 0.25)) { error in
            XCTAssertEqual(error as? LsofCommandRunnerError, .outputTooLarge)
        }

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    // Stderr is still discarded, so a flood on stderr neither
    // blocks the child nor counts toward the stdout budget.
    func testProcessRunnerDiscardsStderrSoItNeitherBlocksNorCountsTowardTheBudget() throws {
        let runner = ProcessLsofCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print STDERR 'e' x 1048576; print 'ok'"],
            outputLimit: 65_536
        )

        let output = try runner.run(timeout: 3)

        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertEqual(output.stdout, Data("ok".utf8))
    }

    private func socket(
        pid: Int32 = 12,
        port: UInt16 = 8080,
        bind: String,
        isTCP: Bool = true
    ) -> ListenSocket {
        ListenSocket(
            pid: pid,
            processName: pid == 42 ? "demo" : "process",
            port: port,
            bindAddress: bind,
            isTCP: isTCP
        )
    }

    private func assertFailure(
        _ result: Result<[ListenSocket], TelemetryError>,
        equals expected: TelemetryError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case let .failure(error):
            XCTAssertEqual(error, expected, file: file, line: line)
        case let .success(sockets):
            XCTFail("Expected failure, got \(sockets)", file: file, line: line)
        }
    }

    private func validListenerRecord() -> String {
        "p4242\ncdemo\nf3\nPTCP\nn127.0.0.1:8080\n"
    }

    /// A valid one-listener record padded with blank lines to an exact byte
    /// count. Blank lines are dropped by the parser, so padding adds no rows.
    private func paddedListenerOutput(byteCount: Int) -> Data {
        var output = Data(validListenerRecord().utf8)
        output.append(Data(repeating: UInt8(ascii: "\n"), count: max(0, byteCount - output.count)))
        return output
    }
}

private struct StubLsofCommandRunner: LsofCommandRunning {
    let result: Result<LsofCommandOutput, LsofCommandRunnerError>

    init(_ result: Result<LsofCommandOutput, LsofCommandRunnerError>) {
        self.result = result
    }

    func run(timeout: TimeInterval) throws -> LsofCommandOutput {
        try result.get()
    }
}
