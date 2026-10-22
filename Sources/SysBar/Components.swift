import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Ledger icons, resolved from the outermost `.app` bundle that contains an
/// executable (so helpers show their app) and downsampled once to 16 pt @2x
/// so a few dozen cached icons cost kilobytes, not full icon families.
@MainActor
enum ProcessIconCache {
    static let side: CGFloat = 16
    private static let executableKey = "#unix-executable"
    private static var icons: [String: NSImage] = [:]

    static func icon(forExecutablePath path: String?) -> NSImage {
        let key = path.flatMap(ProcessIconPath.bundlePath(containing:)) ?? executableKey
        if let cached = icons[key] { return cached }
        let source = key != executableKey && FileManager.default.fileExists(atPath: key)
            ? NSWorkspace.shared.icon(forFile: key)
            : NSWorkspace.shared.icon(for: .unixExecutable)
        let image = downsampled(source)
        if icons.count >= 96 { icons.removeAll(keepingCapacity: true) }
        icons[key] = image
        return image
    }

    private static func downsampled(_ source: NSImage) -> NSImage {
        let size = NSSize(width: side, height: side)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(side) * 2,
            pixelsHigh: Int(side) * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return source }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

enum ProcessIconPath {
    /// The outermost `.app` bundle in an executable path, or nil for plain tools.
    static func bundlePath(containing executablePath: String) -> String? {
        var built: [String] = []
        for component in (executablePath as NSString).pathComponents {
            built.append(component)
            if component.hasSuffix(".app") {
                return NSString.path(withComponents: built)
            }
        }
        return nil
    }
}

struct ProcessIcon: View {
    let executablePath: String?

    var body: some View {
        Image(nsImage: ProcessIconCache.icon(forExecutablePath: executablePath))
            .resizable()
            .interpolation(.high)
            .frame(width: ProcessIconCache.side, height: ProcessIconCache.side)
            .accessibilityHidden(true)
    }
}

struct HoverHighlight: ViewModifier {
    let radius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        isHovered
                            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12)
                            : .clear
                    )
            }
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverHighlight(opacity: Double = 0.08, radius: CGFloat = 6) -> some View {
        // Keep the old call shape while using one restrained, semantic hover.
        modifier(HoverHighlight(radius: radius))
    }

    func panelCard(padding: CGFloat = 10) -> some View {
        modifier(PanelCard(padding: padding))
    }
}

/// One quiet surface for every grouped block in the popover, replacing
/// `GroupBox` so cards share a radius, fill and increased-contrast outline.
struct PanelCard: ViewModifier {
    static let cornerRadius: CGFloat = 10

    let padding: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            )
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
    }
}

/// Footer toggle that stays quiet when off and uses a tinted capsule when on,
/// instead of the filled accent button that read as a primary call to action.
struct FooterToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    configuration.isOn ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05),
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

struct HealthBadge: View {
    let severity: MetricSeverity
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: severity.systemImage)
                .foregroundStyle(severity.color)
                .accessibilityHidden(true)
            Text(AppResources.localized(severity.word))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay {
                if differentiateWithoutColor {
                    Capsule().strokeBorder(severity.color, lineWidth: 1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                AppResources.formatted(
                    "accessibility.status",
                    fallback: "Status: %@",
                    AppResources.localized(severity.word)
                )
            )
    }
}

