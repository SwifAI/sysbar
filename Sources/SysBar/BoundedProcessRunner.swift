import Foundation
import Darwin

struct BoundedProcessCommand: Sendable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let environment: [String: String]
    let standardInput: Data
    let standardInputLimit: Int
    let standardOutputLimit: Int
    let standardErrorLimit: Int
    let timeout: TimeInterval
}

struct BoundedProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
    let stdoutExceededLimit: Bool
    let stderrExceededLimit: Bool

    init(
        stdout: Data,
        stderr: Data,
        terminationStatus: Int32,
        stdoutExceededLimit: Bool = false,
        stderrExceededLimit: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.terminationStatus = terminationStatus
        self.stdoutExceededLimit = stdoutExceededLimit
        self.stderrExceededLimit = stderrExceededLimit
    }
}

enum BoundedProcessError: Error, Equatable, Sendable {
    case launchFailed
    case inputTooLarge
    case outputTooLarge
    case timedOut
    case cancelled
}

protocol BoundedProcessRunning: Sendable {
    func run(_ command: BoundedProcessCommand) async throws -> BoundedProcessOutput
}

/// A direct Foundation.Process runner with bounded input, retained output,
/// timeout, cancellation, concurrent pipe drains, and child reaping. It never
/// invokes a shell. Foundation does not provide an atomic new-process-group
/// spawn API, so termination is guaranteed for the direct child only.
struct BoundedProcessRunner: BoundedProcessRunning, @unchecked Sendable {
    private static let terminationGrace: TimeInterval = 0.25
    private static let forceKillGrace: TimeInterval = 0.75
    private static let drainGrace: TimeInterval = 0.50
    private static let cleanupQueue = DispatchQueue(
        label: "sysbar.process.cleanup",
        qos: .utility,
        attributes: .concurrent
    )

    private let injectedProcess: ProcessBox?

    init() {
        injectedProcess = nil
    }

    init(process: Process) {
        injectedProcess = ProcessBox(process)
    }

