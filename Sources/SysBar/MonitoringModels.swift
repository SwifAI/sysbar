import Foundation
import Combine

enum TelemetryError: Error, Equatable, Sendable {
    case collector(String)
    case timedOut(String)
    case permission(String)

    var message: String {
        switch self {
        case let .collector(message), let .timedOut(message), let .permission(message):
            return message
        }
    }
}

enum TelemetryState<Value> {
    case loading
    case available(Value, sampledAt: Date)
    case stale(Value, sampledAt: Date, error: TelemetryError)
    case unavailable(TelemetryError)

    var value: Value? {
        switch self {
        case let .available(value, _), let .stale(value, _, _):
            return value
        case .loading, .unavailable:
            return nil
        }
    }

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }

    var isStale: Bool {
        if case .stale = self {
            return true
        }
        return false
    }

    var isUnavailable: Bool {
        if case .unavailable = self {
            return true
        }
        return false
    }

    var sampledAt: Date? {
        switch self {
        case let .available(_, sampledAt), let .stale(_, sampledAt, _):
            return sampledAt
        case .loading, .unavailable:
            return nil
        }
    }

    func recordingFailure(_ error: TelemetryError) -> Self {
        switch self {
        case let .available(value, sampledAt), let .stale(value, sampledAt, _):
            return .stale(value, sampledAt: sampledAt, error: error)
        case .loading, .unavailable:
            return .unavailable(error)
        }
    }
}

extension TelemetryState {
    /// A named convenience for a successful, current sample. The timestamp is
    /// intentionally captured at the boundary so callers do not accidentally
    /// model an empty result as healthy telemetry.
    static func current(_ value: Value, sampledAt: Date = Date()) -> Self {
        .available(value, sampledAt: sampledAt)
    }
}

enum PanelHealthPresentation: Equatable, Sendable {
    case unavailable
    case stale
    case loading
    case current

    static func resolve(hasUnavailable: Bool, hasStale: Bool, hasLoading: Bool) -> Self {
        if hasUnavailable { return .unavailable }
        if hasStale { return .stale }
        if hasLoading { return .loading }
        return .current
    }

    var title: String {
        switch self {
        case .unavailable: return "Some data unavailable"
        case .stale: return "Update delayed"
        case .loading: return "Updating"
        case .current: return "Data current"
        }
    }

    var symbolName: String {
        switch self {
        case .unavailable: return "exclamationmark.octagon.fill"
        case .stale: return "clock.badge.exclamationmark.fill"
        case .loading: return "arrow.triangle.2.circlepath"
        case .current: return "checkmark.circle.fill"
        }
    }

    var severity: MetricSeverity {
        switch self {
        case .unavailable: return .critical
        case .stale, .loading: return .warning
        case .current: return .normal
        }
    }

    static func snapshot(_ snapshot: PanelSnapshot) -> Self {
        let unavailable = snapshot.cpu.isUnavailable
            || snapshot.memory.isUnavailable
            || snapshot.swap.isUnavailable
            || snapshot.network.isUnavailable
            || snapshot.processes.isUnavailable
            || snapshot.listenPorts.isUnavailable
            || snapshot.disk.isUnavailable
        let stale = snapshot.cpu.isStale
            || snapshot.memory.isStale
            || snapshot.swap.isStale
            || snapshot.network.isStale
            || snapshot.processes.isStale
            || snapshot.listenPorts.isStale
            || snapshot.disk.isStale
        let loading = snapshot.cpu.isLoading
            || snapshot.memory.isLoading
            || snapshot.swap.isLoading
            || snapshot.network.isLoading
            || snapshot.processes.isLoading
            || snapshot.listenPorts.isLoading
            || snapshot.disk.isLoading
        return resolve(hasUnavailable: unavailable, hasStale: stale, hasLoading: loading)
    }
}

/// The Network section's plain answer to "is anything risky open, and what
/// do I do?": listeners other devices can reach that are neither verified
/// macOS services nor allowed by the user. Everything else is normal.
struct ExposureVerdict: Equatable, Sendable {
    let needsLook: [ListenSocket]
    let normalCount: Int

