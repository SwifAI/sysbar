import AppKit
import SwiftUI

/// Scroll anchors that a brief's Show action jumps to.
enum HealthBriefActionRoute: Hashable, Sendable {
    case topCPU
    case topMemory
    case listeningPorts
}

struct MenuContentView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var appServices: AppServicesModel
    @EnvironmentObject private var attention: AttentionModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pendingAction: PendingProcessAction?
    @State private var actionFeedback: ProcessActionFeedback?
    @State private var topCPUExpansionRequest = 0
    @State private var topMemoryExpansionRequest = 0
    @State private var portsExpansionRequest = 0
    @State private var scrollTarget: AnyHashable?
    @State private var healthBriefNavigationGeneration = 0
    @State private var listenerSearchFocusRequest = 0
    @State private var showsAllPorts = false
    @State private var servicesExpansionRequest = 0
    @State private var statusExpanded = false
    // Held without observing: pointer scrubbing must redraw only the cursor
    // overlays and the axis caption, never the whole popover.
    @State private var scrub = TraceScrubModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(MenuSection.panelOrder, id: \.self) { section in
                            sectionView(for: section)
                        }
                    }
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: healthBriefNavigationGeneration) { _ in
                    guard let route = scrollTarget else { return }
                    DispatchQueue.main.async {
                        if reduceMotion {
                            proxy.scrollTo(route, anchor: .top)
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(route, anchor: .top)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 160)

            Divider()
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .frame(width: 380)
        .onAppear {
            // Open straight onto whatever needs attention, or a fix's result.
            if !attention.cardEntries.isEmpty { statusExpanded = true }
        }
        .onChange(of: attention.revealCount) { _ in
            statusExpanded = true
            scroll(to: AnyHashable(MenuSection.security))
        }
        .onDisappear {
            scrub.scrub(to: nil)
        }
        .confirmationDialog(
            pendingAction?.title ?? AppResources.localized("Confirm Process Action"),
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(pendingAction.buttonTitle, role: .destructive) {
                    self.pendingAction = nil
                    execute(pendingAction)
                }
            }
            Button(AppResources.localized("Cancel"), role: .cancel) { pendingAction = nil }
        } message: {
            if let pendingAction {
                Text(pendingAction.message)
            }
        }
        .confirmationDialog(
            attention.pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { attention.pendingConfirmation != nil },
                set: { if !$0 { attention.cancelPending() } }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation = attention.pendingConfirmation {
                Button(confirmation.confirmTitle, role: .destructive) { attention.confirmPending() }
            }
            Button(AppResources.localized("Cancel"), role: .cancel) { attention.cancelPending() }
        } message: {
            if let confirmation = attention.pendingConfirmation {
                Text(confirmation.message)
            }
        }
        .alert(item: $actionFeedback) { feedback in
            Alert(
                title: Text(feedback.title),
                message: Text(feedback.message),
                dismissButton: .default(Text(AppResources.localized("OK")))
            )
        }
    }

    /// Renders one scroll-view section. `MenuSection.panelOrder` is the
    /// single source of the section order; the `.id` values are the scroll
    /// anchors that `HealthBriefActionRoute` navigation targets.
    @ViewBuilder
    private func sectionView(for section: MenuSection) -> some View {
        switch section {
        case .security:
            securitySection
                .id(MenuSection.security)
        case .metrics:
            PanelReader(panel: monitor.panelModel) { snapshot in
                metricsSection(snapshot)
            }
        case .cpu:
            PanelReader(panel: monitor.panelModel) { snapshot in
                processSection(
                    title: "Top CPU",
                    key: .topCPU,
                    sort: .cpu,
                    processes: snapshot.processes,
                    expansionRequest: topCPUExpansionRequest
                )
            }
            .id(HealthBriefActionRoute.topCPU)
        case .memory:
            PanelReader(panel: monitor.panelModel) { snapshot in
                processSection(
                    title: "Top Memory",
                    key: .topMem,
                    sort: .memory,
                    processes: snapshot.processes,
                    expansionRequest: topMemoryExpansionRequest
                )
            }
            .id(HealthBriefActionRoute.topMemory)
        case .ports:
            PanelReader(panel: monitor.panelModel) { snapshot in
                portsSection(snapshot, expansionRequest: portsExpansionRequest)
            }
            .id(HealthBriefActionRoute.listeningPorts)
        case .systemServices:
            systemServicesSection
        }
    }

    // MARK: - Status line

    /// One plain-language status line, and under it the AI briefs for
    /// anything that needs attention, the manual review and today's history.
    private var securitySection: some View {
        let needsAttention = attention.hasAttention
        let headline = needsAttention
            ? AppResources.plural("status.attention.count", count: attention.attentionEntries.count)
            : AppResources.localized("status.normal.headline", fallback: "Everything looks normal")
        let detail = statusDetail
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    statusExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) { statusExpanded.toggle() }
                }
            } label: {
                StatusStrip(
                    headline: headline,
                    detail: detail,
                    needsAttention: needsAttention,
                    isExpanded: statusExpanded
                )
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(headline)
            .accessibilityValue(detail)
            .accessibilityHint(
                AppResources.localized(statusExpanded ? "Hide details and actions" : "Show details and actions")
            )
            .accessibilityAddTraits(statusExpanded ? .isSelected : [])

            if statusExpanded {
                statusDetailArea
                    .padding(.horizontal, TrackLayout.gutter)
                    .padding(.bottom, 12)
                    .transition(briefTransition)
            }
            Divider()
        }
    }

    private var statusDetail: String {
        if let newest = attention.attentionEntries.first {
            return newest.item.fact.text
        }
        if let snoozed = attention.entries.first(where: \.isSnoozed), let until = snoozed.snoozedUntil {
            return AppResources.formatted(
                "status.snoozed.detail",
                fallback: "Snoozed until %1$@ · %2$@",
                until.formatted(date: .omitted, time: .shortened),
                snoozed.item.fact.text
            )
        }
        if case let .ready(review, meta) = attention.review {
            return AppResources.formatted(
                "status.normal.reviewed",
                fallback: "Reviewed %1$@ · %2$@",
                meta.date.formatted(date: .omitted, time: .shortened),
                AppResources.localized("review.overall.\(review.overall.rawValue)", fallback: review.overall.rawValue)
            )
        }
        if let noted = attention.entries.first(where: \.isExpected), case let .ready(brief, _) = noted.brief {
            return AppResources.formatted("status.normal.noted", fallback: "Noted: %@", brief.headline)
        }
        return AppResources.localized(
            "status.normal.watching",
            fallback: "Watching apps, memory, swap, disk and network"
        )
    }

    private var providerName: String { attention.provider.displayName }

    private var statusDetailArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(attention.cardEntries.prefix(3)) { entry in
                AttentionBriefCard(
                    entry: entry,
                    model: attention,
                    providerName: providerName,
                    show: show(_:),
                    turnOn: revealProviderSwitch
                )
                .transition(briefTransition)
            }

            ForEach(attention.entries.filter { entry in !attention.cardEntries.contains { $0.id == entry.id } }) { entry in
                quietRow(entry)
            }

            if attention.review != .idle {
                ReviewCard(state: attention.review, providerName: providerName, show: show(_:)) { attention.runReview() }
            }

            HStack(spacing: 8) {
                if attention.provider != .off {
                    Button(AppResources.localized("status.review.button", fallback: "Review now")) {
                        attention.runReview()
                    }
                    .controlSize(.small)
                    .disabled(attention.review == .running)
                }
                Spacer(minLength: 4)
                Button(providerLine, action: revealProviderSwitch)
                    .buttonStyle(.link)
                    .font(.caption)
            }

            if !attention.history.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppResources.localized("status.history.heading", fallback: "Earlier today"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(attention.history.prefix(5)) { item in
                        Text(historyLine(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ForEach(attention.allowedListeners.sorted(by: { $0.key < $1.key }), id: \.key) { subject, allowed in
                HStack(spacing: 6) {
                    Text(AppResources.formatted(
                        "status.allowed.entry",
                        fallback: "Allowed: %1$@ on %2$@",
                        allowed.name,
                        "\(AppResources.localized(allowed.isTCP ? "TCP" : "UDP")) \(allowed.port)"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button(AppResources.localized("status.allowed.remove", fallback: "Remove")) {
                        attention.removeAllowedListener(subject)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            ForEach(attention.mutes.sorted(by: { $0.key < $1.key }), id: \.key) { subject, mute in
                HStack(spacing: 6) {
                    Text(AppResources.formatted("status.muted.entry", fallback: "Muted today: %@", mute.name))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(AppResources.localized("status.unmute", fallback: "Unmute")) { attention.unmute(subject) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(.top, 2)
    }

    private func historyLine(_ item: AttentionModel.HistoryEntry) -> String {
        let raised = item.raisedAt.formatted(date: .omitted, time: .shortened)
        let cleared = item.clearedAt.formatted(date: .omitted, time: .shortened)
        if let resolution = item.resolution {
            return AppResources.formatted(
                "status.history.fixed",
                fallback: "%1$@ · %2$@–%3$@ · fixed by %4$@",
                item.headline ?? item.fact, raised, cleared, resolution
            )
        }
        return AppResources.formatted(
            "status.history.entry",
            fallback: "%1$@ · %2$@–%3$@ · resolved",
            item.headline ?? item.fact, raised, cleared
        )
    }

    /// A line for an item that doesn't count: snoozed, dismissed or expected.
    /// It keeps the one or two links that still make sense.
    private func quietRow(_ entry: AttentionModel.Entry) -> some View {
        let text: String
        if let until = entry.snoozedUntil {
            text = AppResources.formatted(
                "status.snoozed.detail",
                fallback: "Snoozed until %1$@ · %2$@",
                until.formatted(date: .omitted, time: .shortened),
                entry.item.fact.text
            )
        } else if entry.isDismissed {
            text = AppResources.formatted("status.dismissed.detail", fallback: "Dismissed · %@", entry.item.fact.text)
        } else if case let .ready(brief, _) = entry.brief {
            text = AppResources.formatted("status.normal.noted", fallback: "Noted: %@", brief.headline)
        } else {
            text = entry.item.fact.text
        }
        let allow = entry.isExpected ? entry.plan.buttons.first { $0.allowed.action == .allowListener }?.allowed : nil
        return VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if entry.isSnoozed {
                    Button(AppResources.localized("action.showNow", fallback: "Show now")) { attention.showNow(entry.id) }
                }
                if let allow {
                    Button(ActionLabel.title(allow)) { attention.perform(allow, for: entry.id) }
                }
                if entry.isExpected {
                    Button(AppResources.localized("brief.muteToday", fallback: "Mute today")) { attention.muteToday(entry.id) }
                }
            }
            .buttonStyle(.link)
        }
        .font(.caption)
    }

    private var providerLine: String {
        if attention.provider == .off {
            return AppResources.localized("status.provider.off", fallback: "AI briefs off · Turn on")
        }
        if let status = attention.activeProviderStatus, !status.isReady, status != .checking {
            return AppResources.formatted(
                "status.provider.paused",
                fallback: "AI briefs paused · %@",
                AIProviderPolicy.caption(attention.provider, status: status)
            )
        }
        return AppResources.formatted("status.provider.active", fallback: "Briefs by %@ · Change", providerName)
    }

    private func revealProviderSwitch() {
        servicesExpansionRequest &+= 1
        scroll(to: AnyHashable(Self.systemServicesAnchor))
    }

    /// A card's "Show in …" link: expand that section and scroll to it.
    private func show(_ route: FooterRoute) {
        switch route {
        case .topCPU:
            topCPUExpansionRequest &+= 1
            navigateHealthBrief(to: .topCPU)
        case .topMemory:
            topMemoryExpansionRequest &+= 1
            navigateHealthBrief(to: .topMemory)
        case .network:
            portsExpansionRequest &+= 1
            navigateHealthBrief(to: .listeningPorts)
        }
    }

    // MARK: - Metrics: seismograph hero

    private func metricsSection(_ snapshot: PanelSnapshot) -> some View {
        let health = PanelHealthPresentation.snapshot(snapshot)
        let retry: (() -> Void)? = health == .loading ? nil : { monitor.refresh() }
        return VStack(alignment: .leading, spacing: 0) {
            if health != .current {
                FreshnessStrip(
                    health: health,
                    detail: freshnessDetail(for: health, in: snapshot),
                    retry: retry
                )
                Divider()
            }
            VStack(alignment: .leading, spacing: 0) {
                lane(.cpuHigh, in: snapshot)
                lane(.memoryLow, in: snapshot)
                lane(.swapInUse, in: snapshot)
                lane(.storageLow, in: snapshot)
            }
            .padding(.vertical, 6)
            TraceAxisRow(scrub: scrub, updated: updatedText(snapshot))
            Divider()
        }
    }

    private func updatedText(_ snapshot: PanelSnapshot) -> String? {
        guard snapshot.latestUpdate != .distantPast else { return nil }
        return AppResources.formatted(
            "updated.time",
            fallback: "Updated %@",
            snapshot.latestUpdate.formatted(date: .omitted, time: .shortened)
        )
    }

    private func freshnessDetail(for health: PanelHealthPresentation, in snapshot: PanelSnapshot) -> String? {
        switch health {
        case .current, .loading:
            return nil
        case .unavailable:
            return panelFailures(snapshot).first(where: { $0.sampledAt == nil })?.error.message
        case .stale:
            guard let oldest = panelFailures(snapshot)
                .compactMap({ failure in failure.sampledAt.map { ($0, failure.error) } })
                .min(by: { $0.0 < $1.0 }) else { return nil }
            return AppResources.formatted(
                "last.updated.error",
                fallback: "Last updated %@ · %@",
                oldest.0.formatted(date: .omitted, time: .shortened),
                oldest.1.message
            )
        }
    }

    private func panelFailures(_ snapshot: PanelSnapshot) -> [(sampledAt: Date?, error: TelemetryError)] {
        [
            snapshot.cpu.failureRecord,
            snapshot.memory.failureRecord,
            snapshot.swap.failureRecord,
            snapshot.network.failureRecord,
            snapshot.processes.failureRecord,
            snapshot.listenPorts.failureRecord,
            snapshot.disk.failureRecord
        ].compactMap { $0 }
    }

    @ViewBuilder
    private func lane(_ id: HealthConditionID, in snapshot: PanelSnapshot) -> some View {
        let content = laneContent(for: id, in: snapshot)
        // Lanes are instruments, not buttons: anything that needs attention
        // is explained in the status area at the top.
        MetricLane(content: content, scrub: scrub)
            .focusable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(laneAccessibilityLabel(content))
        .accessibilityValue(laneAccessibilityValue(content))
        .accessibilityHint(
            AppResources.localized(
                "trace.scrub.hint",
                fallback: "Use the Left and Right Arrow keys to review recent samples."
            )
        )
        .accessibilityChartDescriptor(
            LaneChartDescriptor(
                title: laneAccessibilityLabel(content),
                summary: laneAccessibilityValue(content),
                samples: content.samples.map { $0 * 100 }
            )
        )
        .onMoveCommand { direction in
            let step = NSEvent.modifierFlags.contains(.shift) ? 10 : 1
            switch direction {
            case .left: scrub.step(by: step)
            case .right: scrub.step(by: -step)
            default: break
            }
        }
    }

    private func laneAccessibilityLabel(_ content: MetricLaneContent) -> String {
        content.presentation.map { AppResources.localized($0.accessibilityLabel) } ?? content.title
    }

    private func laneAccessibilityValue(_ content: MetricLaneContent) -> String {
        switch content.state {
        case let .loading(message), let .unavailable(message), let .empty(message):
            return message
        case let .value(presentation, _, isStale):
            guard isStale else { return presentation.accessibilityValue }
            return AppResources.formatted(
                "accessibility.detail.status",
                fallback: "%@, %@",
                presentation.accessibilityValue,
                AppResources.localized("Update delayed")
            )
        }
    }

    private func laneContent(for id: HealthConditionID, in snapshot: PanelSnapshot) -> MetricLaneContent {
        switch id {
        case .memoryLow:
            let memory = snapshot.memory.value
            return MetricLaneContent(
                id: id,
                title: AppResources.localized("Memory"),
                symbolName: "memorychip",
                isPrimary: true,
                state: laneState(snapshot.memory, loading: "Updating memory") { memory in
                    let presentation = MetricPresentation.memory(
                        usedGB: memory.usedGB,
                        availableMB: Double(memory.freeMB),
                        totalGB: memory.totalGB,
                        peakPercent: snapshot.memoryHistory.max()
                    )
                    let compact = MetricPresentation.memory(
                        usedGB: memory.usedGB,
                        availableMB: Double(memory.freeMB),
                        totalGB: memory.totalGB
                    )
                    return (presentation, compact.detail)
                },
                samples: snapshot.memoryHistory.map(TraceGeometry.fraction(percent:)),
                isLevel: false,
                thresholds: MetricThresholdLines.memory(totalGB: memory?.totalGB ?? 0)
            )
        case .swapInUse:
            let swap = snapshot.swap.value
            return MetricLaneContent(
                id: id,
                title: AppResources.localized("Swap"),
                symbolName: "arrow.left.arrow.right.square",
                isPrimary: false,
                state: laneState(snapshot.swap, loading: "Updating swap") { swap in
                    let presentation = MetricPresentation.swap(
                        usedMB: Double(swap.usedMB),
                        totalMB: Double(swap.totalMB),
                        peakPercent: snapshot.swapHistory.max()
                    )
                    let compact = MetricPresentation.swap(
                        usedMB: Double(swap.usedMB),
                        totalMB: Double(swap.totalMB)
                    )
                    return (
                        presentation,
                        swap.totalMB == 0 ? AppResources.localized("Not in use") : compact.detail
                    )
                },
                samples: snapshot.swapHistory.map(TraceGeometry.fraction(percent:)),
                isLevel: false,
                thresholds: MetricThresholdLines.swap(totalMB: Double(swap?.totalMB ?? 0))
            )
        case .storageLow:
            let volume = snapshot.disk.value.flatMap(DiskPresentationPolicy.internalVolume(in:))
            return MetricLaneContent(
                id: id,
                title: AppResources.localized("Disk Free"),
                symbolName: "internaldrive",
                isPrimary: false,
                state: laneState(snapshot.disk, loading: "Updating disk") { disk in
                    guard let volume = DiskPresentationPolicy.internalVolume(in: disk) else { return nil }
                    let presentation = MetricPresentation.disk(freeGB: volume.freeGB, totalGB: volume.totalGB)
                    return (presentation, presentation.detail)
                },
                samples: volume.map { [$0.usedFraction] } ?? [],
                isLevel: true,
                thresholds: MetricThresholdLines.disk(totalGB: volume?.totalGB ?? 0)
            )
        default:
            return MetricLaneContent(
                id: .cpuHigh,
                title: AppResources.localized("CPU"),
                symbolName: "cpu",
                isPrimary: true,
                state: laneState(snapshot.cpu, loading: "Updating CPU") { value in
                    let presentation = MetricPresentation.cpu(
                        percent: value,
                        peakPercent: snapshot.cpuHistory.max()
                    )
                    return (presentation, presentation.detail)
                },
                samples: snapshot.cpuHistory.map(TraceGeometry.fraction(percent:)),
                isLevel: false,
                thresholds: MetricThresholdLines.cpu
            )
        }
    }

    private func laneState<Value>(
        _ state: TelemetryState<Value>,
        loading: String,
        present: (Value) -> (MetricPresentation, String?)?
    ) -> LaneState {
        switch state {
        case .loading:
            return .loading(AppResources.localized(loading))
        case let .unavailable(error):
            return .unavailable(error.message)
        case let .available(value, _), let .stale(value, _, _):
            guard let (presentation, detail) = present(value) else {
                return .empty(AppResources.localized("No internal volume detected"))
            }
            return .value(presentation, detail: detail, isStale: state.isStale)
        }
    }

    private func processSection(
        title: String,
        key: SectionKey,
        sort: GroupSort,
        processes: TelemetryState<ProcessOverview>,
        expansionRequest: Int
    ) -> some View {
        let groups = sort == .cpu
            ? (processes.value?.topCPU ?? [])
            : (processes.value?.topMemory ?? [])
        return CollapsibleSection(
            title,
            key: key,
            count: groups.count,
            expansionRequest: expansionRequest
        ) {
            processSectionContent(groups: groups, sort: sort, processes: processes)
        }
        .ledgerSectionPadding()
    }

    @ViewBuilder
    private func processSectionContent(
        groups: [ProcessGroup],
        sort: GroupSort,
        processes: TelemetryState<ProcessOverview>
    ) -> some View {
        switch processes {
        case .loading:
            loadingRow("Sampling processes")
        case let .unavailable(error):
            unavailableRow("Process data unavailable", error: error)
        case let .stale(_, sampledAt, error):
            delayedRow(sampledAt: sampledAt, error: error)
            processRows(groups, sort: sort, actionsEnabled: false)
        case .available:
            processRows(groups, sort: sort, actionsEnabled: true)
        }
    }

    @ViewBuilder
    private func processRows(_ groups: [ProcessGroup], sort: GroupSort, actionsEnabled: Bool) -> some View {
        if groups.isEmpty {
            EmptyStateRow(icon: "hourglass", message: "Collecting a second sample…", tint: .secondary)
        } else {
            ForEach(groups) { group in
                ProcessRow(
                    group: group,
                    metric: sort == .cpu ? .percent : .megabytes,
                    value: sort == .cpu ? group.totalCPU : Double(group.totalMemMB),
                    terminateAction: actionsEnabled ? { identities in
                        requestAction(name: group.name, signal: .terminate, identities: identities)
                    } : nil,
                    forceKillAction: actionsEnabled ? { identities in
                        requestAction(name: group.name, signal: .forceKill, identities: identities)
                    } : nil
                )
                .equatable()
            }
        }
    }

    private func portsSection(_ snapshot: PanelSnapshot, expansionRequest: Int) -> some View {
        let ports = snapshot.listenPorts.value ?? []
        return CollapsibleSection(
            "Network",
            key: .ports,
            expansionRequest: expansionRequest
        ) {
            networkSummary(snapshot.network)
                .padding(.bottom, 6)
            HStack(spacing: 6) {
                Text(AppResources.localized("Listening Ports"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                if !ports.isEmpty {
                    Text(ports.count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(AppResources.plural("items.count", count: ports.count))
                }
            }
            .padding(.horizontal, 6)
            portsSectionContent(ports, in: snapshot)
        }
        .ledgerSectionPadding()
    }

    @ViewBuilder
    private func networkSummary(_ network: TelemetryState<NetworkState>) -> some View {
        switch network {
        case .loading:
            loadingRow("Updating network status")
        case let .unavailable(error):
            unavailableRow("Network unavailable", error: error)
        case let .available(network, _), let .stale(network, _, _):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                networkRow(
                    "VPN",
                    network.vpnActive
                        ? ([network.vpnInterface, network.vpnIP].compactMap { $0 }.joined(separator: " · "))
                        : AppResources.localized("Off")
                )
                networkRow(
                    "IP address",
                    network.primaryIP ?? AppResources.localized("No primary IP detected")
                )
                networkRow(
                    "DNS",
                    network.dnsServers.isEmpty
                        ? AppResources.localized("System default")
                        : network.dnsServers.joined(separator: ", ")
                )
                networkRow(
                    "Traffic",
                    AppResources.formatted(
                        "network.transfer",
                        fallback: "↑ %@  ↓ %@",
                        MetricFormat.rate(bytesPerSecond: network.txBytesPerSec),
                        MetricFormat.rate(bytesPerSecond: network.rxBytesPerSec)
                    )
                )
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.top, 2)
        }
    }

    private func networkRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(AppResources.localized(label))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func portsSectionContent(_ ports: [ListenSocket], in snapshot: PanelSnapshot) -> some View {
        switch snapshot.listenPorts {
        case .loading:
            loadingRow("Checking ports")
        case let .unavailable(error):
            unavailableRow("Listening ports unavailable", error: error)
        case let .stale(_, sampledAt, error):
            delayedRow(sampledAt: sampledAt, error: error)
            exposureVerdict(ports, in: snapshot)
            foldedPortRows(ports, in: snapshot, actionsEnabled: false)
        case .available:
            if ports.isEmpty {
                EmptyStateRow(icon: "checkmark.shield", message: "No listening ports detected", tint: .sbSuccess)
            } else {
                exposureVerdict(ports, in: snapshot)
                foldedPortRows(ports, in: snapshot, actionsEnabled: true)
            }
        }
    }

    /// The answer first: is anything other devices can reach worth a look,
    /// and what to do about it. The raw port list stays one click away.
    private func exposureVerdict(_ ports: [ListenSocket], in snapshot: PanelSnapshot) -> some View {
        let verdict = ExposureVerdict(
            ports,
            trusted: snapshot.trustedListenerKeys,
            allowedSubjects: Set(attention.allowedListeners.keys)
        )
        let names = snapshot.listenerExecutablePaths.mapValues(AppDisplayName.name(forExecutablePath:))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: verdict.isClear ? "checkmark.shield" : "wifi.exclamationmark")
                    .foregroundStyle(verdict.isClear ? Color.secondary : Color.sbWarning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verdict.title(names: names))
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verdict.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            ForEach(verdict.needsLook) { port in
                HStack(spacing: 6) {
                    ProcessIcon(executablePath: snapshot.listenerExecutablePaths[port.pid])
                    Text(names[port.pid] ?? port.processName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(PortDisplayText.endpoint(
                        transport: port.isTCP ? "TCP" : "UDP",
                        bindAddress: port.bindAddress,
                        port: port.port
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(AppResources.localized("ports.verdict.allow", fallback: "Allow")) { attention.allow(port) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityLabel(AppResources.formatted(
                            "action.allowListener", fallback: "Allow %1$@ on %2$@", port.processName, String(port.port)
                        ))
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func foldedPortRows(_ ports: [ListenSocket], in snapshot: PanelSnapshot, actionsEnabled: Bool) -> some View {
        Button {
            showsAllPorts.toggle()
        } label: {
            HStack(spacing: 2) {
                Text(showsAllPorts
                    ? AppResources.localized("ports.hideAll", fallback: "Hide port list")
                    : AppResources.formatted("ports.showAll", fallback: "Show all %@ ports", ports.count.formatted()))
                Image(systemName: showsAllPorts ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.horizontal, 6)
        .accessibilityValue(AppResources.localized(showsAllPorts ? "Expanded" : "Collapsed"))
        .onChange(of: listenerSearchFocusRequest) { _ in showsAllPorts = true }
        if showsAllPorts {
            portRows(ports, in: snapshot, actionsEnabled: actionsEnabled)
        }
    }

    private func portRows(_ ports: [ListenSocket], in snapshot: PanelSnapshot, actionsEnabled: Bool) -> some View {
        ListenerList(
            ports: ports,
            resetRequest: portsExpansionRequest,
            searchFocusRequest: listenerSearchFocusRequest,
            trustedKeys: snapshot.trustedListenerKeys,
            executablePaths: snapshot.listenerExecutablePaths,
            terminateAction: actionsEnabled ? { port, identity in
                requestAction(name: port.processName, signal: .terminate, identities: [identity])
            } : nil,
            forceKillAction: actionsEnabled ? { port, identity in
                requestAction(name: port.processName, signal: .forceKill, identities: [identity])
            } : nil
        )
        .equatable()
    }

    private var systemServicesSection: some View {
        CollapsibleSection(
            "System Services",
            key: .systemServices,
            expansionRequest: servicesExpansionRequest,
            requiresAttention: systemServicesRequireAttention
        ) {
            VStack(alignment: .leading, spacing: 8) {
                AIProviderSwitch(model: attention)
                Divider()
                notificationServiceStatus
                if let error = appServices.notificationState.errorMessage {
                    serviceError(error) {
                        Task { await monitor.setAlertsDesired(appServices.notificationState.desired) }
                    }
                }

                Divider()
                loginItemStatus
                if let error = appServices.loginItemError {
                    serviceError(error) {
                        Task { await appServices.refreshLoginItem() }
                    }
                }
            }
            .panelCard()
        }
        .ledgerSectionPadding()
        .id(Self.systemServicesAnchor)
    }

    private var systemServicesRequireAttention: Bool {
        let providerBlocked: Bool = {
            switch attention.activeProviderStatus {
            case .signInNeeded?, .unverified?, .notInstalled?: return true
            default: return false
            }
        }()
        return providerBlocked
            || appServices.notificationState.errorMessage != nil
            || (appServices.notificationState.desired && appServices.notificationState.requiresOpenSettings)
            || appServices.loginItemError != nil
            || appServices.loginItemState == .requiresApproval
    }

    @ViewBuilder
    private var notificationServiceStatus: some View {
        let state = appServices.notificationState
        if !state.desired {
            StateMessageRow(
                symbolName: "bell.slash",
                title: AppResources.localized("Alerts off"),
                detail: AppResources.localized("SysBar will not post notifications.")
            )
        } else if state.deliveryActive {
            StateMessageRow(
                symbolName: "bell.badge.fill",
                title: AppResources.localized("Alerts active"),
                detail: AppResources.localized("macOS notifications and alert banners are enabled."),
                severity: .normal
            )
        } else if state.requiresOpenSettings {
            StateMessageRow(
                symbolName: "bell.badge.slash.fill",
                title: AppResources.localized(
                    state.authorization == .denied
                        ? "Notifications denied"
                        : "Notification alerts disabled"
                ),
                detail: AppResources.localized(
                    "Allow SysBar alerts in System Settings to receive warnings."
                ),
                severity: .warning,
                actionTitle: AppResources.localized("Open Settings"),
                action: appServices.openNotificationSettings
            )
        } else if state.authorization == .notDetermined {
            StateMessageRow(
                symbolName: "bell.badge",
                title: AppResources.localized("Notification permission pending"),
                detail: AppResources.localized(
                    "Complete the macOS permission request to enable alerts."
                )
            )
        } else {
            StateMessageRow(
                symbolName: "bell.badge.slash",
                title: AppResources.localized("Alerts unavailable"),
                detail: AppResources.localized("macOS notification status could not be confirmed."),
                severity: .warning
            )
        }
    }

    @ViewBuilder
    private var loginItemStatus: some View {
        switch appServices.loginItemState {
        case .enabled, .notRegistered, .notFound:
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppResources.localized("Open at Login"))
                        .font(.body)
                    Text(AppResources.localized(appServices.loginItemState == .enabled ? "Enabled" : "Off"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle(AppResources.localized("Open at Login"), isOn: loginItemBinding)
                    .labelsHidden()
                    .accessibilityLabel(AppResources.localized("Open at Login"))
                    .accessibilityValue(
                        AppResources.localized(appServices.loginItemState == .enabled ? "On" : "Off")
                    )
            }
            .padding(.vertical, 4)
        case .requiresApproval:
            StateMessageRow(
                symbolName: "exclamationmark.triangle.fill",
                title: AppResources.localized("Login item needs approval"),
                detail: AppResources.localized("Allow SysBar in Login Items in System Settings."),
                severity: .warning,
                actionTitle: AppResources.localized("Open Settings"),
                action: { Task { await appServices.openLoginItemSettings() } }
            )
        case .unavailable:
            StateMessageRow(
                symbolName: "power.circle",
                title: AppResources.localized("Login item unavailable"),
                detail: AppResources.localized(
                    "The current launch environment cannot manage this service."
                )
            )
        }
    }

    private func serviceError(_ message: String, retry: @escaping () -> Void) -> some View {
        StateMessageRow(
            symbolName: "exclamationmark.circle.fill",
            title: AppResources.localized("System service error"),
            detail: message,
            severity: .critical,
            actionTitle: AppResources.localized("Retry"),
            action: retry
        )
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Toggle(isOn: alertsBinding) {
                Label(
                    AppResources.localized("Alerts"),
                    systemImage: appServices.notificationState.desired ? "bell.fill" : "bell.slash"
                )
            }
            .toggleStyle(FooterToggleStyle())
            .help(AppResources.localized(appServices.notificationState.desired ? "Disable alerts" : "Enable alerts"))
            .accessibilityValue(AppResources.localized(appServices.notificationState.desired ? "On" : "Off"))

            Toggle(isOn: displayBinding) {
                Label(
                    AppResources.localized("Keep Awake"),
                    systemImage: monitor.caffeinated ? "cup.and.saucer.fill" : "cup.and.saucer"
                )
            }
            .toggleStyle(FooterToggleStyle())
            .help(AppResources.localized(monitor.caffeinated ? "Allow display sleep" : "Prevent display sleep"))
            .accessibilityValue(
                AppResources.localized(monitor.caffeinated ? "Display stays awake" : "Display may sleep")
            )

            Spacer(minLength: 4)

            Button(AppResources.localized("Search listening ports")) {
                focusListenerSearch()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            Button { monitor.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: [.command])
            .help(AppResources.localized("Refresh"))
            .accessibilityLabel(AppResources.localized("Refresh"))

            Button(role: .destructive) { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: [.command])
            .help(AppResources.localized("Quit SysBar"))
            .accessibilityLabel(AppResources.localized("Quit SysBar"))
        }
        .controlSize(.small)
    }

    private var alertsBinding: Binding<Bool> {
        Binding(
            get: { appServices.notificationState.desired },
            set: { desired in Task { await monitor.setAlertsDesired(desired) } }
        )
    }

    private var displayBinding: Binding<Bool> {
        Binding(
            get: { monitor.caffeinated },
            set: { desired in
                if desired != monitor.caffeinated { monitor.toggleCaffeinate() }
            }
        )
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { appServices.loginItemState == .enabled },
            set: { enabled in Task { await appServices.setLoginItemEnabled(enabled) } }
        )
    }

    private func loadingRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(AppResources.localized(title)).font(.body).foregroundStyle(.secondary)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }

    private func unavailableRow(_ title: String, error: TelemetryError) -> some View {
        StateMessageRow(
            symbolName: "exclamationmark.octagon.fill",
            title: AppResources.localized(title),
            detail: error.message,
            severity: .critical,
            actionTitle: AppResources.localized("Retry"),
            action: monitor.refresh
        )
    }

    private func delayedRow(sampledAt: Date, error: TelemetryError) -> some View {
        StateMessageRow(
            symbolName: "clock.badge.exclamationmark",
            title: AppResources.localized("Update delayed"),
            detail: AppResources.formatted(
                "last.updated.error",
                fallback: "Last updated %@ · %@",
                sampledAt.formatted(date: .omitted, time: .shortened),
                error.message
            ),
            severity: .warning
        )
    }

    private func requestAction(name: String, signal: ProcessSignal, identities: [ProcessIdentity]) {
        let action = PendingProcessAction(name: name, signal: signal, identities: identities)
        if ProcessActionPolicy.requiresConfirmation(signal: signal, processCount: identities.count) {
            pendingAction = action
        } else {
            execute(action)
        }
    }

    private func execute(_ action: PendingProcessAction) {
        Task {
            let report = await monitor.performProcessAction(action.signal, identities: action.identities)
            actionFeedback = .make(from: report)
        }
    }

    private func focusListenerSearch() {
        portsExpansionRequest &+= 1
        listenerSearchFocusRequest &+= 1
        navigateHealthBrief(to: .listeningPorts)
    }

    private func navigateHealthBrief(to route: HealthBriefActionRoute) {
        scroll(to: AnyHashable(route))
    }

    private func scroll(to target: AnyHashable) {
        scrollTarget = target
        healthBriefNavigationGeneration &+= 1
    }

    private static let systemServicesAnchor = "system-services-anchor"

    private var briefTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top))
    }

}

/// Observes only the panel model. A panel publication (once per tick) then
/// re-renders the sections that show telemetry, not the status line, the
/// services, the footer or the dialogs around them.
private struct PanelReader<Content: View>: View {
    @ObservedObject var panel: PanelDetailModel
    @ViewBuilder let content: (PanelSnapshot) -> Content

    var body: some View {
        content(panel.snapshot)
    }
}

private extension View {
    func ledgerSectionPadding() -> some View {
        padding(.horizontal, 12).padding(.top, 10)
    }
}

private extension TelemetryState {
    /// The failure behind a stale or unavailable state, with the time of the
    /// last good sample when there is one.
    var failureRecord: (sampledAt: Date?, error: TelemetryError)? {
        switch self {
        case let .stale(_, sampledAt, error): return (sampledAt, error)
        case let .unavailable(error): return (nil, error)
        case .loading, .available: return nil
        }
    }

    var failure: TelemetryError? { failureRecord?.error }
}

private struct PendingProcessAction: Identifiable {
    let name: String
    let signal: ProcessSignal
    let identities: [ProcessIdentity]

    var id: String { "\(signal):\(identities.map { $0.pid })" }
    var title: String {
        AppResources.formatted(
            "process.action.title",
            fallback: "%@ %@?",
            AppResources.localized(signal == .forceKill ? "Force Quit" : "Quit"),
            name
        )
    }
    var buttonTitle: String {
        AppResources.localized(signal == .forceKill ? "Force Quit" : "Quit")
    }
    var message: String {
        ProcessActionPolicy.confirmationMessage(name: name, signal: signal, identities: identities)
    }
}
