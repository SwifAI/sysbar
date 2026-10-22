import Foundation
import Darwin
import Darwin.Mach
@preconcurrency import SystemConfiguration

/// `mach_host_self()` acquires a new send-right reference on every call (a
/// kernel trap + uref bump we never release). Fetch once and reuse — the port
/// is stable for the process lifetime.
let kHostPort: mach_port_t = mach_host_self()

private let kTotalRAMBytes: UInt64 = {
    var bytes: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &bytes, &size, nil, 0)
    return bytes
}()

actor CPUSampler {
    private var prevUser: UInt32 = 0
    private var prevSystem: UInt32 = 0
    private var prevIdle: UInt32 = 0
    private var prevNice: UInt32 = 0
    private var hasPrev = false

    func sampleResult() -> Result<Double, TelemetryError> {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics(kHostPort, HOST_CPU_LOAD_INFO, reboundPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return .failure(.collector(
                AppResources.formatted(
                    "error.cpu.statistics",
                    fallback: "host CPU statistics failed (%d)",
                    kr
                )
            ))
        }

        let user = info.cpu_ticks.0
        let system = info.cpu_ticks.1
        let idle = info.cpu_ticks.2
        let nice = info.cpu_ticks.3

        defer {
            prevUser = user
            prevSystem = system
            prevIdle = idle
            prevNice = nice
            hasPrev = true
        }

        guard hasPrev else { return .success(0) }

        let du = Double(user &- prevUser)
        let ds = Double(system &- prevSystem)
        let di = Double(idle &- prevIdle)
        let dn = Double(nice &- prevNice)
        let total = du + ds + di + dn
        guard total > 0 else { return .success(0) }
        return .success(((du + ds + dn) / total) * 100.0)
    }
}

enum MemoryAPI {
    /// The kernel returns an append-only revision of vm_statistics64. Require
    /// only the complete prefix containing the last field used by our formula,
    /// rather than every trailing field introduced by the build SDK.
    static let requiredStatisticsCount: mach_msg_type_number_t = {
        let wordSize = MemoryLayout<integer_t>.size
        guard let offset = MemoryLayout<vm_statistics64_data_t>.offset(of: \.internal_page_count) else {
            // Imported C fields have fixed offsets; fail closed if a future
            // toolchain cannot expose this layout.
            return mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / wordSize)
        }
        let requiredBytes = offset + MemoryLayout<natural_t>.size
        return mach_msg_type_number_t((requiredBytes + wordSize - 1) / wordSize)
    }()

    static func fetchResult() -> Result<MemorySnapshot, TelemetryError> {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(kHostPort, HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return .failure(.collector(
                AppResources.formatted(
                    "error.memory.statistics",
                    fallback: "host memory statistics failed (%d)",
                    kr
                )
            ))
        }
        return snapshot(
            from: stats,
            count: count,
            totalRAMBytes: kTotalRAMBytes,
            pageSize: kernelPageSize
        )
    }

    static func snapshot(
        from stats: vm_statistics64_data_t,
        count: mach_msg_type_number_t,
        totalRAMBytes: UInt64,
        pageSize: UInt64
    ) -> Result<MemorySnapshot, TelemetryError> {
        // Older kernels can return a shorter, fully usable revision. A prefix
        // missing accounting fields would instead leave those fields zeroed
        // and must still be rejected before interpreting the sample.
        guard count >= requiredStatisticsCount else {
            return .failure(.collector(
                AppResources.formatted(
                    "error.memory.truncated",
                    fallback: "host memory statistics truncated (%1$d of %2$d fields)",
                    count,
                    requiredStatisticsCount
                )
            ))
        }
        guard totalRAMBytes > 0 else {
            return .failure(.collector(
                AppResources.localized(
                    "error.memory.totalram",
                    fallback: "total RAM size unavailable"
                )
            ))
        }

        let used = usedBytes(
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressorPages: UInt64(stats.compressor_page_count),
            pageSize: pageSize
        )
        // A physically impossible sample (used beyond total RAM) must surface
        // as a collector failure — clamping it to "0 MB available" would fire
        // critical alerts and poison history exactly like the underflow bug
        // this accounting replaced.
        guard used <= totalRAMBytes else {
            return .failure(.collector(
                AppResources.formatted(
                    "error.memory.implausible",
                    fallback: "memory accounting implausible (used %1$llu of %2$llu bytes)",
                    used,
                    totalRAMBytes
                )
            ))
        }
        // "Available" memory — what apps can actually grab on demand. Strict
        // `free + speculative` understates this on macOS because inactive cache
        // is reclaimed instantly under pressure. Derive from total - used so the
        // panel's "used" and the alert's "available" stay internally consistent.
        let trueFree = totalRAMBytes - used

        return .success(MemorySnapshot(
            usedGB: Double(used) / Double(Bytes.gb),
            freeMB: Int(trueFree / Bytes.mb),
            totalGB: Double(totalRAMBytes) / Double(Bytes.gb)
        ))
    }

    /// Activity Monitor's "Memory Used": App Memory + Wired + Compressed, where
    /// App Memory is anonymous (internal) pages minus purgeable ones.
    /// `internal_page_count` already excludes file-backed pages, unlike the
    /// active+inactive-external approximation, whose subtraction goes negative
    /// whenever the speculative queue holds file-backed pages (counted in
    /// external_page_count but in neither active nor inactive).
    /// host_statistics64 samples its counters non-atomically, so purgeable can
    /// still transiently exceed internal — clamp to zero instead of letting
    /// unsigned subtraction wrap to ~2^64 bytes.
    static func usedBytes(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64,
        pageSize: UInt64
    ) -> UInt64 {
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        // Page counts are 32-bit natural_t, so this sum times any real page
        // size stays far below UInt64.max.
        return (appPages + wiredPages + compressorPages) * pageSize
    }
}

