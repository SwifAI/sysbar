import Foundation

enum MonitorWork: Hashable, Sendable {
    case processes
    case ports
    case disk
}

/// A deterministic offset on the monitor's monotonic timeline.
///
/// Scheduling intentionally does not use `Date`: wall-clock adjustments must not
/// make collectors run early, late, or repeatedly.
struct MonitorInstant: Comparable, Hashable, Sendable {
    private let offset: Duration

    static let zero = MonitorInstant(offset: .zero)

    static func seconds(_ value: Int64) -> MonitorInstant {
        MonitorInstant(offset: .seconds(max(0, value)))
    }

    func duration(since earlier: MonitorInstant) -> Duration? {
        guard self >= earlier else { return nil }
        return offset - earlier.offset
    }

    static func < (lhs: MonitorInstant, rhs: MonitorInstant) -> Bool {
        lhs.offset < rhs.offset
    }
}

struct MonitorScheduleState: Sendable {
    private(set) var isPanelOpen: Bool
    private(set) var alertsEnabled: Bool
    /// The attention watch (AI briefs on): while the popover is closed, take one
    /// light process sample per minute and a disk check every five minutes so
    /// the local rules can notice a runaway app. Nothing is published to the UI.
    private(set) var watchEnabled: Bool

    private var lastPortsAt: MonitorInstant?
    private var lastDiskAt: MonitorInstant?
    private var lastWatchProcessesAt: MonitorInstant?
    private var latestInstant: MonitorInstant?
    private var verificationProcessesPending = false
    private var verificationSlowPending = false

    static let watchProcessCadence: Duration = .seconds(60)
    static let watchDiskCadence: Duration = .seconds(300)

    init(isPanelOpen: Bool = false, alertsEnabled: Bool = false, watchEnabled: Bool = false) {
        self.isPanelOpen = isPanelOpen
        self.alertsEnabled = alertsEnabled
        self.watchEnabled = watchEnabled
    }

    @discardableResult
    mutating func panelDidOpen(at instant: MonitorInstant) -> Bool {
        guard accept(instant) else { return false }
        isPanelOpen = true
        return true
    }

    @discardableResult
    mutating func panelDidClose(at instant: MonitorInstant) -> Bool {
        guard accept(instant) else { return false }
        isPanelOpen = false
        return true
    }

    /// A rejected in-flight result never refreshed the cache. Restore only
    /// its own reservations so newer completed collections stay on cadence.
    mutating func invalidate(_ work: Set<MonitorWork>, collectedAt instant: MonitorInstant) {
        if work.contains(.ports), lastPortsAt == instant { lastPortsAt = nil }
        if work.contains(.disk), lastDiskAt == instant { lastDiskAt = nil }
    }

    mutating func setAlertsEnabled(_ enabled: Bool, at instant: MonitorInstant) {
        guard accept(instant) else { return }
        alertsEnabled = enabled
    }

    mutating func setWatchEnabled(_ enabled: Bool) {
        watchEnabled = enabled
    }

    /// After an action, checking its result needs one fresh sample of each
    /// kind regardless of cadence or whether the watch is on.
    mutating func requestVerificationSample(slow: Bool) {
        verificationProcessesPending = true
        if slow { verificationSlowPending = true }
    }

    /// Returns and consumes one closed-popover process sample for the watch.
    /// While the popover is open, processes are sampled every tick anyway.
    mutating func watchProcessesDue(at instant: MonitorInstant) -> Bool {
        guard accept(instant) else { return false }
        guard !isPanelOpen else {
            verificationProcessesPending = false
            return false
        }
        if verificationProcessesPending {
            verificationProcessesPending = false
            lastWatchProcessesAt = instant
            return true
        }
        guard watchEnabled,
              isDue(lastRun: lastWatchProcessesAt, cadence: Self.watchProcessCadence, at: instant) else {
            return false
        }
        lastWatchProcessesAt = instant
        return true
    }

