import Foundation
import Darwin
import XCTest
@testable import SysBar

final class BoundedProcessRunnerTests: XCTestCase {
    func testBoundedRunnerDrainsBothStreamsAndCapsRetainedBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = BoundedProcessRunner()
        let command = BoundedProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [
                "-e",
                "binmode STDOUT; binmode STDERR; print STDOUT 'o' x 262144; print STDERR 'e' x 262144"
            ],
            currentDirectoryURL: root,
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: Data(),
            standardInputLimit: 16 * 1_024,
            standardOutputLimit: 1_024,
            standardErrorLimit: 512,
            timeout: 2
        )

        let output = try await runner.run(command)

        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertEqual(output.stdout.count, 1_024)
        XCTAssertEqual(output.stderr.count, 512)
        XCTAssertTrue(output.stdoutExceededLimit)
        XCTAssertTrue(output.stderrExceededLimit)
    }

    func testBoundedRunnerWritesStdinAndNeverInvokesAShell() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = Data("literal; $(touch should-not-run) | value".utf8)
        let command = BoundedProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "binmode STDIN; binmode STDOUT; local $/; print <STDIN>"],
            currentDirectoryURL: root,
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: sentinel,
            standardInputLimit: 16 * 1_024,
            standardOutputLimit: 32 * 1_024,
            standardErrorLimit: 16 * 1_024,
            timeout: 2
        )

        let output = try await BoundedProcessRunner().run(command)

        XCTAssertEqual(output.stdout, sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-run").path))
    }

    func testBoundedRunnerSurvivesChildClosingStdinBeforeLargeWriteCompletes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = Data(repeating: 0x41, count: 2 * 1_024 * 1_024)
        let command = BoundedProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [
                "-e",
                "close STDIN; select(undef, undef, undef, 0.2); exit 0"
            ],
            currentDirectoryURL: root,
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: input,
            standardInputLimit: input.count,
            standardOutputLimit: 1_024,
            standardErrorLimit: 1_024,
            timeout: 2
        )

        let output = try await BoundedProcessRunner().run(command)

        XCTAssertEqual(output.terminationStatus, 0)
    }

    func testBoundedRunnerRejectsOversizedInputBeforeLaunch() async {
        let process = Process()
        let command = BoundedProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "exit 0"],
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: [:],
            standardInput: Data(repeating: 0, count: 17),
            standardInputLimit: 16,
            standardOutputLimit: 16,
            standardErrorLimit: 16,
            timeout: 1
        )

        do {
            _ = try await BoundedProcessRunner(process: process).run(command)
            XCTFail("Expected oversized input failure")
        } catch {
            XCTAssertEqual(error as? BoundedProcessError, .inputTooLarge)
            XCTAssertEqual(process.processIdentifier, 0)
        }
    }

    func testBoundedRunnerTerminatesForceKillsAndReapsTermIgnoringChild() async {
        let process = Process()
        let command = BoundedProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "$SIG{TERM} = 'IGNORE'; select(undef, undef, undef, 10)"],
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: Data(),
            standardInputLimit: 16,
            standardOutputLimit: 16,
            standardErrorLimit: 16,
            timeout: 0.25
        )
        let startedAt = Date()

        do {
            _ = try await BoundedProcessRunner(process: process).run(command)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? BoundedProcessError, .timedOut)
        }

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    // Stdout drain: a descendant holding stdout open past the
    // drain grace ends the run as .timedOut, with no crash and no truncated success.
    func testBoundedRunnerFailsAsTimedOutInsteadOfCrashingWhenADescendantKeepsWritingStdoutAfterTheChildExits() async {
        // Mirrors PortsAPITests.testProcessRunnerSurvivesClosingItsReaderWhileADescendantKeepsWriting.
        // A readData(ofLength:) drain aborts the whole test process on this path.
        let process = Process()
        let command = BoundedProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(i=0; while [ $i -lt 100 ]; do echo x; sleep 0.05; i=$((i+1)); done) &"],
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: Data(),
            standardInputLimit: 16,
            standardOutputLimit: 32 * 1_024,
            standardErrorLimit: 16 * 1_024,
            timeout: 2
        )
        let startedAt = Date()

        do {
            let output = try await BoundedProcessRunner(process: process).run(command)
            XCTFail("A pipe held open past the drain grace must fail, not return \(output.stdout.count) truncated bytes")
        } catch {
            XCTAssertEqual(error as? BoundedProcessError, .timedOut)
        }

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    // Stderr drain: a descendant that has already exceeded the
    // stderr cap and keeps writing still ends as .timedOut, not .outputTooLarge, because a
    // forced close gains no new overflow precedence. This is the deterministic regression
    // guard for the readData(ofLength:) crash: a partial read is always in flight at the close.
    func testBoundedRunnerFailsAsTimedOutInsteadOfCrashingWhenADescendantExceedsTheStderrCapAndKeepsWriting() async {
        let process = Process()
        let command = BoundedProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [
                "-e",
                "exit 0 if fork; print STDERR 'e' x 8192; for (1..200) { print STDERR 'e' x 100; select(undef, undef, undef, 0.02) }"
            ],
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"],
            standardInput: Data(),
            standardInputLimit: 16,
            standardOutputLimit: 1_024,
            standardErrorLimit: 1_024,
            timeout: 2
        )
        let startedAt = Date()

        do {
            let output = try await BoundedProcessRunner(process: process).run(command)
            XCTFail("A pipe held open past the drain grace must fail, not return \(output.stderr.count) truncated bytes")
        } catch {
            XCTAssertEqual(error as? BoundedProcessError, .timedOut)
        }

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SysBarBoundedProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }
}