enum SwapAPI {
    static func fetchResult() -> Result<SwapSnapshot, TelemetryError> {
        var xsu = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsu, &size, nil, 0) == 0 else {
            let code = errno
            return .failure(.collector(
                AppResources.formatted(
                    "error.swap.statistics",
                    fallback: "swap statistics failed (errno %d)",
                    code
                )
            ))
        }
        return .success(SwapSnapshot(
            usedMB: Int(xsu.xsu_used / Bytes.mb),
            totalMB: Int(xsu.xsu_total / Bytes.mb)
        ))
    }
}

actor ProcessSampler {
    /// Max believable gap between samples; beyond this the baselines reset.
    /// It covers the attention watch's one-minute cadence while the popover is
    /// closed (with slack for timer drift), so a watch sample reports the real
    /// average over that minute instead of 0%. Baselines are keyed by PID and
    /// exact start time, so a recycled PID can never inherit another's ticks.
    static let maxDeltaWindowSec: Double = 150

    private var prevTicks: [ProcessInstanceID: UInt64] = [:]
    private var prevSampleNanos: UInt64 = mach_absolute_time()
    private var nameCache: [ProcessInstanceID: String] = [:]
    private var pathCache: [ProcessInstanceID: String] = [:]
    private let timebase: mach_timebase_info_data_t
    private let identityReader = DarwinProcessIdentityReader()

    init() {
        var tb = mach_timebase_info_data_t()
        if mach_timebase_info(&tb) != KERN_SUCCESS || tb.denom == 0 {
            tb = mach_timebase_info_data_t(numer: 1, denom: 1)
        }
        self.timebase = tb
    }

    func sampleProcessesResult() -> Result<[ProcSample], TelemetryError> {
        let bufSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufSize > 0 else {
            let code = errno
            return .failure(.collector(
                AppResources.formatted(
                    "error.process.list",
                    fallback: "process list failed (errno %d)",
                    code
                )
            ))
        }
        let pidCount = Int(bufSize) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: pidCount)
        let actualSize = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress,
                          Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard actualSize > 0 else {
            let code = errno
            return .failure(.collector(
                AppResources.formatted(
                    "error.process.list.read",
                    fallback: "process list read failed (errno %d)",
                    code
                )
            ))
        }
        let realCount = Int(actualSize) / MemoryLayout<pid_t>.size
        pids = Array(pids.prefix(realCount))

        let now = mach_absolute_time()
        let elapsedRaw = now &- prevSampleNanos
        let elapsedNanos = elapsedRaw * UInt64(timebase.numer) / UInt64(timebase.denom)
        let elapsedSec = max(Double(elapsedNanos) / 1e9, 0.001)

        // Without the attention watch, sampling pauses while the panel is
        // closed. After a gap longer than the window, the first sample
        // reports 0% and re-resolves names rather than a stale average.
        if elapsedSec > Self.maxDeltaWindowSec {
            prevTicks = [:]
            nameCache = [:]
            pathCache = [:]
        }

        var newTicks: [ProcessInstanceID: UInt64] = [:]
        newTicks.reserveCapacity(pids.count)
        var samples: [ProcSample] = []
        samples.reserveCapacity(pids.count)
        var freshNameCache: [ProcessInstanceID: String] = [:]
        freshNameCache.reserveCapacity(pids.count)
        var freshPathCache: [ProcessInstanceID: String] = [:]
        freshPathCache.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            var info = proc_taskallinfo()
            let expectedSize = MemoryLayout<proc_taskallinfo>.size
            let infoSize = proc_pidinfo(
                pid,
                PROC_PIDTASKALLINFO,
                0,
                &info,
                Int32(expectedSize)
            )
            // Partial task-all-info cannot establish the exact process start
            // tuple and must never seed a signalable row.
            guard infoSize == Int32(expectedSize),
                  info.pbsd.pbi_pid == UInt32(pid) else { continue }

            let startTime = ProcessStartTime(
                seconds: info.pbsd.pbi_start_tvsec,
                microseconds: info.pbsd.pbi_start_tvusec
            )
            guard startTime.isTrustworthy else { continue }
            let instanceID = ProcessInstanceID(pid: pid, startTime: startTime)

            let totalTicks = info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system
            newTicks[instanceID] = totalTicks

            let prev = prevTicks[instanceID] ?? totalTicks
            let deltaTicks = totalTicks >= prev ? totalTicks - prev : 0
            let cpuPercent = Self.cpuPercent(deltaTicks: deltaTicks, elapsedSec: elapsedSec, timebase: timebase)

            let residentMB = Int(info.ptinfo.pti_resident_size / Bytes.mb)

            // Cache by PID + exact birth tuple so recycled PIDs never inherit a
            // dead process's name or executable path.
            let name: String
            if let cached = nameCache[instanceID] {
                name = cached
            } else {
                name = Self.lookupName(for: pid)
            }
            freshNameCache[instanceID] = name

            let executablePath: String?
            if let cached = pathCache[instanceID] {
                executablePath = cached
            } else {
                executablePath = identityReader.readExecutablePath(for: pid)
            }
            if let executablePath {
                freshPathCache[instanceID] = executablePath
            }

            samples.append(ProcSample(
                pid: pid,
                startTime: startTime,
                executablePath: executablePath,
                name: name,
                cpuPercent: cpuPercent,
                residentMB: residentMB
            ))
        }

        prevTicks = newTicks
        prevSampleNanos = now
        nameCache = freshNameCache  // drops dead process instances
        pathCache = freshPathCache

        return .success(samples)
    }

    /// `proc_taskallinfo` CPU times are Mach absolute-time ticks, not
    /// nanoseconds: on Apple Silicon one tick is 125/3 ns. Read as nanoseconds,
    /// a process using two cores showed as about 5%.
    nonisolated static func cpuPercent(
        deltaTicks: UInt64,
        elapsedSec: Double,
        timebase: mach_timebase_info_data_t
    ) -> Double {
        guard elapsedSec > 0 else { return 0 }
        let nanos = Double(deltaTicks) * Double(timebase.numer) / Double(max(1, timebase.denom))
        return nanos / 1e9 / elapsedSec * 100
    }

    /// Best-effort: proc_name → proc_pidpath last component → "pid-N"
    nonisolated static func lookupName(for pid: Int32) -> String {
        // proc_name requires the pbi_name-sized buffer (2 * MAXCOMLEN), not
        // MAXCOMLEN + 1; the latter commonly fails with ENOMEM.
        var nameBuf = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2)
        proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        let short = String(cString: nameBuf)
        if !short.isEmpty {
            return short
        }
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        if pathLen > 0 {
            let path = String(cString: pathBuf)
            if !path.isEmpty {
                return (path as NSString).lastPathComponent
            }
        }
        return "pid-\(pid)"
    }
}

