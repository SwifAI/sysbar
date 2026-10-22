import AppKit
import Combine
import Foundation
import IOKit
import IOKit.pwr_mgt

#if DEBUG
import os

private let monitorSignposter = OSSignposter(
    subsystem: "com.sysbar.monitoring",
    category: "Pipeline"
)
#endif

let monitorHistoryCapacity = 60
let monitorRefreshSeconds: TimeInterval = 3
private let alertCooldownSeconds: TimeInterval = 60

typealias SummaryCollector = @Sendable () async -> SummarySample
typealias ProcessCollector = @Sendable () async -> Result<[ProcSample], TelemetryError>
typealias PortsCollector = @Sendable () async -> Result<[ListenSocket], TelemetryError>
typealias DiskCollector = @Sendable () async -> Result<DiskSnapshot, TelemetryError>

/// Keep Awake's IOKit power-assertion boundary (ADR-016). Mirrors
/// `IOPMAssertionCreateWithName`/`IOPMAssertionRelease` one-to-one, including
/// the out-parameter, so every ownership decision stays in `SystemMonitor`
/// where tests can reach it.
protocol PowerAssertionControlling: Sendable {
    func create(
        type: String,
        level: IOPMAssertionLevel,
        name: String,
        assertionID: inout IOPMAssertionID
    ) -> IOReturn
    func release(_ assertionID: IOPMAssertionID)
}

struct DarwinPowerAssertionController: PowerAssertionControlling {
    func create(
        type: String,
        level: IOPMAssertionLevel,
        name: String,
        assertionID: inout IOPMAssertionID
    ) -> IOReturn {
        IOPMAssertionCreateWithName(type as CFString, level, name as CFString, &assertionID)
    }

    func release(_ assertionID: IOPMAssertionID) {
        IOPMAssertionRelease(assertionID)
    }
}

struct MonitorAlert: Equatable, Sendable {
    let title: String
    let body: String
}

