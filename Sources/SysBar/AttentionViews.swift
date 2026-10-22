import SwiftUI

// MARK: - Status strip

/// The top of the popover: one plain-language line about whether anything
/// needs attention. Line two is always SysBar's own measurement.
struct StatusStrip: View {
    let headline: String
    let detail: String
    let needsAttention: Bool
    let isExpanded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .font(.body)
                .foregroundStyle(needsAttention ? Color.sbWarning : Color.secondary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            HealthBriefDisclosureIndicator(isExpanded: isExpanded)
                .frame(height: 20)
        }
        .padding(.horizontal, TrackLayout.gutter)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(needsAttention ? Color.sbWarning.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .hoverHighlight(radius: 0)
    }
}

// MARK: - Brief card

/// One attention item, action first: what happened, one line of why, then
/// the one or two buttons SysBar can press for it. Everything else folds
/// under Details. Buttons are SysBar's catalog actions; the AI only picks
/// which ones and says what each costs.
struct AttentionBriefCard: View {
    let entry: AttentionModel.Entry
    let model: AttentionModel
    let providerName: String
    let show: (FooterRoute) -> Void
    let turnOn: () -> Void

    @State private var showsDetails = false

    private var readyBrief: (AttentionBrief, AttentionModel.BriefMeta)? {
        if case let .ready(brief, meta) = entry.brief { return (brief, meta) }
        return nil
    }