enum DNSAPI {
    /// Cached store — recreating per-tick is wasteful and the store survives across calls.
    private static let store: SCDynamicStore? = SCDynamicStoreCreate(nil, "SysBar.DNS" as CFString, nil, nil)

    static func fetch() -> [String] {
        guard let store else { return [] }
        guard let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dns["ServerAddresses"] as? [String] else {
            return []
        }
        return servers
    }
}

struct NetworkByteCounters: Equatable, Sendable {
    let received: UInt64
    let sent: UInt64
}

struct NetworkRates: Equatable, Sendable {
    let received: Double
    let sent: Double

    static let zero = NetworkRates(received: 0, sent: 0)
}

/// Keeps interface lifetimes separate: attaching a device must not turn its
/// accumulated byte counter into a burst, and removing it must not erase
/// traffic from the remaining devices. Time comes from the monotonic clock.
struct NetworkRateAccumulator: Sendable {
    private var previous: [String: NetworkByteCounters] = [:]
    private var previousUptime: TimeInterval?
    private var lastRates = NetworkRates.zero

    mutating func sample(
        _ counters: [String: NetworkByteCounters],
        at uptime: TimeInterval
    ) -> NetworkRates {
        guard uptime.isFinite else { return lastRates }
        if let previousUptime {
            let elapsed = uptime - previousUptime
            // Opening the panel can request another sample immediately. Keep
            // the meaningful baseline until enough time has elapsed.
            if elapsed >= 0, elapsed <= 0.5 { return lastRates }
            if elapsed > 0.5, elapsed <= 10 {
                var received = 0.0
                var sent = 0.0
                for (name, current) in counters {
                    guard let old = previous[name] else { continue }
                    // Counters can wrap or reset when a device reconnects.
                    // Rebaseline that direction without poisoning other links.
                    if current.received >= old.received {
                        received += Double(current.received - old.received)
                    }
                    if current.sent >= old.sent {
                        sent += Double(current.sent - old.sent)
                    }
                }
                lastRates = NetworkRates(received: received / elapsed, sent: sent / elapsed)
            } else {
                // A resume after sleep needs a fresh rate interval, not an
                // average over time when monitoring was suspended.
                lastRates = .zero
            }
        }
        previous = counters
        previousUptime = uptime
        return lastRates
    }
}