    var isClear: Bool { needsLook.isEmpty }

    init(_ ports: [ListenSocket], trusted: Set<ListenerEndpointKey>, allowedSubjects: Set<String>) {
        needsLook = ports.filter {
            $0.exposure == .actionableLAN
                && !trusted.contains($0.endpointKey)
                && !allowedSubjects.contains(AttentionTracker.subject(for: $0))
        }
        normalCount = ports.count - needsLook.count
    }

    /// `names`: display names by PID (the owning app's name, not lsof's).
    func title(names: [Int32: String]) -> String {
        guard !isClear else {
            return AppResources.localized("ports.verdict.clear.title", fallback: "Nothing risky is open")
        }
        var seen = Set<String>()
        let apps = needsLook.map { names[$0.pid] ?? $0.processName }.filter { seen.insert($0).inserted }
        return AppResources.formatted(
            "ports.verdict.review.title",
            fallback: "Other devices can connect to %@",
            apps.formatted(.list(type: .and))
        )
    }

    var detail: String {
        if isClear {
            return AppResources.formatted(
                "ports.verdict.clear.detail",
                fallback: "%@ ports belong to macOS or only this Mac can reach them. Nothing to do.",
                normalCount.formatted()
            )
        }
        return AppResources.localized(
            "ports.verdict.review.detail",
            fallback: "Fine if you use it. If you don't recognize it, quit it. Allow stops this warning."
        )
    }
}

/// Every section of the popover's scroll view. `panelOrder` is the single
/// source of their top-to-bottom order; `MenuContentView` renders
/// the sections by iterating it. Raw values are not persisted (expansion state
/// is keyed by `SectionKey`).
enum MenuSection: String, CaseIterable, Hashable, Sendable {
    case security
    case metrics
    case cpu
    case memory
    case ports
    case systemServices

    static let panelOrder: [Self] = [.security, .metrics, .cpu, .memory, .ports, .systemServices]
}

enum ProcessActionPolicy {
    static func requiresConfirmation(signal: ProcessSignal, processCount: Int) -> Bool {
        signal == .forceKill || processCount > 1
    }

    static func confirmationMessage(
        name: String,
        signal: ProcessSignal,
        identities: [ProcessIdentity]
    ) -> String {
        let pids = identities.map { String($0.pid) }.joined(separator: ", ")
        let verb = AppResources.localized(signal == .forceKill ? "Force quit" : "Quit")
        let processCount = AppResources.plural("processes.count", count: identities.count)
        return AppResources.formatted(
            "process.confirmation",
            fallback: "%@ %@ (%@)? PIDs: %@.",
            verb,
            name,
            processCount,
            pids
        )
    }
}

struct ProcessActionFeedback: Identifiable, Equatable, Sendable {
    let title: String
    let message: String
    let failedPIDs: [Int32]

    var id: String { "\(title):\(failedPIDs.map(String.init).joined(separator: ",")):\(message)" }

    static func make(from report: ProcessActionReport) -> Self {
        let succeeded = report.results.filter { $0.outcome == .signaled }
        let failed = report.results.filter {
            if case .notSignaled = $0.outcome { return true }
            return false
        }
        let failedPIDs = failed.map { $0.identity.pid }

        if failed.isEmpty {
            return ProcessActionFeedback(
                title: AppResources.localized("Action completed"),
                message: AppResources.plural(
                    "processes.signaled.count",
                    count: succeeded.count
                ),
                failedPIDs: []
            )
        }

        let changed = failed.contains {
            if case .notSignaled(.staleIdentity) = $0.outcome { return true }
            return false
        }
        let pidText = failedPIDs.map(String.init).joined(separator: ", ")
        return ProcessActionFeedback(
            title: AppResources.localized(
                succeeded.isEmpty ? "No signal sent" : "Action partially completed"
            ),
            message: changed
                ? AppResources.formatted(
                    "process.changed.failed.pids",
                    fallback: "A process changed; no signal was sent to it. Failed PIDs: %@.",
                    pidText
                )
                : AppResources.formatted(
                    "process.failed.pids",
                    fallback: "Failed PIDs: %@.",
                    pidText
                ),
            failedPIDs: failedPIDs
        )
    }
}