    func run(_ command: BoundedProcessCommand) async throws -> BoundedProcessOutput {
        guard command.standardInput.count <= max(0, command.standardInputLimit) else {
            throw BoundedProcessError.inputTooLarge
        }

        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                Self.cleanupQueue.async {
                    do {
                        continuation.resume(
                            returning: try runSynchronously(command, cancellation: cancellation)
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func runSynchronously(
        _ command: BoundedProcessCommand,
        cancellation: ProcessCancellation
    ) throws -> BoundedProcessOutput {
        let processBox = injectedProcess ?? ProcessBox(Process())
        let process = processBox.process
        guard cancellation.register(processBox) else {
            throw BoundedProcessError.cancelled
        }

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL
        process.environment = command.environment
        process.qualityOfService = .utility

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let inputHandle = stdinPipe.fileHandleForWriting
        guard Darwin.fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            Self.closeAll(stdinPipe, stdoutPipe, stderrPipe)
            throw BoundedProcessError.launchFailed
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exitGroup = DispatchGroup()
        exitGroup.enter()
        process.terminationHandler = { _ in exitGroup.leave() }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            Self.closeAll(stdinPipe, stdoutPipe, stderrPipe)
            throw BoundedProcessError.launchFailed
        }

        // The child owns its duplicated descriptors after spawn. Closing the
        // parent's unused endpoints allows EOF to propagate deterministically.
        stdinPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let stdoutBuffer = CappedDataBuffer(limit: command.standardOutputLimit)
        let stderrBuffer = CappedDataBuffer(limit: command.standardErrorLimit)
        let drainGroup = DispatchGroup()
        Self.startDrain(
            stdoutPipe.fileHandleForReading,
            into: stdoutBuffer,
            group: drainGroup
        )
        Self.startDrain(
            stderrPipe.fileHandleForReading,
            into: stderrBuffer,
            group: drainGroup
        )

        let inputGroup = DispatchGroup()
        inputGroup.enter()
        let input = command.standardInput
        Self.cleanupQueue.async {
            if !input.isEmpty {
                try? inputHandle.write(contentsOf: input)
            }
            inputHandle.closeFile()
            inputGroup.leave()
        }

        if cancellation.isCancelled {
            _ = Self.stopAndReap(processBox, exitGroup: exitGroup)
        }

        let didExit = exitGroup.wait(
            timeout: Self.deadline(after: max(0, command.timeout))
        ) == .success
        if !didExit {
            _ = Self.stopAndReap(processBox, exitGroup: exitGroup)
            _ = Self.finishInput(inputHandle, group: inputGroup)
            _ = Self.finishDrains(
                [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading],
                group: drainGroup
            )
            throw cancellation.isCancelled
                ? BoundedProcessError.cancelled
                : BoundedProcessError.timedOut
        }

        guard Self.finishInput(inputHandle, group: inputGroup),
              Self.finishDrains(
                [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading],
                group: drainGroup
              ) else {
            throw cancellation.isCancelled
                ? BoundedProcessError.cancelled
                : BoundedProcessError.timedOut
        }
        if cancellation.isCancelled {
            throw BoundedProcessError.cancelled
        }

        return BoundedProcessOutput(
            stdout: stdoutBuffer.snapshot.data,
            stderr: stderrBuffer.snapshot.data,
            terminationStatus: process.terminationStatus,
            stdoutExceededLimit: stdoutBuffer.snapshot.exceededLimit,
            stderrExceededLimit: stderrBuffer.snapshot.exceededLimit
        )
    }

    private static func startDrain(
        _ handle: FileHandle,
        into buffer: CappedDataBuffer,
        group: DispatchGroup
    ) {
        group.enter()
        cleanupQueue.async {
            // read(upToCount:) throws, rather than raising an Objective-C
            // exception, if finishDrains closes the handle between chunks.
            while let chunk = try? handle.read(upToCount: 4_096), !chunk.isEmpty {
                buffer.append(chunk)
            }
            group.leave()
        }
    }

    @discardableResult
    private static func stopAndReap(
        _ processBox: ProcessBox,
        exitGroup: DispatchGroup
    ) -> Bool {
        let process = processBox.process
        if process.isRunning {
            process.terminate()
        }
        if exitGroup.wait(timeout: deadline(after: terminationGrace)) == .success {
            return true
        }

        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        if exitGroup.wait(timeout: deadline(after: forceKillGrace)) == .success {
            return true
        }

        // Keep the public call bounded. The retained waiter ensures Foundation
        // still observes and reaps an abnormally delayed direct child.
        cleanupQueue.async {
            process.waitUntilExit()
        }
        return false
    }

    @discardableResult
    private static func finishInput(
        _ handle: FileHandle,
        group: DispatchGroup
    ) -> Bool {
        if group.wait(timeout: deadline(after: drainGrace)) == .success {
            return true
        }
        handle.closeFile()
        if group.wait(timeout: deadline(after: drainGrace)) == .success {
            return true
        }
        cleanupQueue.async { group.wait() }
        return false
    }

    @discardableResult
    private static func finishDrains(
        _ handles: [FileHandle],
        group: DispatchGroup
    ) -> Bool {
        if group.wait(timeout: deadline(after: drainGrace)) == .success {
            return true
        }
        // A descendant inheriting stdout or stderr can hold the pipe open
        // after the child exits. Closing the readers bounds that path, and output
        // that never reached EOF is incomplete, so a forced close always fails.
        handles.forEach { $0.closeFile() }
        if group.wait(timeout: deadline(after: drainGrace)) == .timedOut {
            cleanupQueue.async { group.wait() }
        }
        return false
    }

    private static func closeAll(_ pipes: Pipe...) {
        for pipe in pipes {
            pipe.fileHandleForReading.closeFile()
            pipe.fileHandleForWriting.closeFile()
        }
    }

    private static func deadline(after interval: TimeInterval) -> DispatchTime {
        .now() + .milliseconds(max(1, Int(interval * 1_000)))
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var processBox: ProcessBox?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ processBox: ProcessBox) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.processBox = processBox
        return !cancelled
    }

    func cancel() {
        let box: ProcessBox?
        lock.lock()
        cancelled = true
        box = processBox
        lock.unlock()

        guard let box else { return }
        let process = box.process
        if process.isRunning {
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

private final class CappedDataBuffer: @unchecked Sendable {
    struct Snapshot {
        let data: Data
        let exceededLimit: Bool
    }

    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var exceededLimit = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if chunk.count > remaining {
            exceededLimit = true
        }
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(data: data, exceededLimit: exceededLimit)
    }
}
