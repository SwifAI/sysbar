import Foundation
import Darwin

enum Bytes {
    static let mb: UInt64 = 1 << 20
    static let gb: UInt64 = 1 << 30
}

enum MetricKind {
    case percent
    case megabytes

    func format(_ value: Double) -> String {
        switch self {
        case .percent:
            return MetricFormat.percent(value)
        case .megabytes:
            return MetricFormat.memory(megabytes: Int(value))
        }
    }
}

struct MemorySnapshot: Equatable, Sendable {
    var usedGB: Double
    var freeMB: Int
    var totalGB: Double

    static let empty = MemorySnapshot(usedGB: 0, freeMB: 0, totalGB: 16)

    var pressurePercent: Double {
        guard totalGB > 0 else { return 0 }
        return min(100, max(0, (usedGB / totalGB) * 100))
    }
}

struct SwapSnapshot: Equatable, Sendable {
    var usedMB: Int
    var totalMB: Int

    static let empty = SwapSnapshot(usedMB: 0, totalMB: 0)

    var percent: Double {
        guard totalMB > 0 else { return 0 }
        return Double(usedMB) / Double(totalMB) * 100
    }
}

/// Exact process birth time as reported by `proc_bsdinfo`. Keeping the timeval
/// tuple intact avoids rounding two distinct process instances through
/// `Date`/`Double` during destructive-action validation.
struct ProcessStartTime: Hashable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64

    static let unknown = ProcessStartTime(seconds: 0, microseconds: 0)

    var isTrustworthy: Bool {
        seconds > 0 && microseconds < 1_000_000
    }
}

/// PID reuse-safe identity for UI rows and process sampling baselines.
struct ProcessInstanceID: Hashable, Sendable {
    let pid: Int32
    let startTime: ProcessStartTime
}

/// Identity that is strong enough to authorize a process signal. Paths remain
/// case-sensitive because that is part of the observed executable identity.
struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startTime: ProcessStartTime
    let executablePath: String

    init?(pid: Int32, startTime: ProcessStartTime, executablePath: String) {
        guard pid > 0, startTime.isTrustworthy, !executablePath.isEmpty else {
            return nil
        }
        self.pid = pid
        self.startTime = startTime
        self.executablePath = executablePath
    }

    var instanceID: ProcessInstanceID {
        ProcessInstanceID(pid: pid, startTime: startTime)
    }
}

struct ProcSample: Identifiable, Hashable, Sendable {
    let pid: Int32
    let startTime: ProcessStartTime
    let executablePath: String?
    let name: String
    let cpuPercent: Double
    let residentMB: Int

    init(
        pid: Int32,
        startTime: ProcessStartTime = .unknown,
        executablePath: String? = nil,
        name: String,
        cpuPercent: Double,
        residentMB: Int
    ) {
        self.pid = pid
        self.startTime = startTime
        self.executablePath = executablePath
        self.name = name
        self.cpuPercent = cpuPercent
        self.residentMB = residentMB
    }

    var id: ProcessInstanceID {
        ProcessInstanceID(pid: pid, startTime: startTime)
    }

    var identity: ProcessIdentity? {
        guard let executablePath else { return nil }
        return ProcessIdentity(pid: pid, startTime: startTime, executablePath: executablePath)
    }
}

enum ProcessGroupID: Hashable, Sendable {
    case executablePath(String)
    case unresolved(ProcessInstanceID)
}

struct ProcessGroup: Identifiable, Hashable, Sendable {
    let id: ProcessGroupID
    let name: String
    let executablePath: String?
    let pids: [Int32]
    let expectedIdentities: [ProcessIdentity]
    let totalCPU: Double
    let totalMemMB: Int

    var count: Int { pids.count }
    var isActionable: Bool {
        !pids.isEmpty && expectedIdentities.count == pids.count
    }
}

enum ListenerTransport: String, Hashable, Sendable {
    case tcp
    case udp
}

enum ListenerExposure: Equatable, Sendable {
    case local
    case lanReachable
    case actionableLAN
}

/// Delimiter-safe identity for a concrete process-owned listener endpoint.
struct ListenerEndpointKey: Hashable, Sendable {
    let pid: Int32
    let bindAddress: String
    let port: UInt16
    let transport: ListenerTransport
}