extension TelemetryState: Equatable where Value: Equatable {
    /// Equal apart from when a current sample was taken, so what the panel
    /// shows for it is unchanged.
    func hasSameContent(as other: Self) -> Bool {
        if case let .available(lhs, _) = self, case let .available(rhs, _) = other {
            return lhs == rhs
        }
        return self == other
    }
}
extension TelemetryState: Sendable where Value: Sendable {}

enum MetricFormat {
    static func memory(megabytes: Int) -> String {
        guard megabytes >= 1_024 else {
            return valueWithUnit(
                decimal(Double(max(0, megabytes)), maximumFractionDigits: 0),
                unit: "MB"
            )
        }
        return valueWithUnit(
            decimal(Double(megabytes) / 1_024, maximumFractionDigits: 1),
            unit: "GB"
        )
    }

    static func rate(bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value >= 1_048_576 {
            return valueWithUnit(
                decimal(value / 1_048_576, maximumFractionDigits: 1),
                unit: "MB/s"
            )
        }
        return valueWithUnit(
            decimal(value / 1_024, maximumFractionDigits: 0),
            unit: "KB/s"
        )
    }

    static func percent(_ value: Double) -> String {
        AppResources.formatted(
            "metric.percent.value",
            fallback: "%@%%",
            decimal(max(0, value), maximumFractionDigits: 1)
        )
    }

    private static func valueWithUnit(_ value: String, unit: String) -> String {
        AppResources.formatted(
            "metric.value.unit",
            fallback: "%@ %@",
            value,
            AppResources.localized(unit)
        )
    }

    static func decimal(
        _ value: Double,
        maximumFractionDigits: Int,
        locale: Locale = .current
    ) -> String {
        // Foundation caches the backing formatter for equivalent value-style
        // configurations. Live rows can share it without mutable global state.
        let style = FloatingPointFormatStyle<Double>.number
            .grouping(.never)
            .precision(.fractionLength(0...maximumFractionDigits))
            .locale(locale)
        return (value.isFinite ? value : 0).formatted(style)
    }
}

enum PortDisplayText {
    static func host(_ bindAddress: String) -> String {
        guard bindAddress.contains(":"), !bindAddress.hasPrefix("[") else { return bindAddress }
        return "[\(bindAddress)]"
    }

    static func address(bindAddress: String, port: UInt16) -> String {
        "\(host(bindAddress)):\(port)"
    }

    static func endpoint(transport: String, bindAddress: String, port: UInt16) -> String {
        AppResources.formatted(
            "port.endpoint.detail",
            fallback: "%@ · %@:%@",
            transport,
            host(bindAddress),
            String(port)
        )
    }

    static func actionLabel(port: UInt16) -> String {
        AppResources.formatted(
            "actions.port",
            fallback: "Actions for port %@",
            String(port)
        )
    }

    static func help(
        processName: String,
        pid: Int32,
        bindAddress: String,
        port: UInt16
    ) -> String {
        AppResources.formatted(
            "port.help",
            fallback: "%@, process %@, listening on %@:%@",
            processName,
            String(pid),
            host(bindAddress),
            String(port)
        )
    }

    static func accessibilityLabel(port: UInt16, processName: String) -> String {
        AppResources.formatted(
            "port.accessibility.label",
            fallback: "Port %@, %@",
            String(port),
            processName
        )
    }

    static func listenerAlertBody(
        processName: String,
        bindAddress: String,
        port: UInt16
    ) -> String {
        AppResources.formatted(
            "alert.listener.body",
            fallback: "%@ is listening on %@:%@",
            processName,
            host(bindAddress),
            String(port)
        )
    }
}