actor NetworkSampler {
    private var rateAccumulator = NetworkRateAccumulator()

    func sampleResult() -> Result<NetworkState, TelemetryError> {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else {
            let code = errno
            return .failure(.collector(
                AppResources.formatted(
                    "error.network.interfaces",
                    fallback: "network interfaces failed (errno %d)",
                    code
                )
            ))
        }
        defer { freeifaddrs(ifap) }

        var vpnActive = false
        var vpnInterface: String?
        var vpnIP: String?
        var primaryIP: String?
        var counters: [String: NetworkByteCounters] = [:]

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let curr = ptr {
            defer { ptr = curr.pointee.ifa_next }

            let name = String(cString: curr.pointee.ifa_name)
            guard let sa = curr.pointee.ifa_addr else { continue }
            let family = sa.pointee.sa_family

            // AF_LINK entries carry the interface byte counters (32-bit, wrap
            // at 4 GB per interface — the rate computation clamps on wrap).
            if family == UInt8(AF_LINK), !name.hasPrefix("lo"),
               let dataPtr = curr.pointee.ifa_data {
                let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = NetworkByteCounters(
                    received: UInt64(data.ifi_ibytes),
                    sent: UInt64(data.ifi_obytes)
                )
            }

            // IPv4 only — IPv6 link-local utun stubs would create false positives
            guard family == UInt8(AF_INET) else { continue }

            var addrBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let addrIn = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var mutableAddr = addrIn
            inet_ntop(AF_INET, &mutableAddr, &addrBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: addrBuf)

            let flags = Int32(curr.pointee.ifa_flags)
            let up = (flags & IFF_UP) != 0
            let running = (flags & IFF_RUNNING) != 0

            if (name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")) && up && running {
                if !ip.hasPrefix("169.254") && ip != "0.0.0.0" {
                    vpnActive = true
                    vpnInterface = name
                    vpnIP = ip
                }
            }

            if (name == "en0" || name == "en1") && up && running && !ip.hasPrefix("169.254") {
                if primaryIP == nil {
                    primaryIP = ip
                }
            }
        }

        let rates = rateAccumulator.sample(counters, at: ProcessInfo.processInfo.systemUptime)

        return .success(NetworkState(
            vpnActive: vpnActive,
            vpnInterface: vpnInterface,
            vpnIP: vpnIP,
            dnsServers: DNSAPI.fetch(),
            primaryIP: primaryIP,
            rxBytesPerSec: rates.received,
            txBytesPerSec: rates.sent
        ))
    }
}

struct LsofCommandOutput: Sendable {
    let stdout: Data
    let terminationStatus: Int32
}

enum LsofCommandRunnerError: Error, Equatable {
    case launchFailed(String)
    case timedOut
    case outputTooLarge
}

protocol LsofCommandRunning {
    func run(timeout: TimeInterval) throws -> LsofCommandOutput
}

