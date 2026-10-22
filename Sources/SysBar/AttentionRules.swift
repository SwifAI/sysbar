import Foundation

/// The local "something is wrong" rules. They run on samples SysBar already
/// takes, decide on their own when an item is raised or cleared, and are the
/// only thing that can start an automatic AI brief. Pure and deterministic:
/// every input carries its own timestamp.
enum AttentionRule: String, Codable, CaseIterable, Sendable {
    case runawayProcess
    case hostCPU
    case memory
    case swapGrowth
    case disk
    case newListener
}

struct AttentionKey: Hashable, Codable, Sendable {
    let rule: AttentionRule
    /// Executable path, "host", or a listener endpoint.
    let subject: String
}

/// SysBar's own measurement behind an item. It is always shown first; an AI
/// brief only explains it.
enum AttentionFact: Equatable, Codable, Sendable {
    case runaway(name: String, cpuPercent: Double, minutes: Int)
    case hostCPU(percent: Double, minutes: Int)
    case memory(availableMB: Double, minutes: Int)
    case swapGrowth(grewMB: Double, minutes: Int)
    case diskLow(freeGB: Double)
    case diskFast(droppedGB: Double, minutes: Int)
    case listener(name: String, isTCP: Bool, port: UInt16)
}

struct AttentionItem: Identifiable, Equatable, Codable, Sendable {
    let id: AttentionKey
    let subjectName: String
    /// Executable path for process items, so actions can resolve the live group.
    let executablePath: String?
    var fact: AttentionFact
    let raisedAt: Date
    /// Coarse magnitude: a new brief is worth asking for only when it changes.
    var magnitudeBucket: Int

    var rule: AttentionRule { id.rule }
}

struct AttentionChanges: Equatable, Sendable {
    var raised: [AttentionItem] = []
    var cleared: [AttentionKey] = []

    var isEmpty: Bool { raised.isEmpty && cleared.isEmpty }

    mutating func merge(_ other: AttentionChanges) {
        raised += other.raised
        cleared += other.cleared
    }
}

struct AttentionTracker: Sendable {
    // R1 runaway process
    static let runawayCPUPercent = 100.0
    static let runawayFloorPercent = 50.0
    static let backgroundWindow: TimeInterval = 5 * 60
    static let frontmostWindow: TimeInterval = 20 * 60
    static let clearWindow: TimeInterval = 2 * 60
    /// Closed-popover samples arrive once a minute; anything sparser is a gap.
    static let maximumSampleGap: TimeInterval = 150
    /// How close to the full window the oldest sample must be.
    static let coverageSlack: TimeInterval = 30
    // R2 host CPU
    static let hostCPUMinimumSamples = 50
    static let hostCPUClearPercent = 40.0
    // R3 memory
    static let memoryRaiseAfter: TimeInterval = 2 * 60
    static let memoryClearAfter: TimeInterval = 5 * 60
    // R4 swap growth
    static let swapMinimumUsedMB = 1_024.0
    static let swapGrowthMB = 512.0
    static let swapGrowthWindow: TimeInterval = 10 * 60
    static let swapQuietWindow: TimeInterval = 15 * 60
    static let swapQuietGrowthMB = 128.0
    // R5 disk
    static let diskClearGB = 60.0
    static let diskFastDropGB = 20.0
    static let diskFastWindow: TimeInterval = 30 * 60

    private(set) var active: [AttentionKey: AttentionItem] = [:]

    private var processSeries: [String: [Point]] = [:]
    private var processNames: [String: String] = [:]
    private var memoryLowSince: Date?
    private var memoryHealthySince: Date?
    private var swapSeries: [Point] = []
    private var diskSeries: [Point] = []
    private var previousListenerKeys: Set<ListenerEndpointKey>?

    private struct Point: Sendable {
        let date: Date
        let value: Double
    }

    init() {}

    // MARK: R1 — one app holding more than a core