struct StateMessageRow: View {
    let symbolName: String
    let title: String
    var detail: String? = nil
    var severity: MetricSeverity? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbolName)
                .font(.body)
                .foregroundStyle(severity?.color ?? Color.secondary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                        .frame(minHeight: 28)
                        .accessibilityLabel(
                            AppResources.formatted(
                                "state.action.accessibility",
                                fallback: "%@: %@",
                                actionTitle,
                                title
                            )
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

struct HealthBriefDisclosureIndicator: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

private struct OptionalIdentityAccessibilityActions: ViewModifier {
    let terminate: (() -> Void)?
    let forceKill: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        switch (terminate, forceKill) {
        case let (terminate?, forceKill?):
            content
                .accessibilityAction(named: Text(AppResources.localized("Quit Process")), terminate)
                .accessibilityAction(named: Text(AppResources.localized("Force Quit Process")), forceKill)
        case let (terminate?, nil):
            content.accessibilityAction(named: Text(AppResources.localized("Quit Process")), terminate)
        case let (nil, forceKill?):
            content.accessibilityAction(named: Text(AppResources.localized("Force Quit Process")), forceKill)
        case (nil, nil):
            content
        }
    }
}

struct ProcessRow: View, Equatable {
    let group: ProcessGroup
    let metric: MetricKind
    let value: Double
    let terminateAction: (([ProcessIdentity]) -> Void)?
    let forceKillAction: (([ProcessIdentity]) -> Void)?
    private let offersTerminate: Bool
    private let offersForceKill: Bool

    init(
        group: ProcessGroup,
        metric: MetricKind,
        value: Double,
        terminateAction: (([ProcessIdentity]) -> Void)? = nil,
        forceKillAction: (([ProcessIdentity]) -> Void)? = nil
    ) {
        self.group = group
        self.metric = metric
        self.value = value
        self.terminateAction = terminateAction
        self.forceKillAction = forceKillAction
        offersTerminate = terminateAction != nil
        offersForceKill = forceKillAction != nil
    }

    /// The action closures are rebuilt on every panel render; only whether a
    /// row offers them changes what it shows. Unchanged rows skip their body.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group
            && lhs.metric == rhs.metric
            && lhs.value == rhs.value
            && lhs.offersTerminate == rhs.offersTerminate
            && lhs.offersForceKill == rhs.offersForceKill
    }

    private var identities: [ProcessIdentity]? {
        group.isActionable ? group.expectedIdentities : nil
    }

    private var terminate: (() -> Void)? {
        guard let identities, let terminateAction else { return nil }
        return { terminateAction(identities) }
    }

    private var forceKill: (() -> Void)? {
        guard let identities, let forceKillAction else { return nil }
        return { forceKillAction(identities) }
    }

    var body: some View {
        // One line per group: sort order already ranks the rows, so a per-row
        // bar scaled to the top entry only made a 0.9% process look maxed out.
        HStack(spacing: 8) {
            ProcessIcon(executablePath: group.executablePath)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(group.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if group.count > 1 {
                    Text(
                        AppResources.formatted(
                            "process.count.badge",
                            fallback: "×%@",
                            group.count.formatted()
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(
                            AppResources.plural("processes.count", count: group.count)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(metric.format(value.isFinite ? max(0, value) : 0))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)

            Menu {
                actionMenu
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(0.6)
            .help(
                AppResources.formatted(
                    "actions.process",
                    fallback: "Actions for %@",
                    group.name
                )
            )
            .accessibilityLabel(
                AppResources.formatted(
                    "actions.process",
                    fallback: "Actions for %@",
                    group.name
                )
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .hoverHighlight()
        .help(
            AppResources.formatted(
                "process.help",
                fallback: "%@ — %@",
                group.name,
                AppResources.plural("processes.count", count: group.count)
            )
        )
        .contextMenu { actionMenu }
        .modifier(OptionalIdentityAccessibilityActions(terminate: terminate, forceKill: forceKill))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionMenu: some View {
        Button(AppResources.localized("Copy Process IDs")) {
            Pasteboard.copy(group.pids.map(String.init).joined(separator: " "))
        }
        if let path = group.executablePath {
            Button(AppResources.localized("Copy Executable Path")) { Pasteboard.copy(path) }
        }
        Button(AppResources.localized("Open Activity Monitor")) {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
            )
        }
        if let terminate {
            Divider()
            Button(AppResources.localized("Quit Process"), action: terminate)
        }
        if let forceKill {
            Button(AppResources.localized("Force Quit Process"), role: .destructive, action: forceKill)
        }
    }
}

enum ListenerScope: String, CaseIterable {
    case all
    case lan
    case local

    var title: String {
        switch self {
        case .all: return "All"
        case .lan: return "Network"
        case .local: return "This Mac"
        }
    }

    func includes(_ listener: ListenSocket) -> Bool {
        switch self {
        case .all: return true
        case .lan: return listener.exposure != .local
        case .local: return listener.exposure == .local
        }
    }
}

enum ListenerListPresentation {
    static func filtered(
        _ listeners: [ListenSocket],
        query: String,
        scope: ListenerScope
    ) -> [ListenSocket] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return listeners.filter { listener in
            guard scope.includes(listener) else { return false }
            guard !terms.isEmpty else { return true }
            let searchableText = [
                listener.processName,
                String(listener.pid),
                listener.isTCP ? "TCP" : "UDP",
                PortDisplayText.address(bindAddress: listener.bindAddress, port: listener.port)
            ].joined(separator: " ")
            return terms.allSatisfy { searchableText.localizedStandardContains($0) }
        }
    }
}

struct ListenerList: View, Equatable {
    let ports: [ListenSocket]
    let resetRequest: Int
    let searchFocusRequest: Int
    let trustedKeys: Set<ListenerEndpointKey>
    let executablePaths: [Int32: String]
    let terminateAction: ((ListenSocket, ProcessIdentity) -> Void)?
    let forceKillAction: ((ListenSocket, ProcessIdentity) -> Void)?
    private let offersTerminate: Bool
    private let offersForceKill: Bool
    @State private var query = ""
    @State private var scope: ListenerScope = .all
    @FocusState private var searchFocused: Bool

    init(
        ports: [ListenSocket],
        resetRequest: Int,
        searchFocusRequest: Int = 0,
        trustedKeys: Set<ListenerEndpointKey> = [],
        executablePaths: [Int32: String] = [:],
        terminateAction: ((ListenSocket, ProcessIdentity) -> Void)? = nil,
        forceKillAction: ((ListenSocket, ProcessIdentity) -> Void)? = nil
    ) {
        self.ports = ports
        self.resetRequest = resetRequest
        self.searchFocusRequest = searchFocusRequest
        self.trustedKeys = trustedKeys
        self.executablePaths = executablePaths
        self.terminateAction = terminateAction
        self.forceKillAction = forceKillAction
        offersTerminate = terminateAction != nil
        offersForceKill = forceKillAction != nil
    }

    /// Ports change on a 15-second scan, not every tick. The closures are
    /// rebuilt on every render, so only whether they exist is compared.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ports == rhs.ports
            && lhs.resetRequest == rhs.resetRequest
            && lhs.searchFocusRequest == rhs.searchFocusRequest
            && lhs.trustedKeys == rhs.trustedKeys
            && lhs.executablePaths == rhs.executablePaths
            && lhs.offersTerminate == rhs.offersTerminate
            && lhs.offersForceKill == rhs.offersForceKill
    }

    var body: some View {
        let visiblePorts = ListenerListPresentation.filtered(ports, query: query, scope: scope)
        VStack(alignment: .leading, spacing: 8) {
            searchField
            Picker(AppResources.localized("Listener scope"), selection: $scope) {
                ForEach(ListenerScope.allCases, id: \.self) { scope in
                    Text(AppResources.localized(scope.title)).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(AppResources.localized("Listener scope"))
            .help(AppResources.localized("Network shows apps other devices can reach."))

            if !query.isEmpty || scope != .all {
                Text(
                    AppResources.formatted(
                        "listeners.filtered.count",
                        fallback: "Showing %@ of %@ listeners",
                        visiblePorts.count.formatted(),
                        ports.count.formatted()
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if ports.isEmpty {
                EmptyStateRow(icon: "checkmark.shield", message: "No listening ports detected", tint: .secondary)
            } else if visiblePorts.isEmpty {
                StateMessageRow(
                    symbolName: "magnifyingglass",
                    title: AppResources.localized("No matching listeners"),
                    detail: AppResources.localized("Try a process name, PID, port, or address."),
                    actionTitle: AppResources.localized("Clear filters"),
                    action: resetFilters
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(visiblePorts) { port in
                        PortRow(
                            port: port,
                            isTrustedSystemService: trustedKeys.contains(port.endpointKey),
                            executablePath: executablePaths[port.pid],
                            terminateAction: terminateAction.map { action in
                                { identity in action(port, identity) }
                            },
                            forceKillAction: forceKillAction.map { action in
                                { identity in action(port, identity) }
                            }
                        )
                    }
                }
            }
        }
        .onChange(of: resetRequest) { _ in resetFilters() }
        .task(id: searchFocusRequest) {
            guard searchFocusRequest > 0 else { return }
            // Let the section finish expanding before moving focus into it.
            try? await Task.sleep(nanoseconds: 50_000_000)
            searchFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(AppResources.localized("Search name, PID, port…"), text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel(AppResources.localized("Search listening ports"))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(AppResources.localized("Clear search"))
                .accessibilityLabel(AppResources.localized("Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private func resetFilters() {
        query = ""
        scope = .all
    }
}

struct PortRow: View {
    let port: ListenSocket
    var isTrustedSystemService = false
    var executablePath: String? = nil
    var terminateAction: ((ProcessIdentity) -> Void)? = nil
    var forceKillAction: ((ProcessIdentity) -> Void)? = nil

    private var isFlagged: Bool { port.exposure == .actionableLAN && !isTrustedSystemService }

    private var exposureTitle: String {
        switch port.exposure {
        case .local: return AppResources.localized("This Mac only")
        case .lanReachable: return AppResources.localized("Discovery")
        case .actionableLAN:
            return AppResources.localized(isTrustedSystemService ? "macOS service" : "Open to network")
        }
    }

    private var exposureSymbol: String {
        switch port.exposure {
        case .local: return "lock.fill"
        case .lanReachable: return "wifi"
        case .actionableLAN: return isTrustedSystemService ? "checkmark.shield" : "wifi.exclamationmark"
        }
    }

    private var terminate: (() -> Void)? {
        guard let identity = port.processIdentity, let terminateAction else { return nil }
        return { terminateAction(identity) }
    }

    private var forceKill: (() -> Void)? {
        guard let identity = port.processIdentity, let forceKillAction else { return nil }
        return { forceKillAction(identity) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(port.port))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 44, alignment: .leading)
                    ProcessIcon(executablePath: port.processIdentity?.executablePath ?? executablePath)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    Text(port.processName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Label(exposureTitle, systemImage: exposureSymbol)
                        .font(.caption.weight(isFlagged ? .semibold : .regular))
                        .foregroundStyle(isFlagged ? .sbWarning : .secondary)
                        .fixedSize()
                }
                Text(
                    PortDisplayText.endpoint(
                        transport: AppResources.localized(port.isTCP ? "TCP" : "UDP"),
                        bindAddress: port.bindAddress,
                        port: port.port
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                actionMenu
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(0.6)
            .help(PortDisplayText.actionLabel(port: port.port))
            .accessibilityLabel(PortDisplayText.actionLabel(port: port.port))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .hoverHighlight()
        .help(
            PortDisplayText.help(
                processName: port.processName,
                pid: port.pid,
                bindAddress: port.bindAddress,
                port: port.port
            )
        )
        .contextMenu { actionMenu }
        .modifier(OptionalIdentityAccessibilityActions(terminate: terminate, forceKill: forceKill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            PortDisplayText.accessibilityLabel(port: port.port, processName: port.processName)
        )
        .accessibilityValue(
            AppResources.formatted(
                "port.accessibility.value",
                fallback: "%@, %@",
                AppResources.localized(port.isTCP ? "TCP" : "UDP"),
                exposureTitle
            )
        )
    }

    @ViewBuilder
    private var actionMenu: some View {
        Button(AppResources.localized("Copy Port")) { Pasteboard.copy(String(port.port)) }
        Button(AppResources.localized("Copy Address")) {
            Pasteboard.copy(PortDisplayText.address(bindAddress: port.bindAddress, port: port.port))
        }
        Button(AppResources.localized("Copy lsof Command")) { Pasteboard.copy("lsof -i :\(port.port)") }
        if port.isTCP {
            Button(AppResources.localized("Open Local Web Service")) {
                if let url = URL(string: "http://localhost:\(port.port)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        if let terminate {
            Divider()
            Button(AppResources.localized("Quit Process"), action: terminate)
        }
        if let forceKill {
            Button(AppResources.localized("Force Quit Process"), role: .destructive, action: forceKill)
        }
    }
}

struct EmptyStateRow: View {
    let icon: String
    let message: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(AppResources.localized(message))
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .frame(minHeight: 32)
    }
}

struct CollapsibleSection<Content: View>: View {
    let title: String
    let count: Int?
    let expansionRequest: Int
    let requiresAttention: Bool
    @AppStorage private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        key: SectionKey,
        count: Int? = nil,
        defaultExpanded: Bool? = nil,
        expansionRequest: Int = 0,
        requiresAttention: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.count = count
        self.expansionRequest = expansionRequest
        self.requiresAttention = requiresAttention
        _expanded = AppStorage(
            wrappedValue: defaultExpanded ?? key.defaultExpanded,
            key.rawValue
        )
        self.content = content
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                content()
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(AppResources.localized(title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                if let count, count > 0 {
                    Text(count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(AppResources.plural("items.count", count: count))
                }
                Spacer()
                if requiresAttention {
                    HealthBadge(severity: .warning)
                }
            }
            // The whole header row toggles, not only the disclosure arrow.
            // DisclosureGroup still provides the expand/collapse semantics for
            // VoiceOver and the keyboard.
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
        }
        .onChange(of: expansionRequest) { request in
            if request > 0 {
                expanded = true
            }
        }
        .onChange(of: requiresAttention) { needsAttention in
            if needsAttention { expanded = true }
        }
        .onAppear {
            if requiresAttention { expanded = true }
        }
    }

    private func toggle() {
        if reduceMotion {
            expanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        }
    }
}

// MARK: - Seismograph lanes

enum LaneState: Equatable {
    case loading(String)
    case unavailable(String)
    case empty(String)
    case value(MetricPresentation, detail: String?, isStale: Bool)
}

/// The four seismograph lanes, named for the condition each one watches.
enum HealthConditionID: Equatable, Sendable {
    case cpuHigh
    case memoryLow
    case swapInUse
    case storageLow
}

struct MetricLaneContent: Equatable {
    let id: HealthConditionID
    let title: String
    let symbolName: String
    let isPrimary: Bool
    let state: LaneState
    /// Fractions of capacity used, oldest first.
    let samples: [Double]
    /// Draw the latest sample as a flat level (no history exists, e.g. disk).
    let isLevel: Bool
    let thresholds: ThresholdLines

    var presentation: MetricPresentation? {
        if case let .value(presentation, _, _) = state { return presentation }
        return nil
    }

    var isStale: Bool {
        if case let .value(_, _, isStale) = state { return isStale }
        return false
    }
}

/// One channel of the instrument: label, a large numeral and its detail on the
/// leading column, the recorded trace on the trailing column. Healthy lanes are
/// monochrome ink; only warning and critical lanes take a color.
struct MetricLane: View {
    let content: MetricLaneContent
    let scrub: TraceScrubModel
    var isSelectable = false
    var isSelected = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .largeTitle) private var primaryNumeralSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title2) private var secondaryNumeralSize: CGFloat = 22

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    summary
                    traceArea
                        .frame(height: TrackLayout.accessibilityTraceHeight)
                }
                .padding(.vertical, 8)
            } else {
                HStack(alignment: .center, spacing: 0) {
                    summary
                        .frame(width: TrackLayout.leadingColumnWidth, alignment: .leading)
                        .padding(.vertical, 6)
                        .frame(
                            minHeight: content.isPrimary
                                ? TrackLayout.primaryLaneHeight
                                : TrackLayout.secondaryLaneHeight
                        )
                    traceArea
                        .frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, TrackLayout.gutter)
        .background { selectionBackground }
        .contentShape(Rectangle())
    }

    private var severity: MetricSeverity { content.presentation?.severity ?? .normal }

    private var labelSymbol: String {
        switch content.state {
        case .unavailable: return "exclamationmark.octagon.fill"
        case .loading, .empty: return content.symbolName
        case .value:
            if content.isStale { return "clock.badge.exclamationmark" }
            return severity == .normal ? content.symbolName : severity.systemImage
        }
    }

    private var accentColor: Color? {
        switch content.state {
        case .unavailable: return .sbDanger
        case .loading, .empty: return nil
        case .value:
            if content.isStale { return .sbWarning }
            return severity == .normal ? nil : severity.color
        }
    }

    private var numeral: (value: String, unit: String?) {
        guard let presentation = content.presentation else { return ("—", nil) }
        return (presentation.value, AppResources.localized(presentation.unit))
    }

    private var detail: String? {
        if case let .value(_, detail, _) = content.state { return detail }
        return nil
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: labelSymbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accentColor ?? Color.secondary)
                Text(content.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor ?? Color.secondary)
                    .lineLimit(1)
                if isSelectable {
                    HealthBriefDisclosureIndicator(isExpanded: isSelected)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: numeral.unit == "%" ? 1 : 3) {
                Text(numeral.value)
                    .font(
                        .system(
                            size: content.isPrimary ? primaryNumeralSize : secondaryNumeralSize,
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .monospacedDigit()
                    .foregroundStyle(
                        content.isStale || content.presentation == nil
                            ? Color.secondary
                            : (accentColor ?? Color.primary)
                    )
                if let unit = numeral.unit {
                    Text(unit)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            // Numerals update in place: a rolling-digit transition blurs on the
            // CPU every frame of every sample, which a monitor cannot afford.

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .help(detail)
            }
        }
    }

    @ViewBuilder
    private var traceArea: some View {
        switch content.state {
        case let .loading(title):
            // Blank instrument paper keeps the lane's shape while it waits.
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TraceBackdrop(thresholds: .none, hatchColor: nil))
        case let .unavailable(message), let .empty(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(TraceBackdrop(thresholds: .none, hatchColor: nil))
        case let .value(presentation, _, isStale):
            TracePlot(
                samples: content.samples,
                isLevel: content.isLevel,
                thresholds: content.thresholds,
                severity: presentation.severity,
                isStale: isStale,
                scrub: scrub
            )
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.5)
                    }
                }
                .padding(.horizontal, 8)
        }
    }
}

/// The axis under the hero: when the traces were last fed, and either the
/// window length or the age of the scrubbed sample.
struct TraceAxisRow: View {
    @ObservedObject var scrub: TraceScrubModel
    let updated: String?

    var body: some View {
        HStack(spacing: 8) {
            if let updated {
                Text(updated)
            }
            Spacer(minLength: 8)
            Text(scrub.stepsBack.map(TraceText.ageText(stepsBack:)) ?? TraceText.windowText)
                .foregroundStyle(scrub.stepsBack == nil ? .tertiary : .secondary)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .padding(.horizontal, TrackLayout.gutter)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Freshness strip

/// One line that appears only when telemetry is loading, delayed or missing,
/// replacing the per-card "Update delayed" rows.
struct FreshnessStrip: View {
    let health: PanelHealthPresentation
    let detail: String?
    let retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if health == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: health.symbolName)
                        .foregroundStyle(health.severity.color)
                }
            }
            .frame(width: 20)
            .accessibilityHidden(true)

            HStack(spacing: 6) {
                Text(AppResources.localized(health.title))
                    .fontWeight(.semibold)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .truncationMode(.tail)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .help(detail ?? AppResources.localized(health.title))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                AppResources.formatted(
                    "accessibility.collection.status",
                    fallback: "Collection status: %@",
                    AppResources.localized(health.title)
                )
            )
            .accessibilityValue(detail ?? "")

            Spacer(minLength: 4)
            if let retry {
                Button(AppResources.localized("Retry"), action: retry)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, TrackLayout.gutter)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(health.severity.color.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}