/// Runs lsof without letting a full stdout pipe, oversized stdout, or a stuck
/// child wedge the serial telemetry collector.
struct ProcessLsofCommandRunner: LsofCommandRunning {
    private static let lsofArguments = ["-iTCP", "-sTCP:LISTEN", "-iUDP", "-P", "-n", "-FpcnP"]
    private static let terminationGrace: TimeInterval = 0.25
    private static let forceKillGrace: TimeInterval = 0.50
    private static let drainGrace: TimeInterval = 0.50
    /// Retained stdout never exceeds this budget plus one in-flight read chunk;
    /// larger output fails closed instead of being truncated (ADR-020).
    static let defaultOutputLimit = 4 * 1_024 * 1_024
    static let readChunkSize = 4_096
    private static let cleanupQueue = DispatchQueue(
        label: "sysbar.lsof.cleanup",
        qos: .utility,
        attributes: .concurrent
    )

    private let executableURL: URL
    private let arguments: [String]
    private let process: Process
    private let outputLimit: Int

    init() {
        self.init(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: Self.lsofArguments
        )
    }

    /// Internal injection point for bounded subprocess integration tests. The
    /// production default remains fixed to `/usr/sbin/lsof`.
    init(
        executableURL: URL,
        arguments: [String],
        process: Process = Process(),
        outputLimit: Int = ProcessLsofCommandRunner.defaultOutputLimit
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.process = process
        self.outputLimit = outputLimit
    }

    func run(timeout: TimeInterval) throws -> LsofCommandOutput {
        process.executableURL = executableURL
        process.arguments = arguments
        process.qualityOfService = .utility

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // An undrained stderr pipe can fill and block the child indefinitely.
        process.standardError = FileHandle.nullDevice

        let exitGroup = DispatchGroup()
        exitGroup.enter()
        process.terminationHandler = { _ in exitGroup.leave() }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw LsofCommandRunnerError.launchFailed(error.localizedDescription)
        }
        // The child owns its duplicated descriptor after spawn. Closing the
        // parent's writer guarantees EOF once the child (and any descendants)
        // release stdout.
        stdoutPipe.fileHandleForWriting.closeFile()

        // Drain concurrently while waiting for exit. Waiting first can deadlock
        // once lsof fills the kernel pipe buffer.
        let outputBuffer = LsofOutputBuffer(limit: outputLimit)
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            // Keep draining past the cap (discarding) so the child can never block on a
            // full pipe: the cap bounds retained memory, the timeout still bounds time.
            // read(upToCount:) throws, rather than raising an Objective-C exception,
            // if finishDrain closes the reader between chunks.
            while let chunk = try? stdoutPipe.fileHandleForReading.read(upToCount: Self.readChunkSize),
                  !chunk.isEmpty {
                outputBuffer.append(chunk)
            }
            drainGroup.leave()
        }

        // An exceeded budget is the specific cause, so it wins over every other
        // post-launch failure and over the exit status.
        guard exitGroup.wait(timeout: Self.deadline(after: max(0, timeout))) == .success else {
            _ = Self.stopAndReap(process, exitGroup: exitGroup)
            _ = Self.finishDrain(stdoutPipe, drainGroup: drainGroup)
            throw outputBuffer.snapshot.exceededLimit ? LsofCommandRunnerError.outputTooLarge : .timedOut
        }

        // A fired termination handler means Foundation has observed and reaped
        // the child, so status is valid without another potentially blocking
        // waitUntilExit call.
        guard Self.finishDrain(stdoutPipe, drainGroup: drainGroup) else {
            throw outputBuffer.snapshot.exceededLimit ? LsofCommandRunnerError.outputTooLarge : .timedOut
        }

        let captured = outputBuffer.snapshot
        guard !captured.exceededLimit else {
            throw LsofCommandRunnerError.outputTooLarge
        }
        return LsofCommandOutput(
            stdout: captured.data,
            terminationStatus: process.terminationStatus
        )
    }

    @discardableResult
    private static func stopAndReap(_ process: Process, exitGroup: DispatchGroup) -> Bool {
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

        // Preserve the collector's hard bound even under an abnormal kernel or
        // Foundation delay. This retained closure still waits and reaps, so the
        // child is not abandoned merely because the caller's deadline expired.
        cleanupQueue.async {
            process.waitUntilExit()
        }
        return false
    }

    @discardableResult
    private static func finishDrain(_ pipe: Pipe, drainGroup: DispatchGroup) -> Bool {
        if drainGroup.wait(timeout: deadline(after: drainGrace)) == .success {
            return true
        }

        // A descendant inheriting stdout could otherwise keep EOF open after
        // lsof exits. Closing the reader bounds that failure path.
        pipe.fileHandleForReading.closeFile()
        if drainGroup.wait(timeout: deadline(after: drainGrace)) == .timedOut {
            // Retain an explicit cleanup waiter without blocking the collector.
            // The drain closure itself retains the pipe until its read unwinds.
            cleanupQueue.async {
                drainGroup.wait()
            }
        }
        return false
    }

    private static func deadline(after interval: TimeInterval) -> DispatchTime {
        .now() + .milliseconds(max(1, Int(interval * 1_000)))
    }
}