    mutating func ingestProcesses(
        _ groups: [ProcessGroup],
        frontmostAppPath: String?,
        excludedPaths: Set<String> = [],
        at now: Date
    ) -> AttentionChanges {
        var changes = AttentionChanges()
        var seen = Set<String>()
        for group in groups {
            guard group.name != "kernel_task" else { continue }
            let key = group.executablePath ?? "name:\(group.name)"
            guard !excludedPaths.contains(key) else { continue }
            seen.insert(key)
            processNames[key] = group.name
            append(group.totalCPU, to: key, at: now)
        }
        // A group that left the top list is no longer burning CPU.
        for key in processSeries.keys where !seen.contains(key) {
            append(0, to: key, at: now)
        }

        for (key, series) in processSeries {
            let itemKey = AttentionKey(rule: .runawayProcess, subject: key)
            let name = processNames[key] ?? key
            let isFrontmost = frontmostAppPath.map { key.hasPrefix($0) } ?? false
            let window = isFrontmost ? Self.frontmostWindow : Self.backgroundWindow
            if var item = active[itemKey] {
                let recent = series.filter { now.timeIntervalSince($0.date) <= Self.clearWindow }
                let observedLongEnough = series.first.map { now.timeIntervalSince($0.date) >= Self.clearWindow } ?? false
                if observedLongEnough, Self.mean(recent) < Self.runawayFloorPercent {
                    active[itemKey] = nil
                    changes.cleared.append(itemKey)
                } else {
                    let cpu = Self.mean(series.filter { now.timeIntervalSince($0.date) <= window })
                    item.fact = .runaway(
                        name: name,
                        cpuPercent: cpu,
                        minutes: Self.runMinutes(series, floor: Self.runawayFloorPercent, now: now)
                    )
                    item.magnitudeBucket = Int(cpu / 50)
                    active[itemKey] = item
                }
            } else if Self.isSustained(series, window: window, now: now) {
                let cpu = Self.mean(series.filter { now.timeIntervalSince($0.date) <= window })
                let item = AttentionItem(
                    id: itemKey,
                    subjectName: name,
                    executablePath: key.hasPrefix("name:") ? nil : key,
                    fact: .runaway(
                        name: name,
                        cpuPercent: cpu,
                        minutes: Self.runMinutes(series, floor: Self.runawayFloorPercent, now: now)
                    ),
                    raisedAt: now,
                    magnitudeBucket: Int(cpu / 50)
                )
                active[itemKey] = item
                changes.raised.append(item)
            }
        }

        // Forget series that have been idle for the whole long window.
        processSeries = processSeries.filter { key, series in
            active[AttentionKey(rule: .runawayProcess, subject: key)] != nil
                || series.contains { $0.value >= 1 }
        }
        return changes
    }

    private mutating func append(_ value: Double, to key: String, at now: Date) {
        var series = processSeries[key] ?? []
        series.append(Point(date: now, value: value.isFinite ? max(0, value) : 0))
        series.removeAll { now.timeIntervalSince($0.date) > Self.frontmostWindow + 60 }
        processSeries[key] = series
    }

    /// The window is fully covered by gap-free samples, none below half a core,
    /// and their mean is at least one core.
    private static func isSustained(_ series: [Point], window: TimeInterval, now: Date) -> Bool {
        let inWindow = series.filter { now.timeIntervalSince($0.date) <= window }
        guard inWindow.count >= 3,
              let oldest = inWindow.first,
              now.timeIntervalSince(oldest.date) >= window - coverageSlack else { return false }
        for (earlier, later) in zip(inWindow, inWindow.dropFirst())
        where later.date.timeIntervalSince(earlier.date) > maximumSampleGap {
            return false
        }
        guard inWindow.allSatisfy({ $0.value >= runawayFloorPercent }) else { return false }
        return mean(inWindow) >= runawayCPUPercent
    }