/// Coordinates independent status, process, and slow collectors. Only
/// `statusModel` is observed by the always-visible status item; panel state is
/// published through `panelModel` exclusively while the panel is open.
@MainActor
final class SystemMonitor: @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let statusModel: StatusSummaryModel
    let panelModel: PanelDetailModel
    let appServices: AppServicesModel
    /// The attention watch and AI briefs. Fed by every collection below.
    let attention: AttentionModel

    private let summaryCollector: SummaryCollector
    private let processCollector: ProcessCollector
    private let portsCollector: PortsCollector
    private let diskCollector: DiskCollector
    private let alertIdentityReader: any ProcessIdentityReading
    private let powerAssertions: any PowerAssertionControlling
    private let processActionService = ProcessActionService()

    private var timer: Timer?
    private var schedule: MonitorScheduleState
    private var summaryGate = CollectionGate()
    private var processGate = CollectionGate()
    private var watchGate = CollectionGate()
    private var slowGate = CollectionGate()
    private var panelPublication = PanelPublicationBarrier()
    /// Latest process overview from either the open popover or the watch,
    /// kept for AI evidence. Never published while the popover is closed.
    private var latestOverview: ProcessOverview?
    private var lastStatusSummary: StatusSummary?
    private var pendingProcessContext: CollectionContext?
    private var pendingSlowContext: CollectionContext?
    private var serviceRefreshTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var slowTask: Task<Void, Never>?
    private var isShutdown = false
    private var panelSession: UInt64 = 0
    private var cachedPanel = PanelSnapshot.loading

    private(set) var caffeinated = false
    private(set) var emittedAlerts: [MonitorAlert] = []

    var alertsEnabled: Bool { appServices.notificationState.desired }

    private var caffeinateAssertion: IOPMAssertionID = 0
    private var lastSuccessfulPorts: [ListenSocket]?
    private var lastVPNState: Bool?
    private var alertLastFired: [String: Date] = [:]
    private var memAlertArmed = true

    private struct CollectionContext: Sendable {
        let instant: MonitorInstant
        let sampledAt: Date
        let panelSession: UInt64
    }

    nonisolated static let portAlertAllowlist: Set<String> = [
        "rapportd", "ControlCe", "ControlCenter", "remotepairingd", "remoted",
        "sharingd", "homed", "WeatherWidget", "replicatord", "cfnetwork",
        "nsurlsessiond", "identityservicesd", "apsd", "mDNSResponder",
        "searchpartyd", "akd", "nearbyd", "locationd", "netbiosd",
        "screensharingd", "CoreLocationAgent"
    ]

    /// Production listener collection (ADR-019). Deliberately the zero-identity
    /// `PortsAPI.fetchResult()` overload, so listener rows are never actionable.
    /// Named so a regression test can pin exactly what `init` installs.
    nonisolated static let defaultPortsCollector: PortsCollector = {
        await Task.detached(priority: .utility) { PortsAPI.fetchResult() }.value
    }

    init(
        autoStart: Bool = true,
        initialAlertsEnabled: Bool? = nil,
        appServices injectedAppServices: AppServicesModel? = nil,
        summaryCollector injectedSummaryCollector: SummaryCollector? = nil,
        processCollector injectedProcessCollector: ProcessCollector? = nil,
        portsCollector injectedPortsCollector: PortsCollector? = nil,
        diskCollector injectedDiskCollector: DiskCollector? = nil,
        alertIdentityReader injectedAlertIdentityReader: (any ProcessIdentityReading)? = nil,
        powerAssertions injectedPowerAssertions: (any PowerAssertionControlling)? = nil,
        attention injectedAttention: AttentionModel? = nil
    ) {
        let cpuSampler = CPUSampler()
        let processSampler = ProcessSampler()
        let networkSampler = NetworkSampler()

        self.summaryCollector = injectedSummaryCollector ?? {
            async let cpu = cpuSampler.sampleResult()
            async let network = networkSampler.sampleResult()
            async let other: (
                Result<MemorySnapshot, TelemetryError>,
                Result<SwapSnapshot, TelemetryError>
            ) = Task.detached(priority: .utility) {
                (MemoryAPI.fetchResult(), SwapAPI.fetchResult())
            }.value
            return await SummarySample(
                cpu: cpu,
                memory: other.0,
                swap: other.1,
                network: network,
                sampledAt: Date()
            )
        }
        self.processCollector = injectedProcessCollector ?? {
            await processSampler.sampleProcessesResult()
        }
        self.portsCollector = injectedPortsCollector ?? Self.defaultPortsCollector
        self.diskCollector = injectedDiskCollector ?? {
            await Task.detached(priority: .utility) { DiskAPI.fetchResult() }.value
        }
        self.alertIdentityReader = injectedAlertIdentityReader ?? DarwinProcessIdentityReader()
        self.powerAssertions = injectedPowerAssertions ?? DarwinPowerAssertionController()

        let services = injectedAppServices
            ?? initialAlertsEnabled.map(AppServicesModel.transient(alertsDesired:))
            ?? AppServicesModel.live()
        self.appServices = services
        let attention = injectedAttention ?? AttentionModel(
            defaults: autoStart ? .standard : UserDefaults(suiteName: "SysBar.transient.\(UUID().uuidString)") ?? .standard
        )
        self.attention = attention
        self.schedule = MonitorScheduleState(
            alertsEnabled: services.notificationState.deliveryActive,
            watchEnabled: attention.watchEnabled
        )
        self.statusModel = StatusSummaryModel()
        self.panelModel = PanelDetailModel()

        // No relay from either model: the popover's telemetry sections observe
        // `panelModel` themselves, so a panel publication re-renders only them.
        attention.evidenceInputs = { [weak self] in self?.briefInputs() }
        attention.notify = { [weak self] note in self?.emitAttention(note) }
        attention.resample = { [weak self] slow in self?.resampleForVerification(slow: slow) }
        attention.signalProcesses = { [weak self] signal, identities in
            guard let self else { return ProcessActionReport(signal: signal, results: []) }
            return await self.performProcessAction(signal, identities: identities)
        }
        attention.isPanelOpen = { [weak self] in self?.schedule.isPanelOpen ?? false }
        attention.onWatchChange = { [weak self] enabled in self?.schedule.setWatchEnabled(enabled) }
        attention.onAttentionChange = { [weak self] hasAttention in
            guard let self, let summary = self.lastStatusSummary else { return }
            self.publishStatus(summary.withAttention(hasAttention))
        }

        if autoStart {
            Task { [weak self] in await self?.refreshAppServices() }
            startTimer()
            tick(at: Self.currentInstant())
        }
    }

    /// Explicit lifecycle boundary for AppKit ownership. `Timer` is main-actor
    /// state and therefore must not be touched from nonisolated `deinit`.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        summaryTask?.cancel()
        processTask?.cancel()
        slowTask?.cancel()
        serviceRefreshTask?.cancel()
        summaryTask = nil
        processTask = nil
        slowTask = nil
        serviceRefreshTask = nil
        pendingProcessContext = nil
        pendingSlowContext = nil
        timer?.invalidate()
        timer = nil
        if caffeinateAssertion != 0 {
            powerAssertions.release(caffeinateAssertion)
            caffeinateAssertion = 0
        }
        caffeinated = false
    }

    // MARK: UI entry points

    func refresh() {
        tick(at: Self.currentInstant())
    }

    func setPanelVisible(_ visible: Bool) {
        if visible {
            panelDidOpen(at: Self.currentInstant())
        } else {
            panelDidClose(at: Self.currentInstant())
        }
    }

    // MARK: Deterministic coordinator entry points

    func tick(at instant: MonitorInstant, sampledAt: Date = Date()) {
        guard !isShutdown else { return }
        let context = CollectionContext(
            instant: instant,
            sampledAt: sampledAt,
            panelSession: panelSession
        )
        if schedule.isPanelOpen, panelPublication.tickStarted() {
            publishPanel(cachedPanel)
        }
        requestSummary()
        requestProcesses(context)
        requestWatchProcesses(context)
        requestSlowWork(context)
    }

    func panelDidOpen(at instant: MonitorInstant, sampledAt: Date = Date()) {
        guard !isShutdown else { return }
        guard !schedule.isPanelOpen else {
            tick(at: instant, sampledAt: sampledAt)
            return
        }
        guard schedule.panelDidOpen(at: instant) else { return }
        cachedPanel.processes = .loading
        publishPanel(cachedPanel)
        tick(at: instant, sampledAt: sampledAt)
    }

    func panelDidClose(at instant: MonitorInstant) {
        guard !isShutdown, schedule.isPanelOpen,
              schedule.panelDidClose(at: instant) else { return }
        panelSession &+= 1
        cachedPanel.processes = .loading
        pendingProcessContext = nil
        panelPublication.didPublish()
    }

    func waitForIdle() async {
        while summaryGate.isActive || processGate.isActive || slowGate.isActive {
            await Task.yield()
        }
    }

    // MARK: Pipelines

    private func requestSummary() {
        guard summaryGate.request() else { return }
        launchSummary()
    }

    private func launchSummary() {
        let collector = summaryCollector
#if DEBUG
        let interval = monitorSignposter.beginInterval("Summary")
#endif
        summaryTask = Task { [weak self] in
            let sample = await collector()
#if DEBUG
            monitorSignposter.endInterval("Summary", interval)
#endif
            guard let self else { return }
            guard !self.isShutdown else {
                self.summaryGate = CollectionGate()
                return
            }
            self.applySummary(sample)
            if self.summaryGate.finishedAndShouldRepeat() {
                self.launchSummary()
            }
        }
    }

    private func applySummary(_ sample: SummarySample) {
        var next = cachedPanel
        var hadSuccess = false

        switch sample.cpu {
        case let .success(value):
            next.cpu = .available(value, sampledAt: sample.sampledAt)
            next.cpuHistory = Self.pushed(next.cpuHistory, value)
            hadSuccess = true
        case let .failure(error):
            next.cpu = next.cpu.recordingFailure(error)
        }

        switch sample.memory {
        case let .success(value):
            next.memory = .available(value, sampledAt: sample.sampledAt)
            next.memoryHistory = Self.pushed(next.memoryHistory, value.pressurePercent)
            detectMemory(value, at: sample.sampledAt)
            hadSuccess = true
        case let .failure(error):
            next.memory = next.memory.recordingFailure(error)
        }

        switch sample.swap {
        case let .success(value):
            next.swap = .available(value, sampledAt: sample.sampledAt)
            next.swapHistory = Self.pushed(next.swapHistory, value.percent)
            hadSuccess = true
        case let .failure(error):
            next.swap = next.swap.recordingFailure(error)
        }

        switch sample.network {
        case let .success(value):
            next.network = .available(value, sampledAt: sample.sampledAt)
            detectNetwork(value, at: sample.sampledAt)
            hadSuccess = true
        case let .failure(error):
            next.network = next.network.recordingFailure(error)
        }

        if hadSuccess { next.latestUpdate = sample.sampledAt }
        cachedPanel = next
        attention.ingestHost(
            cpuHistory: next.cpuHistory,
            memory: try? sample.memory.get(),
            swap: try? sample.swap.get(),
            at: sample.sampledAt
        )

        if let cpu = next.cpu.value, let memory = next.memory.value {
            publishStatus(
                .make(
                    cpuPercent: cpu,
                    memory: memory,
                    cpuHistory: next.cpuHistory,
                    isDelayed: next.cpu.isStale || next.memory.isStale,
                    hasAttention: attention.hasAttention
                )
            )
        }
        if schedule.isPanelOpen, panelPublication.resultApplied() {
            publishPanel(next)
        }
    }

    private func requestProcesses(_ context: CollectionContext) {
        guard schedule.isPanelOpen else { return }
        pendingProcessContext = context
        guard processGate.request() else { return }
        launchProcesses(context)
    }

    private func launchProcesses(_ context: CollectionContext) {
        let collector = processCollector
        panelPublication.processSampleStarted()
#if DEBUG
        let interval = monitorSignposter.beginInterval("Processes")
#endif
        processTask = Task { [weak self] in
            // Process grouping and sorting scale with the full process list.
            // Prepare the small immutable presentation away from the UI actor.
            let result = await Task.detached(priority: .utility) {
                await collector().map { ProcessOverview(samples: $0) }
            }.value
#if DEBUG
            monitorSignposter.endInterval("Processes", interval)
#endif
            guard let self else { return }
            guard !self.isShutdown else {
                self.processGate = CollectionGate()
                return
            }
            var applied = false
            if self.schedule.isPanelOpen, context.panelSession == self.panelSession {
                var next = self.cachedPanel
                switch result {
                case let .success(overview):
                    next.processes = .available(
                        overview,
                        sampledAt: context.sampledAt
                    )
                    next.latestUpdate = max(next.latestUpdate, context.sampledAt)
                    self.ingestOverview(overview, at: context.sampledAt)
                case let .failure(error):
                    next.processes = next.processes.recordingFailure(error)
                }
                self.cachedPanel = next
                applied = true
            }
            // The summary that landed during this sample publishes with it.
            if self.panelPublication.processSampleFinished(applied: applied), self.schedule.isPanelOpen {
                self.publishPanel(self.cachedPanel)
            }
            self.finishProcesses()
        }
    }

    private func finishProcesses() {
        guard processGate.finishedAndShouldRepeat() else {
            pendingProcessContext = nil
            return
        }
        guard schedule.isPanelOpen, let context = pendingProcessContext else {
            // The coalesced repeat was consumed by the gate; finish its active
            // slot without launching forbidden hidden work.
            _ = processGate.finishedAndShouldRepeat()
            pendingProcessContext = nil
            return
        }
        launchProcesses(context)
    }

    /// The attention watch: one light process sample a minute while the
    /// popover is closed and AI briefs are on. Feeds the rules only.
    private func requestWatchProcesses(_ context: CollectionContext) {
        guard !schedule.isPanelOpen, schedule.watchProcessesDue(at: context.instant),
              watchGate.request() else { return }
        let collector = processCollector
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await collector().map { ProcessOverview(samples: $0) }
            }.value
            guard let self else { return }
            self.watchGate = CollectionGate()
            guard !self.isShutdown, !self.schedule.isPanelOpen, case let .success(overview) = result else { return }
            self.ingestOverview(overview, at: context.sampledAt)
        }
    }

    private func ingestOverview(_ overview: ProcessOverview, at date: Date) {
        latestOverview = overview
        attention.ingestProcesses(
            overview.topCPU,
            frontmostAppPath: NSWorkspace.shared.frontmostApplication?.bundleURL?.path,
            ownPath: Bundle.main.executablePath,
            at: date
        )
    }

    private func publishStatus(_ summary: StatusSummary) {
        lastStatusSummary = summary
        statusModel.publish(summary)
    }

    /// Everything SysBar already knows, for an AI brief. Nothing is collected here.
    private func briefInputs() -> BriefInputs? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        var appNames: [String: String] = [:]
        for group in (latestOverview?.topCPU ?? []) + (latestOverview?.topMemory ?? []) {
            if let path = group.executablePath {
                appNames[path] = AppDisplayName.name(forExecutablePath: path)
            }
        }
        return BriefInputs(
            now: Date(),
            mac: .current(frontmostApp: frontmost?.localizedName),
            snapshot: cachedPanel,
            processes: latestOverview,
            trigger: nil,
            activeItems: [],
            appNames: appNames,
            listenerAppNames: cachedPanel.listenerExecutablePaths.mapValues(AppDisplayName.name(forExecutablePath:)),
            ownExecutablePath: Bundle.main.executablePath,
            frontmostAppPath: frontmost?.bundleURL?.path
        )
    }

    private func requestSlowWork(_ context: CollectionContext) {
        pendingSlowContext = context
        guard slowGate.request() else { return }
        launchSlowWork(context)
    }

    private func launchSlowWork(_ context: CollectionContext) {
        // Scheduling is intentionally consumed only after the gate grants this
        // collection. Coalesced requests are evaluated against current state.
        let due = schedule.workDue(at: context.instant)
        let wantsPorts = due.contains(.ports)
        let wantsDisk = due.contains(.disk)
        guard wantsPorts || wantsDisk else {
            finishSlowWork()
            return
        }

        let ports = portsCollector
        let disk = diskCollector
        slowTask = Task { [weak self] in
            async let portResult = Self.collectPorts(wantsPorts, using: ports)
            async let diskResult = Self.collectDisk(wantsDisk, using: disk)
            let results = await (portResult, diskResult)
            guard let self else { return }
            guard !self.isShutdown else {
                self.slowGate = CollectionGate()
                return
            }
            if context.panelSession == self.panelSession {
                self.applySlowResults(
                    ports: results.0,
                    disk: results.1,
                    sampledAt: context.sampledAt
                )
            } else {
                // A discarded sample cannot satisfy the cache cadence. A
                // quick close/reopen otherwise leaves missing disk data for
                // a full minute even though the panel is visible again.
                self.schedule.invalidate(due, collectedAt: context.instant)
            }
            self.finishSlowWork()
        }
    }

    private func applySlowResults(
        ports portResult: Result<[ListenSocket], TelemetryError>?,
        disk diskResult: Result<DiskSnapshot, TelemetryError>?,
        sampledAt: Date
    ) {
        var next = cachedPanel
        var hadSuccess = false
        var listenerIngest: ([ListenSocket], Set<ListenerEndpointKey>, [Int32: String])?
        var diskVolume: VolumeInfo?
        if let portResult {
            switch portResult {
            case let .success(ports):
                let paths = resolveListenerPaths(ports)
                next.listenPorts = .available(ports, sampledAt: sampledAt)
                next.listenerExecutablePaths = paths
                next.trustedListenerKeys = Set(
                    ports
                        .filter {
                            $0.exposure == .actionableLAN
                                && Self.isTrustedAppleListener($0, executablePath: paths[$0.pid])
                        }
                        .map(\.endpointKey)
                )
                detectPorts(ports, paths: paths, at: sampledAt)
                listenerIngest = (ports, next.trustedListenerKeys, paths.mapValues(AppDisplayName.name(forExecutablePath:)))
                hadSuccess = true
            case let .failure(error):
                next.listenPorts = next.listenPorts.recordingFailure(error)
            }
        }
        if let diskResult {
            switch diskResult {
            case let .success(disk):
                next.disk = .available(disk, sampledAt: sampledAt)
                diskVolume = DiskPresentationPolicy.internalVolume(in: disk)
                hadSuccess = true
            case let .failure(error):
                next.disk = next.disk.recordingFailure(error)
            }
        }
        if hadSuccess { next.latestUpdate = max(next.latestUpdate, sampledAt) }
        let changesContent = Self.slowContentChanged(from: cachedPanel, to: next)
        cachedPanel = next
        // The rules run after the snapshot is current, so a brief or an
        // action plan for a new item sees the sample that raised it.
        if let (ports, trusted, names) = listenerIngest {
            attention.ingestListeners(ports, trusted: trusted, names: names, at: sampledAt)
        }
        if let diskVolume {
            attention.ingestDisk(freeGB: diskVolume.freeGB, totalGB: diskVolume.totalGB, at: sampledAt)
        }
        if schedule.isPanelOpen, panelPublication.resultApplied(changesContent: changesContent) {
            publishPanel(next)
        }
    }

    /// Whether a ports or disk scan changed what the panel shows. A repeat
    /// scan that only moves its timestamps waits for the next tick's publication.
    private static func slowContentChanged(from old: PanelSnapshot, to new: PanelSnapshot) -> Bool {
        !(old.listenPorts.hasSameContent(as: new.listenPorts)
            && old.disk.hasSameContent(as: new.disk)
            && old.trustedListenerKeys == new.trustedListenerKeys
            && old.listenerExecutablePaths == new.listenerExecutablePaths)
    }

    /// After an action: one fresh summary and process sample (and a ports and
    /// disk scan when asked), popover open or closed. At most a few per click.
    func resampleForVerification(slow: Bool) {
        guard !isShutdown else { return }
        schedule.requestVerificationSample(slow: slow)
        tick(at: Self.currentInstant())
    }

    private func finishSlowWork() {
        guard slowGate.finishedAndShouldRepeat() else {
            pendingSlowContext = nil
            return
        }
        guard let context = pendingSlowContext else {
            _ = slowGate.finishedAndShouldRepeat()
            return
        }
        launchSlowWork(context)
    }

    // MARK: Alerts and settings

    func setAlertsDesired(_ desired: Bool) async {
        guard !isShutdown else { return }
        await appServices.setAlertsDesired(desired)
        guard !isShutdown else { return }
        schedule.setAlertsEnabled(
            appServices.notificationState.deliveryActive,
            at: Self.currentInstant()
        )
        objectWillChange.send()
        tick(at: Self.currentInstant())
    }

    func toggleCaffeinate() {
        guard !isShutdown else { return }
        if !caffeinated {
            let result = powerAssertions.create(
                type: "PreventUserIdleDisplaySleep",
                level: IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name: "SysBar caffeinate",
                assertionID: &caffeinateAssertion
            )
            if result == kIOReturnSuccess {
                caffeinated = true
            } else {
                // A failed create may still write the out-parameter; never keep
                // an ID this process does not own.
                caffeinateAssertion = 0
            }
        } else {
            if caffeinateAssertion != 0 {
                powerAssertions.release(caffeinateAssertion)
                caffeinateAssertion = 0
            }
            caffeinated = false
        }
        objectWillChange.send()
    }

    func performProcessAction(
        _ signal: ProcessSignal,
        identities: [ProcessIdentity]
    ) async -> ProcessActionReport {
        await processActionService.perform(signal, on: identities)
    }

    private func detectPorts(_ ports: [ListenSocket], paths: [Int32: String], at date: Date) {
        defer { lastSuccessfulPorts = ports }
        // With AI briefs on, the attention watch reports new listeners instead.
        guard !attention.watchEnabled,
              appServices.notificationState.deliveryActive,
              let previous = lastSuccessfulPorts else { return }
        for port in ListenerDiff.exposuresAdded(from: previous, to: ports) {
            guard !Self.isTrustedAppleListener(port, executablePath: paths[port.pid]) else { continue }
            let id = "port:\(port.endpointKey)"
            guard canFireAlert(id: id, at: date) else { continue }
            alertLastFired[id] = date
            emitAlert(
                title: AppResources.localized("New LAN-exposed port"),
                body: PortDisplayText.listenerAlertBody(
                    processName: port.processName,
                    bindAddress: port.bindAddress,
                    port: port.port
                )
            )
        }
    }

    /// One path lookup per listening process per scan. A PID reused between the
    /// lsof scan and this read can at worst mislabel a row or suppress one
    /// alert; it never authorizes an action (rows carry no process identity).
    private func resolveListenerPaths(_ ports: [ListenSocket]) -> [Int32: String] {
        var paths: [Int32: String] = [:]
        for port in ports where paths[port.pid] == nil {
            if let path = port.processIdentity?.executablePath
                ?? alertIdentityReader.readExecutablePath(for: port.pid) {
                paths[port.pid] = path
            }
        }
        return paths
    }

    /// ADR-011: trusted only when the name is on the Apple-daemon allowlist and
    /// the live executable sits in a SIP-protected system location. The name is
    /// checked both as lsof reports it (truncated to 9 characters) and as the
    /// executable's full file name, so `remotepai`/`identitys` still match.
    nonisolated static func isTrustedAppleListener(_ port: ListenSocket, executablePath: String?) -> Bool {
        guard let path = executablePath else { return false }
        let executableName = (path as NSString).lastPathComponent
        guard portAlertAllowlist.contains(port.processName)
            || portAlertAllowlist.contains(executableName) else { return false }
        return systemExecutablePrefixes.contains(where: path.hasPrefix)
    }

    nonisolated static let systemExecutablePrefixes = [
        "/System/Library/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/Library/Apple/System/Library/"
    ]

    private func detectNetwork(_ network: NetworkState, at date: Date) {
        defer { lastVPNState = network.vpnActive }
        guard appServices.notificationState.deliveryActive,
              let previous = lastVPNState,
              previous != network.vpnActive else { return }
        let id = "vpn:\(network.vpnActive)"
        guard canFireAlert(id: id, at: date) else { return }
        alertLastFired[id] = date
        emitAlert(
            title: AppResources.localized(network.vpnActive ? "VPN connected" : "VPN disconnected"),
            body: network.vpnActive
                ? AppResources.formatted(
                    "alert.vpn.connected.body",
                    fallback: "Tunnel: %@ (%@)",
                    network.vpnInterface ?? "?",
                    network.vpnIP ?? "?"
                )
                : AppResources.formatted(
                    "alert.vpn.disconnected.body",
                    fallback: "Real IP: %@",
                    network.primaryIP ?? "?"
                )
        )
    }

    private func detectMemory(_ memory: MemorySnapshot, at date: Date) {
        guard appServices.notificationState.deliveryActive else { return }
        let critical = memory.freeMB <= Thresholds.memCriticalMB
        let healthy = memory.freeMB > Thresholds.memCriticalMB * 3 / 2
        if critical, memAlertArmed, canFireAlert(id: "memory:critical", at: date) {
            alertLastFired["memory:critical"] = date
            emitAlert(
                title: AppResources.localized("Memory critical"),
                body: AppResources.formatted(
                    "alert.memory.critical.body",
                    fallback: "Only %lld MB available",
                    Int64(memory.freeMB)
                )
            )
            memAlertArmed = false
        } else if healthy {
            memAlertArmed = true
        }
    }

    private func canFireAlert(id: String, at date: Date) -> Bool {
        guard let previous = alertLastFired[id] else { return true }
        return date.timeIntervalSince(previous) >= alertCooldownSeconds
    }

    private func emitAttention(_ note: AttentionNotification) {
        guard appServices.notificationState.deliveryActive else { return }
        emittedAlerts.append(MonitorAlert(title: note.title, body: note.body))
        let payload = NotificationPayload(
            identifier: note.identifier,
            title: note.title,
            body: note.body,
            actions: note.actions.map {
                NotificationPayload.Action(id: $0.id, title: $0.title, isDestructive: $0.isDestructive, opensApp: $0.opensApp)
            }
        )
        Task { [weak self] in
            await self?.appServices.deliver(payload)
        }
    }

    private func emitAlert(title: String, body: String) {
        guard appServices.notificationState.deliveryActive else { return }
        emittedAlerts.append(MonitorAlert(title: title, body: body))
        Task { [weak self] in
            await self?.appServices.deliver(title: title, body: body)
        }
    }

    func refreshAppServices() async {
        guard !isShutdown else { return }
        if let serviceRefreshTask {
            await serviceRefreshTask.value
            return
        }
        let services = appServices
        let refreshTask = Task { await services.load() }
        serviceRefreshTask = refreshTask
        await refreshTask.value
        guard !isShutdown else { return }
        serviceRefreshTask = nil
        schedule.setAlertsEnabled(
            appServices.notificationState.deliveryActive,
            at: Self.currentInstant()
        )
        tick(at: Self.currentInstant())
    }

    // MARK: Timer and helpers

    private func startTimer() {
        let timer = Timer(timeInterval: monitorRefreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick(at: Self.currentInstant())
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func currentInstant() -> MonitorInstant {
        .seconds(Int64(ProcessInfo.processInfo.systemUptime))
    }

    private static func pushed(_ values: [Double], _ value: Double) -> [Double] {
        var result = values
        if result.count == monitorHistoryCapacity { result.removeFirst() }
        result.append(value)
        return result
    }

    private func publishPanel(_ snapshot: PanelSnapshot) {
#if DEBUG
        let interval = monitorSignposter.beginInterval("Panel publication")
#endif
        panelModel.publish(snapshot)
        panelPublication.didPublish()
#if DEBUG
        monitorSignposter.endInterval("Panel publication", interval)
#endif
    }

    nonisolated private static func collectPorts(
        _ enabled: Bool,
        using collector: PortsCollector
    ) async -> Result<[ListenSocket], TelemetryError>? {
        guard enabled else { return nil }
#if DEBUG
        let interval = monitorSignposter.beginInterval("Ports")
        defer { monitorSignposter.endInterval("Ports", interval) }
#endif
        return await collector()
    }

    nonisolated private static func collectDisk(
        _ enabled: Bool,
        using collector: DiskCollector
    ) async -> Result<DiskSnapshot, TelemetryError>? {
        guard enabled else { return nil }
#if DEBUG
        let interval = monitorSignposter.beginInterval("Disk")
        defer { monitorSignposter.endInterval("Disk", interval) }
#endif
        return await collector()
    }
}