struct ListenSocket: Identifiable, Hashable, Sendable {
    let pid: Int32
    let processName: String
    let port: UInt16
    let bindAddress: String
    let isTCP: Bool
    let processIdentity: ProcessIdentity?

    init(
        pid: Int32,
        processName: String,
        port: UInt16,
        bindAddress: String,
        isTCP: Bool,
        processIdentity: ProcessIdentity? = nil
    ) {
        self.pid = pid
        self.processName = processName
        self.port = port
        self.bindAddress = Self.normalizeBindAddress(bindAddress)
        self.isTCP = isTCP
        self.processIdentity = processIdentity
    }

    var endpointKey: ListenerEndpointKey {
        ListenerEndpointKey(
            pid: pid,
            bindAddress: bindAddress,
            port: port,
            transport: isTCP ? .tcp : .udp
        )
    }

    var id: ListenerEndpointKey { endpointKey }

    var isLanExposed: Bool {
        !Self.isLoopbackBindAddress(bindAddress)
    }

    /// IANA dynamic/ephemeral port floor. Listeners at or above it are
    /// typically short-lived OS-assigned binds rather than configured services.
    static let ephemeralPortFloor: UInt16 = 49152

    var isEphemeralPort: Bool { port >= Self.ephemeralPortFloor }

    /// Ephemeral wildcard UDP binds (QUIC, browsers, games) are technically
    /// LAN-reachable but churn constantly and aren't actionable listeners —
    /// excluded from alerts, the red LAN count, and top-of-list sorting.
    /// UDP that is discovery or reply traffic rather than a service accepting
    /// connections: ephemeral ports, and Bonjour multicast DNS (5353), which
    /// every Bonjour-capable app binds to find devices.
    var isNoiseUDP: Bool {
        !isTCP && (isEphemeralPort || port == 5_353)
    }

    var exposure: ListenerExposure {
        guard isLanExposed else { return .local }
        return isNoiseUDP ? .lanReachable : .actionableLAN
    }

    /// Canonicalize spelling without collapsing IPv4, IPv6, and
    /// family-unspecified wildcards into the same endpoint.
    static func normalizeBindAddress(_ address: String) -> String {
        var normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count >= 2, normalized.first == "[", normalized.last == "]" {
            normalized.removeFirst()
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !normalized.isEmpty else { return "*" }
        return normalized.lowercased()
    }

    private static func isLoopbackBindAddress(_ address: String) -> Bool {
        if address == "localhost" { return true }

        var ipv4 = in_addr()
        let isIPv4 = address.withCString { pointer in
            inet_pton(AF_INET, pointer, &ipv4)
        } == 1
        if isIPv4 {
            let hostOrder = UInt32(bigEndian: ipv4.s_addr)
            return hostOrder & 0xFF00_0000 == 0x7F00_0000
        }

        var ipv6 = in6_addr()
        let isIPv6 = address.withCString { pointer in
            inet_pton(AF_INET6, pointer, &ipv6)
        } == 1
        guard isIPv6 else {
            // Unknown and wildcard spellings fail toward visibility: only a
            // proven loopback address may be presented as local-only.
            return false
        }

        return withUnsafeBytes(of: &ipv6) { rawBuffer in
            let bytes = Array(rawBuffer)
            let nativeLoopback = bytes.dropLast().allSatisfy { $0 == 0 }
                && bytes.last == 1
            let mappedIPv4Loopback = bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xFF
                && bytes[11] == 0xFF
                && bytes[12] == 127
            return nativeLoopback || mappedIPv4Loopback
        }
    }
}

enum ListenerDiff {
    /// Daemons like rapportd re-bind to a fresh OS-assigned port many times a
    /// day, so an ephemeral-port listener is one exposure fact per process, not
    /// one per port — otherwise every re-bind re-alerts as a "new" listener.
    /// Deliberate tradeoff: the key is name-only, so while a process holds an
    /// ephemeral listener, a same-named newcomer's ephemeral listener is also
    /// suppressed. Accepted — the alternative was per-port spam that gets
    /// notifications disabled entirely; service ports below the ephemeral
    /// floor keep exact per-endpoint identity.
    private struct EphemeralProcessKey: Hashable {
        let processName: String
        let transport: ListenerTransport
    }