    /// Minutes since the current uninterrupted run at or above `floor` began.
    private static func runMinutes(_ series: [Point], floor: Double, now: Date) -> Int {
        var start = now
        for point in series.reversed() {
            guard point.value >= floor else { break }
            start = point.date
        }
        return max(0, Int((now.timeIntervalSince(start) / 60).rounded()))
    }

    // MARK: R2–R4 — host CPU, memory, swap

    mutating func ingestHost(
        cpuHistory: [Double],
        memory: MemorySnapshot?,
        swap: SwapSnapshot?,
        at now: Date
    ) -> AttentionChanges {
        var changes = AttentionChanges()
        changes.merge(evaluateHostCPU(cpuHistory, at: now))
        if let memory { changes.merge(evaluateMemory(memory, at: now)) }
        if let swap { changes.merge(evaluateSwap(swap, at: now)) }
        return changes
    }

    private mutating func evaluateHostCPU(_ history: [Double], at now: Date) -> AttentionChanges {
        let key = AttentionKey(rule: .hostCPU, subject: "host")
        let values = history.filter(\.isFinite)
        var changes = AttentionChanges()
        if var item = active[key] {
            let recent = Array(values.suffix(40))
            if !recent.isEmpty, recent.reduce(0, +) / Double(recent.count) < Self.hostCPUClearPercent {
                active[key] = nil
                changes.cleared.append(key)
            } else {
                let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
                item.fact = .hostCPU(
                    percent: mean,
                    minutes: max(3, Int((now.timeIntervalSince(item.raisedAt) / 60).rounded()) + 3)
                )
                active[key] = item
            }
        } else if values.count >= Self.hostCPUMinimumSamples {
            let mean = values.reduce(0, +) / Double(values.count)
            if mean >= Thresholds.cpuWarn {
                let item = AttentionItem(
                    id: key,
                    subjectName: "CPU",
                    executablePath: nil,
                    fact: .hostCPU(percent: mean, minutes: 3),
                    raisedAt: now,
                    magnitudeBucket: Int(mean / 10)
                )
                active[key] = item
                changes.raised.append(item)
            }
        }
        return changes
    }

    private mutating func evaluateMemory(_ memory: MemorySnapshot, at now: Date) -> AttentionChanges {
        let key = AttentionKey(rule: .memory, subject: "host")
        let totalMB = memory.totalGB * 1_024
        guard totalMB > 0 else { return AttentionChanges() }
        let availableMB = Double(max(0, memory.freeMB))
        let isLow = availableMB <= max(2_048, totalMB * 0.15)
        let isHealthy = availableMB >= totalMB * 0.20
        memoryLowSince = isLow ? (memoryLowSince ?? now) : nil
        memoryHealthySince = isHealthy ? (memoryHealthySince ?? now) : nil

        var changes = AttentionChanges()
        if var item = active[key] {
            if let healthySince = memoryHealthySince, now.timeIntervalSince(healthySince) >= Self.memoryClearAfter {
                active[key] = nil
                changes.cleared.append(key)
            } else {
                item.fact = .memory(
                    availableMB: availableMB,
                    minutes: Int((now.timeIntervalSince(memoryLowSince ?? item.raisedAt) / 60).rounded())
                )
                item.magnitudeBucket = Int(availableMB / totalMB * 10)
                active[key] = item
            }
        } else if let lowSince = memoryLowSince, now.timeIntervalSince(lowSince) >= Self.memoryRaiseAfter {
            let item = AttentionItem(
                id: key,
                subjectName: "Memory",
                executablePath: nil,
                fact: .memory(availableMB: availableMB, minutes: Int((now.timeIntervalSince(lowSince) / 60).rounded())),
                raisedAt: now,
                magnitudeBucket: Int(availableMB / totalMB * 10)
            )
            active[key] = item
            changes.raised.append(item)
        }
        return changes
    }