struct HistoryBuffer<Element> {
    let capacity: Int
    private(set) var values: [Element] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ value: Element) {
        if values.count == capacity {
            values.removeFirst()
        }
        values.append(value)
    }
}

extension HistoryBuffer: Equatable where Element: Equatable {}
extension HistoryBuffer: Sendable where Element: Sendable {}

/// The only value observed by the always-visible menu-bar label. Its title is
/// fixed-width so telemetry changes never make neighbouring status items move.
struct StatusSummary: Equatable, Sendable {
    let title: String
    let accessibilityValue: String
    /// Last minute of CPU, quantized for the menu-bar sparkline glyph.
    let cpuLevels: [UInt8]
    /// CPU or memory telemetry is stale, so the glyph is drawn dashed.
    let isDelayed: Bool
    /// Something needs attention: the glyph gains a small dot.
    let hasAttention: Bool

    init(
        title: String,
        accessibilityValue: String,
        cpuLevels: [UInt8] = [],
        isDelayed: Bool = false,
        hasAttention: Bool = false
    ) {
        self.title = title
        self.accessibilityValue = accessibilityValue
        self.cpuLevels = cpuLevels
        self.isDelayed = isDelayed
        self.hasAttention = hasAttention
    }

    func withAttention(_ flag: Bool) -> StatusSummary {
        StatusSummary(
            title: title,
            accessibilityValue: accessibilityValue,
            cpuLevels: cpuLevels,
            isDelayed: isDelayed,
            hasAttention: flag
        )
    }

    static let loading = StatusSummary(
        title: " --%   --G",
        accessibilityValue: AppResources.localized(
            "status.loading.accessibility",
            fallback: "System activity is loading"
        )
    )

    static func make(
        cpuPercent: Double,
        memory: MemorySnapshot,
        cpuHistory: [Double] = [],
        isDelayed: Bool = false,
        hasAttention: Bool = false
    ) -> StatusSummary {
        let clampedCPU = min(999, max(0, cpuPercent))
        let availableGB = max(0, Double(memory.freeMB) / 1_024)
        // "%4.1f" grows to five characters once the value rounds to 100, so
        // drop the fraction there to keep the four-character field on
        // high-RAM machines.
        let availableField = String(
            format: availableGB >= 99.95 ? "%4.0f" : "%4.1f",
            locale: .current,
            availableGB
        )
        return StatusSummary(
            title: String(
                format: "%3.0f%% %@G",
                locale: .current,
                clampedCPU,
                availableField
            ),
            accessibilityValue: AppResources.formatted(
                "status.summary.accessibility",
                fallback: "CPU %.0f percent, %.1f gigabytes memory available",
                clampedCPU,
                availableGB
            ),
            cpuLevels: StatusGlyphModel.levels(from: cpuHistory),
            isDelayed: isDelayed,
            hasAttention: hasAttention
        )
    }
}

@MainActor
final class StatusSummaryModel: ObservableObject {
    @Published private(set) var summary: StatusSummary

    init(summary: StatusSummary = .loading) {
        self.summary = summary
    }

    func publish(_ newValue: StatusSummary) {
        guard newValue != summary else { return }
        summary = newValue
    }
}

@MainActor
final class PanelDetailModel: ObservableObject {
    @Published private(set) var snapshot: PanelSnapshot

    init(snapshot: PanelSnapshot = .loading) {
        self.snapshot = snapshot
    }

    func publish(_ newValue: PanelSnapshot) {
        snapshot = newValue
    }
}

/// One coherent always-on collection. Individual failures remain explicit so
/// a single unavailable subsystem cannot erase the other successful values.
struct SummarySample: Sendable {
    let cpu: Result<Double, TelemetryError>
    let memory: Result<MemorySnapshot, TelemetryError>
    let swap: Result<SwapSnapshot, TelemetryError>
    let network: Result<NetworkState, TelemetryError>
    let sampledAt: Date
}