/// Size-capped stdout accumulator; mirrors `CodexCappedDataBuffer` (ADR-020).
final class LsofOutputBuffer: @unchecked Sendable {
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

enum PortsAPI {
    private static let defaultTimeout: TimeInterval = 5

    /// Production collection deliberately leaves listeners non-actionable.
    /// lsof does not report a process birth time or executable path, so a
    /// post-lsof lookup alone could bless a replacement that reused the PID.
    static func fetchResult(
        timeout: TimeInterval = defaultTimeout
    ) -> Result<[ListenSocket], TelemetryError> {
        fetchParsedResult(runner: ProcessLsofCommandRunner(), timeout: timeout)
    }

    /// Deterministic parser/runner seam retained for collector tests. Supplying
    /// only a runner deliberately performs no ambient host identity reads.
    static func fetchResult(
        runner: any LsofCommandRunning,
        timeout: TimeInterval = defaultTimeout
    ) -> Result<[ListenSocket], TelemetryError> {
        fetchParsedResult(runner: runner, timeout: timeout)
    }

    /// Bracketed enrichment seam. `expectedIdentities` must be captured before
    /// this call starts lsof; after parsing, the same identity is resolved again
    /// before it can be attached. Missing or changed identities fail closed.
    static func fetchResult(
        runner: any LsofCommandRunning,
        expectedIdentities: [Int32: ProcessIdentity],
        postValidationReader: any ProcessIdentityReading,
        timeout: TimeInterval = defaultTimeout
    ) -> Result<[ListenSocket], TelemetryError> {
        fetchParsedResult(runner: runner, timeout: timeout).map { sockets in
            bracketed(
                sockets,
                expectedIdentities: expectedIdentities,
                postValidationReader: postValidationReader
            )
        }
    }

    /// Click-time proof for Stop on a new-listener card (ADR-023). `expected`
    /// is the identity read when the user pressed Stop; this re-runs the same
    /// fixed, bounded lsof scan bracketed by that identity, so a PID recycled
    /// at any point since then can never be reported as `.confirmed`. Never
    /// used by the periodic collector, which stays identity-free (ADR-019).
    static func ownership(
        of target: ListenerStopTarget,
        expected: ProcessIdentity,
        runner: any LsofCommandRunning = ProcessLsofCommandRunner(),
        reader: any ProcessIdentityReading = DarwinProcessIdentityReader(),
        timeout: TimeInterval = defaultTimeout
    ) -> ListenerOwnership {
        guard expected.pid == target.pid else { return .changed }
        let scan = fetchResult(
            runner: runner,
            expectedIdentities: [target.pid: expected],
            postValidationReader: reader,
            timeout: timeout
        )
        return ListenerOwnership.evaluate(scan, target: target, expected: expected)
    }

    /// Fixed message: never echoes lsof output, sizes, or PIDs into the UI.
    private static var outputTooLargeError: TelemetryError {
        .collector(AppResources.localized(
            "error.lsof.output.too.large",
            fallback: "lsof output exceeded the size limit"
        ))
    }

    private static func fetchParsedResult(
        runner: any LsofCommandRunning,
        timeout: TimeInterval
    ) -> Result<[ListenSocket], TelemetryError> {
        let command: LsofCommandOutput
        do {
            command = try runner.run(timeout: timeout)
        } catch let error as LsofCommandRunnerError {
            switch error {
            case let .launchFailed(message):
                return .failure(.collector(
                    AppResources.formatted(
                        "error.lsof.launch",
                        fallback: "lsof launch failed: %@",
                        message
                    )
                ))
            case .timedOut:
                return .failure(.timedOut(
                    AppResources.localized("error.lsof.timeout", fallback: "lsof timed out")
                ))
            case .outputTooLarge:
                return .failure(outputTooLargeError)
            }
        } catch {
            return .failure(.collector(
                AppResources.formatted(
                    "error.lsof.failure",
                    fallback: "lsof failed: %@",
                    error.localizedDescription
                )
            ))
        }

        // Defense in depth: over-budget bytes from any runner fail closed before
        // they are status-interpreted, decoded, or parsed into a truncated list.
        guard command.stdout.count <= ProcessLsofCommandRunner.defaultOutputLimit else {
            return .failure(outputTooLargeError)
        }

        // Darwin lsof 4.91 uses status 1 for a successful selection that found
        // no files. Empty stdout is the discriminator; any other nonzero exit
        // remains a collector failure.
        if command.terminationStatus == 1, command.stdout.isEmpty {
            return .success([])
        }
        guard command.terminationStatus == 0 else {
            return .failure(.collector(
                AppResources.formatted(
                    "error.lsof.exit.status",
                    fallback: "lsof exited with status %d",
                    command.terminationStatus
                )
            ))
        }
        guard let output = String(data: command.stdout, encoding: .utf8) else {
            return .failure(.collector(
                AppResources.localized(
                    "error.lsof.invalid.utf8",
                    fallback: "lsof output was not valid UTF-8"
                )
            ))
        }
        return .success(parseLsofOutput(output))
    }