    private mutating func evaluateSwap(_ swap: SwapSnapshot, at now: Date) -> AttentionChanges {
        let key = AttentionKey(rule: .swapGrowth, subject: "host")
        let used = Double(max(0, swap.usedMB))
        swapSeries.append(Point(date: now, value: used))
        swapSeries.removeAll { now.timeIntervalSince($0.date) > Self.swapQuietWindow + 60 }

        var changes = AttentionChanges()
        let growthWindow = swapSeries.filter { now.timeIntervalSince($0.date) <= Self.swapGrowthWindow }
        let grew = used - (growthWindow.map(\.value).min() ?? used)
        if active[key] != nil {
            let quiet = swapSeries.filter { now.timeIntervalSince($0.date) <= Self.swapQuietWindow }
            let observedQuietWindow = swapSeries.first.map {
                now.timeIntervalSince($0.date) >= Self.swapQuietWindow
            } ?? false
            let recentGrowth = used - (quiet.map(\.value).min() ?? used)
            if observedQuietWindow, recentGrowth < Self.swapQuietGrowthMB {
                active[key] = nil
                changes.cleared.append(key)
            }
        } else if used >= Self.swapMinimumUsedMB, grew >= Self.swapGrowthMB {
            let item = AttentionItem(
                id: key,
                subjectName: "Swap",
                executablePath: nil,
                fact: .swapGrowth(grewMB: grew, minutes: 10),
                raisedAt: now,
                magnitudeBucket: Int(used / 1_024)
            )
            active[key] = item
            changes.raised.append(item)
        }
        return changes
    }

    // MARK: R5 — disk

    mutating func ingestDisk(freeGB: Double, totalGB: Double, at now: Date) -> AttentionChanges {
        let key = AttentionKey(rule: .disk, subject: "internal")
        guard freeGB.isFinite, totalGB > 0 else { return AttentionChanges() }
        diskSeries.append(Point(date: now, value: freeGB))
        diskSeries.removeAll { now.timeIntervalSince($0.date) > Self.diskFastWindow }
        let dropped = (diskSeries.map(\.value).max() ?? freeGB) - freeGB
        let minutes = diskSeries.first.map { Int((now.timeIntervalSince($0.date) / 60).rounded()) } ?? 0

        var changes = AttentionChanges()
        let isLow = freeGB <= Thresholds.diskLowGB
        let isFast = dropped >= Self.diskFastDropGB
        if var item = active[key] {
            if freeGB >= Self.diskClearGB, !isFast {
                active[key] = nil
                changes.cleared.append(key)
            } else {
                item.fact = isLow ? .diskLow(freeGB: freeGB) : .diskFast(droppedGB: dropped, minutes: minutes)
                item.magnitudeBucket = Int(freeGB / 10)
                active[key] = item
            }
        } else if isLow || isFast {
            let item = AttentionItem(
                id: key,
                subjectName: "Disk",
                executablePath: nil,
                fact: isLow ? .diskLow(freeGB: freeGB) : .diskFast(droppedGB: dropped, minutes: minutes),
                raisedAt: now,
                magnitudeBucket: Int(freeGB / 10)
            )
            active[key] = item
            changes.raised.append(item)
        }
        return changes
    }

    // MARK: R6 — a new non-Apple app accepting connections from the network

    mutating func ingestListeners(
        _ ports: [ListenSocket],
        trusted: Set<ListenerEndpointKey>,
        displayNames: [Int32: String] = [:],
        at now: Date
    ) -> AttentionChanges {
        let reviewable = ports.filter { $0.exposure == .actionableLAN && !trusted.contains($0.endpointKey) }
        let currentKeys = Set(reviewable.map(\.endpointKey))
        var changes = AttentionChanges()

        for (key, item) in active where key.rule == .newListener {
            let stillListening = reviewable.contains { Self.subject(for: $0) == item.id.subject }
            if !stillListening {
                active[key] = nil
                changes.cleared.append(key)
            }
        }

        // The first scan is a baseline: only listeners that appear later raise.
        if let previous = previousListenerKeys {
            for port in reviewable where !previous.contains(port.endpointKey) {
                let key = AttentionKey(rule: .newListener, subject: Self.subject(for: port))
                guard active[key] == nil else { continue }
                let name = displayNames[port.pid] ?? port.processName
                let item = AttentionItem(
                    id: key,
                    subjectName: name,
                    executablePath: nil,
                    fact: .listener(name: name, isTCP: port.isTCP, port: port.port),
                    raisedAt: now,
                    magnitudeBucket: 0
                )
                active[key] = item
                changes.raised.append(item)
            }
        }
        previousListenerKeys = currentKeys
        return changes
    }