    static func exposuresAdded(from previous: [ListenSocket], to current: [ListenSocket]) -> [ListenSocket] {
        let previousExposed = previous.filter { $0.exposure == .actionableLAN }
        var knownEndpoints = Set(previousExposed.map(\.endpointKey))
        var knownEphemeralProcesses = Set(
            previousExposed.filter(\.isEphemeralPort).map(Self.ephemeralKey)
        )

        return current.filter { socket in
            guard socket.exposure == .actionableLAN else { return false }
            let newEndpoint = knownEndpoints.insert(socket.endpointKey).inserted
            guard socket.isEphemeralPort else { return newEndpoint }
            return knownEphemeralProcesses.insert(Self.ephemeralKey(socket)).inserted && newEndpoint
        }
    }

    private static func ephemeralKey(_ socket: ListenSocket) -> EphemeralProcessKey {
        EphemeralProcessKey(
            processName: socket.processName,
            transport: socket.isTCP ? .tcp : .udp
        )
    }
}

struct NetworkState: Equatable, Sendable {
    var vpnActive: Bool
    var vpnInterface: String?
    var vpnIP: String?
    var dnsServers: [String]
    var primaryIP: String?
    /// Aggregate throughput across non-loopback interfaces since the last sample.
    var rxBytesPerSec: Double = 0
    var txBytesPerSec: Double = 0

    static let empty = NetworkState(vpnActive: false, vpnInterface: nil, vpnIP: nil, dnsServers: [], primaryIP: nil)
}

struct VolumeInfo: Identifiable, Hashable, Sendable {
    let name: String
    let totalGB: Double
    let freeGB: Double
    let isExternal: Bool

    var id: String { name }

    var usedGB: Double { max(0, totalGB - freeGB) }
    var usedFraction: Double {
        guard totalGB > 0 else { return 0 }
        return min(1, max(0, usedGB / totalGB))
    }
}

struct DiskSnapshot: Equatable, Sendable {
    var volumes: [VolumeInfo] = []

    static let empty = DiskSnapshot(volumes: [])
}

enum DiskPresentationPolicy {
    static func internalVolume(in snapshot: DiskSnapshot) -> VolumeInfo? {
        snapshot.volumes.first(where: { !$0.isExternal })
    }
}

struct ProcessOverview: Equatable, Sendable {
    var topCPU: [ProcessGroup]
    var topMemory: [ProcessGroup]

    init(topCPU: [ProcessGroup], topMemory: [ProcessGroup]) {
        self.topCPU = topCPU
        self.topMemory = topMemory
    }

    /// Build the executable aggregates once, then derive both rankings from
    /// that immutable set. The panel requests both lists every process sample.
    init(samples: [ProcSample], limit: Int = 5) {
        let groups = Self.groupedByExecutable(samples)
        let cpu = Array(groups.sorted(by: Self.cpuOrder).prefix(max(0, limit)))
        let memory = Array(groups.sorted(by: Self.memoryOrder).prefix(max(0, limit)))
        self.init(
            topCPU: cpu.contains(where: { $0.totalCPU > 0.05 }) ? cpu : [],
            topMemory: memory
        )
    }

    /// Aggregate only processes observed at the exact same executable path.
    /// Restricted processes without a trustworthy path remain visible as
    /// independent, non-actionable rows instead of being merged by basename.
    private static func groupedByExecutable(_ processes: [ProcSample]) -> [ProcessGroup] {
        typealias Aggregate = (
            name: String,
            path: String?,
            pids: [Int32],
            identities: [ProcessIdentity],
            cpu: Double,
            mem: Int
        )
        var grouped: [ProcessGroupID: Aggregate] = [:]
        grouped.reserveCapacity(processes.count)
        for proc in processes {
            let key: ProcessGroupID
            if let path = proc.executablePath, !path.isEmpty {
                key = .executablePath(path)
            } else {
                key = .unresolved(proc.id)
            }
            var entry = grouped[key] ?? (
                name: proc.name,
                path: proc.executablePath,
                pids: [],
                identities: [],
                cpu: 0,
                mem: 0
            )
            entry.pids.append(proc.pid)
            if let identity = proc.identity {
                entry.identities.append(identity)
            }
            entry.cpu += proc.cpuPercent
            entry.mem += proc.residentMB
            grouped[key] = entry
        }
        return grouped.map { key, entry in
            ProcessGroup(
                id: key,
                name: entry.name,
                executablePath: entry.path,
                pids: entry.pids.sorted(),
                expectedIdentities: entry.identities.sorted(by: Self.identityOrder),
                totalCPU: entry.cpu,
                totalMemMB: entry.mem
            )
        }
    }