    private enum CachedProcessIdentity {
        case available(ProcessIdentity)
        case unavailable

        var value: ProcessIdentity? {
            switch self {
            case let .available(identity): return identity
            case .unavailable: return nil
            }
        }
    }

    private static func bracketed(
        _ sockets: [ListenSocket],
        expectedIdentities: [Int32: ProcessIdentity],
        postValidationReader: any ProcessIdentityReading
    ) -> [ListenSocket] {
        let resolver = ProcessIdentityResolver(reader: postValidationReader)
        var identities: [Int32: CachedProcessIdentity] = [:]
        identities.reserveCapacity(sockets.count)

        return sockets.map { socket in
            let cached: CachedProcessIdentity
            if let existing = identities[socket.pid] {
                cached = existing
            } else if let expected = expectedIdentities[socket.pid], expected.pid == socket.pid {
                switch resolver.resolve(pid: socket.pid) {
                case let .success(observed) where observed == expected:
                    cached = .available(expected)
                case .success, .failure:
                    cached = .unavailable
                }
                identities[socket.pid] = cached
            } else {
                cached = .unavailable
                identities[socket.pid] = cached
            }

            return ListenSocket(
                pid: socket.pid,
                processName: socket.processName,
                port: socket.port,
                bindAddress: socket.bindAddress,
                isTCP: socket.isTCP,
                processIdentity: cached.value
            )
        }
    }

    /// Parse `lsof -FpcnP` line-prefixed output:
    /// p<pid>
    /// c<command>
    /// P<protocol>  (TCP/UDP, per file)
    /// n<bind:port>
    static func parseLsofOutput(_ output: String) -> [ListenSocket] {
        var results: [ListenSocket] = []
        var seen = Set<ListenerEndpointKey>()
        var currentPID: Int32?
        var currentCmd: String?
        var currentTransport: ListenerTransport?

        for line in output.split(separator: "\n") {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p":
                if let pid = Int32(value), pid > 0 {
                    currentPID = pid
                } else {
                    currentPID = nil
                }
                currentCmd = nil
                currentTransport = nil
            case "c":
                let command = value.trimmingCharacters(in: .whitespacesAndNewlines)
                currentCmd = currentPID == nil || command.isEmpty ? nil : command
            case "f":
                // Protocol is per file record. Never let a preceding PTCP/PUDP
                // value bleed into the next descriptor.
                currentTransport = nil
            case "P":
                switch value {
                case "TCP": currentTransport = .tcp
                case "UDP": currentTransport = .udp
                default: currentTransport = nil
                }
            case "n":
                guard let currentPID, let currentCmd, let currentTransport else { continue }
                // Connected sockets ("a->b") aren't listeners
                guard !value.contains("->") else { continue }
                guard let parsed = parseAddress(value) else { continue }
                let socket = ListenSocket(
                    pid: currentPID,
                    processName: currentCmd,
                    port: parsed.port,
                    bindAddress: parsed.bind,
                    isTCP: currentTransport == .tcp
                )
                guard seen.insert(socket.endpointKey).inserted else { continue }
                results.append(socket)
            default:
                continue
            }
        }
        // Actionable LAN-exposed listeners first, loopback next, ephemeral
        // UDP churn last — otherwise dozens of QUIC sockets bury the real ones.
        func rank(_ s: ListenSocket) -> Int {
            if s.isNoiseUDP { return 2 }
            return s.isLanExposed ? 0 : 1
        }
        return results.sorted { lhs, rhs in
            let lr = rank(lhs)
            let rr = rank(rhs)
            if lr != rr { return lr < rr }
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            if lhs.bindAddress != rhs.bindAddress { return lhs.bindAddress < rhs.bindAddress }
            if lhs.isTCP != rhs.isTCP { return lhs.isTCP && !rhs.isTCP }
            if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
            return lhs.processName < rhs.processName
        }
    }

