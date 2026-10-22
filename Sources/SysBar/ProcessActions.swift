import Darwin
import Foundation

/// The process metadata needed to prove that two reads describe the same
/// process instance. Production reads only succeed when `proc_pidinfo` returns
/// the complete `proc_bsdinfo` structure.
struct ProcessBSDIdentitySnapshot: Equatable, Sendable {
    let pid: Int32
    let startTime: ProcessStartTime
    let status: UInt32
    let flags: UInt32

    init(pid: Int32, startTime: ProcessStartTime, status: UInt32, flags: UInt32) {
        self.pid = pid
        self.startTime = startTime
        self.status = status
        self.flags = flags
    }

    init(identity: ProcessIdentity, status: UInt32 = UInt32(SRUN), flags: UInt32 = 0) {
        self.init(
            pid: identity.pid,
            startTime: identity.startTime,
            status: status,
            flags: flags
        )
    }
}

/// Injectable boundary around libproc identity reads. Keeping the individual
/// BSD/path operations visible lets the resolver enforce BSD → path → BSD.
protocol ProcessIdentityReading: Sendable {
    func readBSDInfo(for pid: Int32) -> ProcessBSDIdentitySnapshot?
    func readExecutablePath(for pid: Int32) -> String?
}

struct DarwinProcessIdentityReader: ProcessIdentityReading {
    func readBSDInfo(for pid: Int32) -> ProcessBSDIdentitySnapshot? {
        guard pid > 0 else { return nil }

        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let returnedSize = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        guard returnedSize == Int32(expectedSize),
              let observedPID = Int32(exactly: info.pbi_pid) else {
            return nil
        }

        return ProcessBSDIdentitySnapshot(
            pid: observedPID,
            startTime: ProcessStartTime(
                seconds: info.pbi_start_tvsec,
                microseconds: info.pbi_start_tvusec
            ),
            status: info.pbi_status,
            flags: info.pbi_flags
        )
    }

    func readExecutablePath(for pid: Int32) -> String? {
        guard pid > 0 else { return nil }

        // proc_pidpath documents a 4 * MAXPATHLEN buffer requirement.
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
            proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard length > 0, Int(length) <= buffer.count else { return nil }

        let pathBytes = buffer.prefix(Int(length)).prefix { $0 != 0 }
        guard let path = String(bytes: pathBytes, encoding: .utf8), !path.isEmpty else {
            return nil
        }
        return path
    }
}

enum ProcessUnsafeState: Equatable, Sendable {
    case idle
    case zombie
    case inExit
}

enum ProcessIdentityReadFailure: Error, Equatable, Sendable {
    case invalidPID(Int32)
    case bsdInfoUnavailable(pid: Int32)
    case executablePathUnavailable(pid: Int32)
    case changedDuringRead(pid: Int32)
    case unsafeState(pid: Int32, state: ProcessUnsafeState)
    case invalidIdentity(pid: Int32)
}

/// Resolves one process identity using two exact BSD reads around the path
/// lookup. The caller must still compare the result with its previously
/// captured expected identity.
struct ProcessIdentityResolver: Sendable {
    private let reader: any ProcessIdentityReading

    init(reader: any ProcessIdentityReading) {
        self.reader = reader
    }

    func resolve(pid: Int32) -> Result<ProcessIdentity, ProcessIdentityReadFailure> {
        guard pid > 0 else { return .failure(.invalidPID(pid)) }
        guard let before = reader.readBSDInfo(for: pid) else {
            return .failure(.bsdInfoUnavailable(pid: pid))
        }
        guard let path = reader.readExecutablePath(for: pid) else {
            return .failure(.executablePathUnavailable(pid: pid))
        }
        guard let after = reader.readBSDInfo(for: pid) else {
            return .failure(.bsdInfoUnavailable(pid: pid))
        }

        guard before == after, before.pid == pid else {
            return .failure(.changedDuringRead(pid: pid))
        }
        if before.status == UInt32(SIDL) {
            return .failure(.unsafeState(pid: pid, state: .idle))
        }
        if before.status == UInt32(SZOMB) {
            return .failure(.unsafeState(pid: pid, state: .zombie))
        }
        if before.flags & UInt32(PROC_FLAG_INEXIT) != 0 {
            return .failure(.unsafeState(pid: pid, state: .inExit))
        }
        guard let identity = ProcessIdentity(
            pid: pid,
            startTime: before.startTime,
            executablePath: path
        ) else {
            return .failure(.invalidIdentity(pid: pid))
        }
        return .success(identity)
    }
}