    private var accent: Color {
        if entry.run?.phase == .done { return .secondary }
        guard let (brief, _) = readyBrief else { return .sbWarning }
        return brief.verdict == .attention ? .sbWarning : .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent)
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                header
                why
                // A failure reads before its way out; progress reads after
                // the button that started it.
                if entry.run?.phase == .failed {
                    statusLine
                    buttonRow
                } else {
                    if entry.run?.phase != .done {
                        buttonRow
                    }
                    statusLine
                }
                if entry.run?.phase != .done {
                    footer
                }
                if showsDetails, let (brief, _) = readyBrief {
                    details(brief)
                }
                if let (brief, meta) = readyBrief {
                    Text(Self.provenance(brief, meta))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PanelCard.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(readyBrief?.0.headline ?? entry.item.fact.text)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(readyBrief?.0.headline ?? entry.item.fact.text)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                Button { model.dismiss(entry.id) } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(AppResources.localized("brief.dismiss", fallback: "Dismiss"))
                .accessibilityLabel(AppResources.localized("brief.dismiss", fallback: "Dismiss"))
            }
            Text(measuredLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(AppResources.formatted("brief.measured.label", fallback: "Measured: %@", measuredLine))
        }
    }

    /// SysBar's own numbers. With an AI headline, the fact; without one the
    /// headline already is the fact, so this says since when.
    private var measuredLine: String {
        if readyBrief != nil { return entry.item.fact.text }
        return AppResources.formatted(
            "brief.since",
            fallback: "Since %@",
            entry.item.raisedAt.formatted(date: .omitted, time: .shortened)
        )
    }

    @ViewBuilder
    private var why: some View {
        switch entry.brief {
        case .asking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(AppResources.formatted("brief.asking", fallback: "Asking %@…", providerName))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case let .ready(brief, _):
            Text(brief.why)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(error):
            Text(Self.failureText(error, providerName: providerName))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .paused:
            Text(AppResources.formatted(
                "brief.failure.paused",
                fallback: "%1$@ paused: %2$ld briefs in the last hour.",
                providerName,
                AttentionModel.maxCallsPerHour
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        case .waitingForData:
            Text(AppResources.localized("brief.waitingForData", fallback: "Waiting for current data"))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .providerOff:
            // The fact and the buttons stand on their own; the provider line
            // under the cards already offers to turn briefs on.
            EmptyView()
        }
    }

    /// The pressed button's follow-ups replace the plan once a quit failed or
    /// a fix did not take; otherwise the plan's one or two buttons.
    private var visibleActions: [AllowedAction] {
        if let run = entry.run, run.phase == .failed, !run.followUps.isEmpty { return run.followUps }
        return entry.plan.buttons.map(\.allowed)
    }

    private var buttonRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                buttons
                keepWatching
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { buttons }
                keepWatching
            }
            VStack(alignment: .leading, spacing: 6) {
                buttons
                keepWatching
            }
        }
    }

    /// After a failed quit or a fix that didn't take: leave things as they are.
    @ViewBuilder
    private var keepWatching: some View {
        if entry.run?.phase == .failed {
            Button(AppResources.localized("action.keepWatching", fallback: "Keep watching")) {
                model.clearRun(entry.id)
            }
            .buttonStyle(.link)
            .font(.caption)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        ForEach(visibleActions) { action in
            ActionButton(
                action: action,
                hint: reason(for: action),
                isRunning: entry.run?.isBusy == true && entry.run?.action == action,
                isDisabled: entry.run?.isBusy == true
            ) {
                model.perform(action, for: entry.id)
            }
        }
    }

    private func reason(for action: AllowedAction) -> String {
        entry.plan.buttons.first { $0.allowed == action }?.reason ?? ActionLabel.caption(action)
    }

    /// The pressed button's progress or result, or the first button's reason.
    @ViewBuilder
    private var statusLine: some View {
        if let run = entry.run {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // Progress shows on the pressed button itself.
                switch run.phase {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                case .failed:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.sbWarning)
                case .running, .checking, .info:
                    EmptyView()
                }
                Text(run.line)
                    .fixedSize(horizontal: false, vertical: true)
                if run.phase == .done, let undo = run.followUps.first {
                    Button(ActionLabel.title(undo)) { model.perform(undo, for: entry.id) }
                        .buttonStyle(.link)
                }

            }
            .font(.caption)
            .foregroundStyle(run.phase == .failed ? Color.primary : Color.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        } else if let first = entry.plan.buttons.first {
            Text(first.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Secondary links. When they don't fit on one line, the two "not now"
    /// choices fold into a More menu instead of wrapping.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                primaryLinks
                laterLinks
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                primaryLinks
                Spacer(minLength: 0)
                Menu {
                    laterLinks
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(AppResources.localized("brief.more", fallback: "More"))
                .help(AppResources.localized("brief.more", fallback: "More"))
            }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    @ViewBuilder
    private var primaryLinks: some View {
        if readyBrief != nil {
            Button {
                showsDetails.toggle()
            } label: {
                HStack(spacing: 2) {
                    Text(AppResources.localized("brief.details", fallback: "Details"))
                    Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .fixedSize()
            .accessibilityValue(AppResources.localized(showsDetails ? "Expanded" : "Collapsed"))
        }
        if let route = entry.plan.route {
            Button(Self.routeTitle(route)) { show(route) }
                .fixedSize()
        }
    }

    @ViewBuilder
    private var laterLinks: some View {
        if entry.plan.offersSnoozeLink {
            Button(ActionLabel.title(.snooze)) { model.snooze(entry.id) }
                .fixedSize()
        }
        Button(AppResources.localized("brief.muteToday", fallback: "Mute today")) { model.muteToday(entry.id) }
            .fixedSize()
    }

    private func details(_ brief: AttentionBrief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(brief.detail)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            labeled(AppResources.localized("brief.likelyCause", fallback: "Likely cause"), brief.likelyCause)
            if let step = brief.manualStep, !step.isEmpty {
                Text(AppResources.formatted("brief.manualStep", fallback: "Also: %@", step))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.canRefresh(entry.id) {
                Button(AppResources.localized("brief.refresh", fallback: "Refresh")) { model.refresh(entry.id) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.top, 2)
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    static func routeTitle(_ route: FooterRoute) -> String {
        switch route {
        case .topCPU: return AppResources.localized("brief.action.showTopCPU", fallback: "Show in Top CPU")
        case .topMemory: return AppResources.localized("brief.action.showTopMemory", fallback: "Show in Top Memory")
        case .network: return AppResources.localized("brief.action.showPorts", fallback: "Show in Network")
        }
    }

    static func provenance(_ brief: AttentionBrief, _ meta: AttentionModel.BriefMeta) -> String {
        var line = AppResources.formatted(
            "brief.provenance",
            fallback: "%1$@ · %2$@ · %3$@ confidence · %4$@",
            "\(meta.provider.shortName) · \(meta.model)",
            Duration.seconds(Int(meta.seconds.rounded())).formatted(.units(allowed: [.seconds], width: .narrow)),
            AppResources.localized("brief.confidence.\(brief.confidence.rawValue)", fallback: brief.confidence.rawValue),
            meta.date.formatted(date: .omitted, time: .shortened)
        )
        if brief.verdict == .unsure {
            line += " · " + AppResources.localized("brief.hint.suffix", fallback: "treat as a hint")
        }
        if meta.droppedPicks > 0 {
            line += " · " + AppResources.plural("brief.suggestionDropped", count: meta.droppedPicks)
        }
        return line
    }

    static func failureText(_ error: AIProviderError, providerName: String) -> String {
        switch error {
        case .notInstalled, .unverified:
            return AppResources.formatted(
                "brief.failure.notInstalled",
                fallback: "%@ isn't installed, or isn't the signed build. SysBar's own measurements are shown.",
                providerName
            )
        case .signInNeeded:
            return AppResources.formatted(
                "brief.failure.signIn",
                fallback: "Sign in to %@ in Terminal, then try again.",
                providerName
            )
        case .timedOut:
            return AppResources.formatted("brief.failure.timedOut", fallback: "%@ took too long. Try again.", providerName)
        case .busy:
            return AppResources.formatted("brief.failure.busy", fallback: "%@ is busy or over its limit right now.", providerName)
        case .invalidResponse:
            return AppResources.formatted("brief.failure.rejected", fallback: "%@'s answer didn't pass SysBar's checks.", providerName)
        case .failed, .cancelled:
            return AppResources.formatted("brief.failure.generic", fallback: "%@ couldn't answer. Try again.", providerName)
        }
    }
}

/// A catalog action as a button. Labels are SysBar's; the AI's reason is the
/// hint. Only an escalation (Force Quit) is drawn prominent.
struct ActionButton: View {
    let action: AllowedAction
    let hint: String
    let isRunning: Bool
    let isDisabled: Bool
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                if isRunning {
                    ProgressView().controlSize(.mini)
                }
                Text(ActionLabel.title(action))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .controlSize(.small)
        .disabled(isDisabled)
        .modifier(ProminentIfEscalation(isEscalation: action.action == .forceQuit))
        .help(hint)
        .accessibilityLabel(ActionLabel.title(action))
        .accessibilityHint(hint)
    }
}

private struct ProminentIfEscalation: ViewModifier {
    let isEscalation: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEscalation {
            content.buttonStyle(.borderedProminent).tint(.sbWarning)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

// MARK: - Review card

/// What the review card says first: a verdict that tells the user plainly
/// whether anything needs doing, the findings that need action, and the rest
/// folded under Details.
enum ReviewPresentation {
    static func title(_ review: ReviewBrief) -> String {
        switch review.overall {
        case .healthy:
            guard needsAction(review).isEmpty else {
                return AppResources.localized("review.title.healthy", fallback: "Healthy")
            }
            return AppResources.localized("review.title.nothingToDo", fallback: "Healthy · nothing to do")
        case .watch:
            return AppResources.localized("review.title.watch", fallback: "Worth watching")
        case .attention:
            return AppResources.localized("review.title.attention", fallback: "Needs attention")
        }
    }

    static func needsAction(_ review: ReviewBrief) -> [ReviewBrief.Finding] {
        review.findings.filter { $0.severity == .attention }
    }

    static func folded(_ review: ReviewBrief) -> [ReviewBrief.Finding] {
        review.findings.filter { $0.severity != .attention }
    }

    /// Where a finding's subject is in the popover, so every finding about a
    /// process or listener has somewhere to go.
    static func route(for subjectRef: String?) -> FooterRoute? {
        switch subjectRef?.first {
        case "p": return .topCPU
        case "m": return .topMemory
        case "l": return .network
        default: return nil
        }
    }
}

struct ReviewCard: View {
    let state: AttentionModel.ReviewState
    let providerName: String
    let show: (FooterRoute) -> Void
    let retry: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppResources.formatted("review.running", fallback: "%@ is reviewing your Mac…", providerName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case let .ready(review, meta):
                let folded = ReviewPresentation.folded(review)
                HStack(spacing: 6) {
                    Image(systemName: review.overall == .healthy ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(review.overall == .attention ? Color.sbWarning : Color.secondary)
                        .accessibilityHidden(true)
                    Text(ReviewPresentation.title(review))
                        .font(.headline)
                }
                Text(review.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(ReviewPresentation.needsAction(review).enumerated()), id: \.offset) { _, finding in
                    findingRow(finding, warns: true)
                }
                if !folded.isEmpty {
                    Button {
                        showsDetails.toggle()
                    } label: {
                        HStack(spacing: 2) {
                            Text(AppResources.localized("brief.details", fallback: "Details"))
                            Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityValue(AppResources.localized(showsDetails ? "Expanded" : "Collapsed"))
                    if showsDetails {
                        ForEach(Array(folded.enumerated()), id: \.offset) { _, finding in
                            findingRow(finding, warns: false)
                        }
                    }
                }
                Text("\(meta.provider.shortName) · \(meta.model) · \(meta.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case let .failed(error):
                Text(AttentionBriefCard.failureText(error, providerName: providerName))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(AppResources.localized("brief.tryAgain", fallback: "Try again"), action: retry)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PanelCard.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func findingRow(_ finding: ReviewBrief.Finding, warns: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if warns {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.sbWarning)
                            .accessibilityHidden(true)
                    }
                    Text(finding.title)
                        .font(.caption.weight(.semibold))
                }
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let route = ReviewPresentation.route(for: finding.subjectRef) {
                Button(AttentionBriefCard.routeTitle(route)) { show(route) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Provider switch

/// Off · Claude · Codex. A provider that isn't installed and signed by its
/// vendor stays visible but disabled, with its caption saying why.
struct AIProviderSwitch: View {
    @ObservedObject var model: AttentionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(AppResources.localized("provider.control.title", fallback: "AI briefs"))
                    .font(.body)
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    ForEach(AIProviderKind.allCases, id: \.self) { kind in
                        segment(kind)
                    }
                }
                .padding(2)
                .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                if !(model.statuses[.claude]?.isInstalled ?? false), !(model.statuses[.codex]?.isInstalled ?? false),
                   model.statuses.values.allSatisfy({ $0 != .checking }) {
                    Text(AppResources.localized("provider.none.installed", fallback: "Install Claude Code or Codex to get briefs"))
                } else {
                    ForEach([AIProviderKind.claude, .codex], id: \.self) { kind in
                        Text(AIProviderPolicy.caption(kind, status: model.statuses[kind] ?? .checking))
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 30)
        }
        .padding(.vertical, 4)
    }

    private func segment(_ kind: AIProviderKind) -> some View {
        let available = kind == .off || (model.statuses[kind]?.isInstalled ?? false)
        let selected = model.provider == kind
        return Button {
            model.setProvider(kind)
        } label: {
            Text(kind.shortName)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .foregroundStyle(selected ? Color.primary : (available ? Color.secondary : Color.secondary.opacity(0.5)))
                .background(
                    selected ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(kind == .off ? kind.displayName : AIProviderPolicy.caption(kind, status: model.statuses[kind] ?? .checking))
    }
}