    /// Returns and consumes the work due for one granted collection.
    ///
    /// While the popover is closed, disk inventory runs only for the attention
    /// watch (every five minutes), whose disk rule is its only hidden consumer.
    mutating func workDue(at instant: MonitorInstant) -> Set<MonitorWork> {
        guard accept(instant) else { return [] }

        var work: Set<MonitorWork> = []
        if verificationSlowPending {
            verificationSlowPending = false
            work.formUnion([.ports, .disk])
            lastPortsAt = instant
            lastDiskAt = instant
        }

        if isPanelOpen {
            work.insert(.processes)

            if isDue(lastRun: lastPortsAt, cadence: .seconds(15), at: instant) {
                work.insert(.ports)
                lastPortsAt = instant
            }

            if isDue(lastRun: lastDiskAt, cadence: .seconds(60), at: instant) {
                work.insert(.disk)
                lastDiskAt = instant
            }
        } else {
            if alertsEnabled || watchEnabled,
               isDue(lastRun: lastPortsAt, cadence: .seconds(60), at: instant) {
                work.insert(.ports)
                lastPortsAt = instant
            }
            if watchEnabled,
               isDue(lastRun: lastDiskAt, cadence: Self.watchDiskCadence, at: instant) {
                work.insert(.disk)
                lastDiskAt = instant
            }
        }

        return work
    }

    private mutating func accept(_ instant: MonitorInstant) -> Bool {
        guard latestInstant.map({ instant >= $0 }) ?? true else { return false }
        latestInstant = instant
        return true
    }

    private func isDue(
        lastRun: MonitorInstant?,
        cadence: Duration,
        at instant: MonitorInstant
    ) -> Bool {
        guard let lastRun else { return true }
        guard let elapsed = instant.duration(since: lastRun) else { return false }
        return elapsed >= cadence
    }
}

/// Folds one tick's collector results into one panel publication.
///
/// While the popover is open, every tick starts a summary and a process sample
/// together. Publishing each result as it landed re-rendered the popover twice
/// per tick, so a result that lands while a process sample is running is held
/// and published with it. A result that changes nothing on screen (a repeat
/// port scan) rides along with the next publication instead of making its own.
/// Nothing is held past the next tick, so a stuck sample cannot freeze the panel.
struct PanelPublicationBarrier: Sendable {
    private(set) var isAwaitingProcesses = false
    private(set) var isHoldingResult = false

    /// A process sample for the open panel started.
    mutating func processSampleStarted() {
        isAwaitingProcesses = true
    }

    /// A result was folded into the cached panel. True when it should publish now.
    mutating func resultApplied(changesContent: Bool = true) -> Bool {
        guard changesContent, !isAwaitingProcesses else {
            isHoldingResult = true
            return false
        }
        isHoldingResult = false
        return true
    }

    /// The process sample finished, whether its result was used or discarded.
    /// True when the panel should publish now.
    mutating func processSampleFinished(applied: Bool) -> Bool {
        isAwaitingProcesses = false
        let publish = applied || isHoldingResult
        isHoldingResult = false
        return publish
    }

    /// A new tick began. True when a result has been held behind a process
    /// sample that is still running a whole tick later: publish it now.
    mutating func tickStarted() -> Bool {
        guard isAwaitingProcesses, isHoldingResult else { return false }
        isHoldingResult = false
        return true
    }

    /// The panel published everything it holds (or closed and holds nothing).
    mutating func didPublish() {
        isHoldingResult = false
    }
}

/// Allows one active collection and coalesces all additional demand into one run.
struct CollectionGate: Sendable {
    private(set) var isActive = false
    private(set) var hasPending = false

    mutating func request() -> Bool {
        guard !isActive else {
            hasPending = true
            return false
        }

        isActive = true
        return true
    }

    mutating func finishedAndShouldRepeat() -> Bool {
        guard isActive else { return false }

        if hasPending {
            hasPending = false
            return true
        }

        isActive = false
        return false
    }
}