enum ProcessSignal: Equatable, Sendable {
    case terminate
    case forceKill

    var rawValue: Int32 {
        switch self {
        case .terminate: return SIGTERM
        case .forceKill: return SIGKILL
        }
    }
}

struct ProcessSignalError: Error, Equatable, Sendable {
    let errnoCode: Int32
}

protocol ProcessSignalSending: Sendable {
    func send(_ signal: ProcessSignal, to pid: Int32) -> Result<Void, ProcessSignalError>
}

struct DarwinProcessSignalSender: ProcessSignalSending {
    func send(_ signal: ProcessSignal, to pid: Int32) -> Result<Void, ProcessSignalError> {
        guard Darwin.kill(pid, signal.rawValue) != 0 else { return .success(()) }
        let capturedErrno = errno
        return .failure(ProcessSignalError(errnoCode: capturedErrno))
    }
}

enum ProcessActionFailure: Equatable, Sendable {
    case unsafePID
    case preflightAborted
    case identityReadFailed(ProcessIdentityReadFailure)
    case staleIdentity(observed: ProcessIdentity)
    case signalFailed(ProcessSignalError)
}

enum ProcessActionOutcome: Equatable, Sendable {
    case signaled
    case notSignaled(ProcessActionFailure)
}

struct ProcessActionMemberResult: Equatable, Sendable {
    let identity: ProcessIdentity
    let outcome: ProcessActionOutcome
}

struct ProcessActionReport: Equatable, Sendable {
    let signal: ProcessSignal
    let results: [ProcessActionMemberResult]
}

/// Executes identity-bound process actions. Group-wide atomicity applies to
/// preflight only: once signaling starts, every member is independently
/// revalidated immediately before its signal and an OS failure is retained in
/// the per-member report. There is necessarily a tiny kernel-level TOCTOU
/// between the final BSD read and `kill(2)` because macOS exposes no pidfd.
actor ProcessActionService {
    private let resolver: ProcessIdentityResolver
    private let signalSender: any ProcessSignalSending
    private let selfPID: Int32

    init(
        identityReader: any ProcessIdentityReading = DarwinProcessIdentityReader(),
        signalSender: any ProcessSignalSending = DarwinProcessSignalSender(),
        selfPID: Int32 = getpid()
    ) {
        resolver = ProcessIdentityResolver(reader: identityReader)
        self.signalSender = signalSender
        self.selfPID = selfPID
    }

    func perform(_ signal: ProcessSignal, on identities: [ProcessIdentity]) -> ProcessActionReport {
        let preflightFailures = identities.map(preflightFailure)
        if preflightFailures.contains(where: { $0 != nil }) {
            let results = zip(identities, preflightFailures).map { identity, failure in
                ProcessActionMemberResult(
                    identity: identity,
                    outcome: .notSignaled(failure ?? .preflightAborted)
                )
            }
            return ProcessActionReport(signal: signal, results: results)
        }

        let results = identities.map { expected -> ProcessActionMemberResult in
            if let failure = validationFailure(for: expected) {
                return ProcessActionMemberResult(identity: expected, outcome: .notSignaled(failure))
            }
            switch signalSender.send(signal, to: expected.pid) {
            case .success:
                return ProcessActionMemberResult(identity: expected, outcome: .signaled)
            case let .failure(error):
                return ProcessActionMemberResult(
                    identity: expected,
                    outcome: .notSignaled(.signalFailed(error))
                )
            }
        }
        return ProcessActionReport(signal: signal, results: results)
    }

    private func preflightFailure(for expected: ProcessIdentity) -> ProcessActionFailure? {
        guard expected.pid > 1, expected.pid != selfPID else { return .unsafePID }
        return validationFailure(for: expected)
    }

    private func validationFailure(for expected: ProcessIdentity) -> ProcessActionFailure? {
        switch resolver.resolve(pid: expected.pid) {
        case let .failure(error):
            return .identityReadFailed(error)
        case let .success(observed):
            return observed == expected ? nil : .staleIdentity(observed: observed)
        }
    }
}