    private static func parseAddress(_ str: String) -> (bind: String, port: UInt16)? {
        var clean = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasSuffix(" (LISTEN)") {
            clean.removeLast(" (LISTEN)".count)
            clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // IPv6 form: [::1]:50121 or [*]:62474
        if clean.hasPrefix("[") {
            guard let closing = clean.firstIndex(of: "]") else { return nil }
            let bind = String(clean[clean.index(after: clean.startIndex)..<closing])
            let after = clean.index(after: closing)
            guard after < clean.endIndex, clean[after] == ":" else { return nil }
            let portStr = String(clean[clean.index(after: after)...])
            guard let port = UInt16(portStr), port > 0 else { return nil }
            return (ListenSocket.normalizeBindAddress(bind), port)
        }

        // IPv4 form: *:8080 or 127.0.0.1:7265
        guard let lastColon = clean.lastIndex(of: ":") else { return nil }
        let bind = String(clean[clean.startIndex..<lastColon])
        let portStr = String(clean[clean.index(after: lastColon)...])
        guard let port = UInt16(portStr), port > 0 else { return nil }
        return (ListenSocket.normalizeBindAddress(bind), port)
    }
}

// MARK: - Disk

enum DiskAPI {
    private static let skipNames: Set<String> = [
        "Preboot", "VM", "Update", "xarts", "iSCPreboot", "Recovery"
    ]

    static func fetchResult() -> Result<DiskSnapshot, TelemetryError> {
        let keys: [URLResourceKey] = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeNameKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return .failure(.collector(
                AppResources.localized(
                    "error.disk.inventory",
                    fallback: "mounted volume inventory was unavailable"
                )
            ))
        }

        let resourceKeys = Set(keys)
        var seenNames = Set<String>()
        var vols: [VolumeInfo] = []
        var hasUnreadableVolume = false

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
                hasUnreadableVolume = true
                continue
            }
            let name = values.volumeName ?? url.lastPathComponent
            if name.isEmpty { continue }
            if skipNames.contains(name) { continue }

            // Skip by path token as well
            let path = url.path
            if Self.skipNames.contains(where: { path.contains("/" + $0) }) { continue }

            guard let total = values.volumeTotalCapacity, total > 0 else { continue }
            // Some filesystems expose only ordinary available capacity.
            // Missing capacity is unknown telemetry, never a full disk.
            guard let freeInt64 = availableBytes(
                important: values.volumeAvailableCapacityForImportantUsage,
                ordinary: values.volumeAvailableCapacity,
                total: total
            ) else {
                hasUnreadableVolume = true
                continue
            }
            let totalGB = Double(total) / Double(Bytes.gb)
            let freeGB = Double(freeInt64) / Double(Bytes.gb)
            if totalGB < 0.1 { continue }

            let isInternal = values.volumeIsInternal ?? true
            let isRemovable = values.volumeIsRemovable ?? false
            let isExternal = !isInternal || isRemovable

            // Deduplicate by name
            if seenNames.contains(name) { continue }
            seenNames.insert(name)

            vols.append(VolumeInfo(
                name: name,
                totalGB: totalGB,
                freeGB: freeGB,
                isExternal: isExternal
            ))
        }

        guard !vols.isEmpty || !hasUnreadableVolume else {
            return .failure(.collector(
                AppResources.localized(
                    "error.disk.inventory",
                    fallback: "mounted volume inventory was unavailable"
                )
            ))
        }

        // Sort internal first, then by name
        vols.sort { lhs, rhs in
            if lhs.isExternal != rhs.isExternal {
                return !lhs.isExternal && rhs.isExternal
            }
            return lhs.name < rhs.name
        }

        return .success(DiskSnapshot(volumes: vols))
    }

    /// Prefer Finder's reclaimable-capacity estimate, with ordinary free
    /// bytes as the fallback. Reject missing or impossible readings so they
    /// cannot produce a false storage-critical insight.
    static func availableBytes(important: Int64?, ordinary: Int?, total: Int) -> Int64? {
        guard total > 0 else { return nil }
        if let important, important >= 0, important <= Int64(total) { return important }
        if let ordinary, ordinary >= 0, ordinary <= total { return Int64(ordinary) }
        return nil
    }
}