    /// After a verified fix: drop the item and its history so a genuine
    /// recurrence has to build up from scratch and raises cleanly.
    mutating func forget(_ key: AttentionKey) {
        active[key] = nil
        switch key.rule {
        case .runawayProcess: processSeries[key.subject] = nil
        case .hostCPU: break
        case .memory:
            memoryLowSince = nil
            memoryHealthySince = nil
        case .swapGrowth: swapSeries = []
        case .disk: diskSeries = []
        case .newListener: break
        }
    }

    static func subject(for port: ListenSocket) -> String {
        "listener:\(port.isTCP ? "tcp" : "udp"):\(port.port):\(port.processName)"
    }

    private static func mean(_ points: [Point]) -> Double {
        guard !points.isEmpty else { return 0 }
        return points.reduce(0) { $0 + $1.value } / Double(points.count)
    }
}

extension AttentionFact {
    /// The measured fact as one line: always SysBar's numbers, never AI text.
    var text: String {
        switch self {
        case let .runaway(name, cpu, minutes):
            return AppResources.formatted(
                "attention.rule.runaway",
                fallback: "%1$@ has used %2$@ CPU for %3$@",
                name,
                MetricFormat.percent(cpu.rounded()),
                AttentionFormat.duration(minutes: minutes)
            )
        case let .hostCPU(percent, minutes):
            return AppResources.formatted(
                "attention.rule.hostCPU",
                fallback: "CPU has averaged %1$@ for %2$@",
                MetricFormat.percent(percent.rounded()),
                AttentionFormat.duration(minutes: minutes)
            )
        case let .memory(availableMB, minutes):
            return AppResources.formatted(
                "attention.rule.memory",
                fallback: "Only %1$@ of memory available for %2$@",
                MetricFormat.memory(megabytes: Int(availableMB)),
                AttentionFormat.duration(minutes: max(1, minutes))
            )
        case let .swapGrowth(grewMB, minutes):
            return AppResources.formatted(
                "attention.rule.swap",
                fallback: "Swap grew by %1$@ in the last %2$@",
                MetricFormat.memory(megabytes: Int(grewMB)),
                AttentionFormat.duration(minutes: minutes)
            )
        case let .diskLow(freeGB):
            return AppResources.formatted(
                "attention.rule.disk",
                fallback: "Only %@ of disk space left",
                AttentionFormat.gigabytes(freeGB)
            )
        case let .diskFast(droppedGB, minutes):
            return AppResources.formatted(
                "attention.rule.diskFast",
                fallback: "%1$@ of disk space used up in %2$@",
                AttentionFormat.gigabytes(droppedGB),
                AttentionFormat.duration(minutes: max(1, minutes))
            )
        case let .listener(name, isTCP, port):
            return AppResources.formatted(
                "attention.rule.listener",
                fallback: "%1$@ started accepting %2$@ connections on port %3$@",
                name,
                AppResources.localized(isTCP ? "TCP" : "UDP"),
                String(port)
            )
        }
    }
}

enum AttentionFormat {
    static func duration(minutes: Int) -> String {
        Duration.seconds(max(1, minutes) * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func gigabytes(_ value: Double) -> String {
        AppResources.formatted(
            "metric.value.unit",
            fallback: "%@ %@",
            MetricFormat.decimal(max(0, value), maximumFractionDigits: value < 10 ? 1 : 0),
            AppResources.localized("GB")
        )
    }
}