    private static func identityOrder(_ lhs: ProcessIdentity, _ rhs: ProcessIdentity) -> Bool {
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        if lhs.startTime.seconds != rhs.startTime.seconds {
            return lhs.startTime.seconds < rhs.startTime.seconds
        }
        return lhs.startTime.microseconds < rhs.startTime.microseconds
    }

    private static func cpuOrder(_ lhs: ProcessGroup, _ rhs: ProcessGroup) -> Bool {
        if lhs.totalCPU != rhs.totalCPU { return lhs.totalCPU > rhs.totalCPU }
        return stableGroupOrder(lhs, rhs)
    }

    private static func memoryOrder(_ lhs: ProcessGroup, _ rhs: ProcessGroup) -> Bool {
        if lhs.totalMemMB != rhs.totalMemMB { return lhs.totalMemMB > rhs.totalMemMB }
        return stableGroupOrder(lhs, rhs)
    }

    /// Dictionary iteration changes between snapshots. Stable tie-breaking
    /// keeps equal-usage rows from swapping positions every refresh.
    private static func stableGroupOrder(_ lhs: ProcessGroup, _ rhs: ProcessGroup) -> Bool {
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        switch (lhs.id, rhs.id) {
        case let (.executablePath(left), .executablePath(right)):
            return left < right
        case (.executablePath, .unresolved):
            return true
        case (.unresolved, .executablePath):
            return false
        case let (.unresolved(left), .unresolved(right)):
            if left.pid != right.pid { return left.pid < right.pid }
            if left.startTime.seconds != right.startTime.seconds {
                return left.startTime.seconds < right.startTime.seconds
            }
            return left.startTime.microseconds < right.startTime.microseconds
        }
    }
}

struct PanelSnapshot: Equatable, Sendable {
    var cpu: TelemetryState<Double>
    var memory: TelemetryState<MemorySnapshot>
    var swap: TelemetryState<SwapSnapshot>
    var network: TelemetryState<NetworkState>
    var processes: TelemetryState<ProcessOverview>
    var listenPorts: TelemetryState<[ListenSocket]>
    var disk: TelemetryState<DiskSnapshot>
    var cpuHistory: [Double]
    var memoryHistory: [Double]
    var swapHistory: [Double]
    var latestUpdate: Date
    /// Actionable LAN listeners verified as macOS services (allowlisted name and
    /// a live executable path under a system prefix). Shown, but not flagged.
    var trustedListenerKeys: Set<ListenerEndpointKey>
    /// Executable paths of listening processes, resolved once per ports scan for
    /// display names, icons and the trust check. Never used to signal a process.
    var listenerExecutablePaths: [Int32: String]

    init(
        cpu: TelemetryState<Double> = .loading,
        memory: TelemetryState<MemorySnapshot>,
        swap: TelemetryState<SwapSnapshot>,
        network: TelemetryState<NetworkState>,
        processes: TelemetryState<ProcessOverview> = .loading,
        listenPorts: TelemetryState<[ListenSocket]>,
        disk: TelemetryState<DiskSnapshot>,
        cpuHistory: [Double] = [],
        memoryHistory: [Double] = [],
        swapHistory: [Double] = [],
        latestUpdate: Date = .distantPast,
        trustedListenerKeys: Set<ListenerEndpointKey> = [],
        listenerExecutablePaths: [Int32: String] = [:]
    ) {
        self.cpu = cpu
        self.memory = memory
        self.swap = swap
        self.network = network
        self.processes = processes
        self.listenPorts = listenPorts
        self.disk = disk
        self.cpuHistory = cpuHistory
        self.memoryHistory = memoryHistory
        self.swapHistory = swapHistory
        self.latestUpdate = latestUpdate
        self.trustedListenerKeys = trustedListenerKeys
        self.listenerExecutablePaths = listenerExecutablePaths
    }

    static let loading = PanelSnapshot(
        cpu: .loading,
        memory: .loading,
        swap: .loading,
        network: .loading,
        processes: .loading,
        listenPorts: .loading,
        disk: .loading
    )
}

enum GroupSort: Sendable {
    case cpu, memory
}
