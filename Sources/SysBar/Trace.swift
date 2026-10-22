import Accessibility
import AppKit
import QuartzCore
import SwiftUI

/// Hero geometry shared by every lane so all traces read on one time axis.
enum TrackLayout {
    static let gutter: CGFloat = 16
    static let leadingColumnWidth: CGFloat = 116
    static let primaryLaneHeight: CGFloat = 68
    static let secondaryLaneHeight: CGFloat = 54
    static let accessibilityTraceHeight: CGFloat = 56
    /// The plotted line keeps this distance from the lane edges; grid lines
    /// still span the full lane so adjacent lanes read as one instrument.
    static let traceVerticalInset: CGFloat = 6
    /// Keeps the "now" dot unclipped on the trailing edge.
    static let nowInset: CGFloat = 4
    static let capacity = monitorHistoryCapacity
    static let cadence = monitorRefreshSeconds
    /// One minute of samples; the grid draws a hairline every minute.
    static var minuteSlots: Int { max(1, Int((60 / cadence).rounded())) }
    static var windowMinutes: Int { max(1, Int((Double(capacity) * cadence / 60).rounded())) }
}

/// Pure mapping between samples, time and trace coordinates.
enum TraceGeometry {
    static func slot(width: CGFloat, capacity: Int = TrackLayout.capacity) -> CGFloat {
        width / CGFloat(max(1, capacity - 1))
    }

    /// The newest sample sits on the trailing edge; shorter histories leave
    /// the leading edge empty instead of stretching time.
    static func x(stepsBack: Int, width: CGFloat, capacity: Int = TrackLayout.capacity) -> CGFloat {
        width - CGFloat(max(0, stepsBack)) * slot(width: width, capacity: capacity)
    }

    static func stepsBack(forX x: CGFloat, width: CGFloat, capacity: Int = TrackLayout.capacity) -> Int {
        guard width > 0, x.isFinite else { return 0 }
        let raw = ((width - x) / slot(width: width, capacity: capacity)).rounded()
        guard raw.isFinite else { return 0 }
        return min(capacity - 1, max(0, Int(raw)))
    }

    static func age(stepsBack: Int, cadence: TimeInterval = TrackLayout.cadence) -> TimeInterval {
        TimeInterval(max(0, stepsBack)) * cadence
    }

    static func fraction(percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(1, max(0, percent / 100))
    }

    /// The sample `stepsBack` slots before the newest one, or nil before history began.
    static func sample(stepsBack: Int, in samples: [Double]) -> Double? {
        let index = samples.count - 1 - stepsBack
        guard stepsBack >= 0, samples.indices.contains(index) else { return nil }
        return samples[index]
    }

    static func y(fraction: Double, height: CGFloat, inset: CGFloat = TrackLayout.traceVerticalInset) -> CGFloat {
        let bounded = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let usable = max(1, height - inset * 2)
        return height - inset - CGFloat(bounded) * usable
    }
}

/// Warning and critical levels expressed as fractions of capacity used, so
/// they can be drawn on the same scale as the trace.
struct ThresholdLines: Equatable, Sendable {
    let warning: Double?
    let critical: Double?

    static let none = ThresholdLines(warning: nil, critical: nil)
}

enum MetricThresholdLines {
    static let cpu = ThresholdLines(
        warning: Thresholds.cpuWarn / 100,
        critical: Thresholds.cpuDanger / 100
    )

    /// Mirrors `MetricPresentation.memory`: warning at the larger of 2 GB or
    /// 15 % of RAM available, critical at 1 GB available.
    static func memory(totalGB: Double) -> ThresholdLines {
        let totalMB = totalGB * 1_024
        guard totalMB.isFinite, totalMB > 0 else { return .none }
        let warningAvailableMB = max(2_048, totalMB * 0.15)
        return ThresholdLines(
            warning: usedFraction(availableOrFree: warningAvailableMB, total: totalMB),
            critical: usedFraction(availableOrFree: Double(Thresholds.memCriticalMB), total: totalMB)
        )
    }

    static func swap(totalMB: Double) -> ThresholdLines {
        guard totalMB.isFinite, totalMB > 0 else { return .none }
        return ThresholdLines(warning: min(1, Double(Thresholds.swapWarnMB) / totalMB), critical: nil)
    }

    static func disk(totalGB: Double) -> ThresholdLines {
        guard totalGB.isFinite, totalGB > 0 else { return .none }
        return ThresholdLines(
            warning: usedFraction(availableOrFree: Thresholds.diskLowGB, total: totalGB),
            critical: usedFraction(availableOrFree: Thresholds.diskCriticalGB, total: totalGB)
        )
    }

    private static func usedFraction(availableOrFree: Double, total: Double) -> Double {
        min(1, max(0, 1 - availableOrFree / total))
    }
}

/// Shared scrub cursor. Kept out of the panel view so pointer movement only
/// redraws the cursor overlays, not the traces or the rest of the popover.
@MainActor
final class TraceScrubModel: ObservableObject {
    @Published private(set) var stepsBack: Int?

    /// Publishes only when the cursor moves to a different sample, so pointer
    /// movement within one slot redraws nothing.
    func scrub(to newValue: Int?) {
        let bounded = newValue.map { min(TrackLayout.capacity - 1, max(0, $0)) }
        guard bounded != stepsBack else { return }
        stepsBack = bounded
    }

    func step(by delta: Int) {
        scrub(to: (stepsBack ?? 0) + delta)
    }
}

enum TraceText {
    /// Scrubbing redraws the axis caption on every sample the pointer crosses.
    /// There are only `capacity` distinct ages, so they are formatted once.
    private static let ageTexts = (0..<TrackLayout.capacity).map(makeAgeText(stepsBack:))

    static func ageText(stepsBack: Int) -> String {
        ageTexts.indices.contains(stepsBack) ? ageTexts[stepsBack] : makeAgeText(stepsBack: stepsBack)
    }

    static let windowText = AppResources.plural("trace.window.minutes", count: TrackLayout.windowMinutes)

    private static func makeAgeText(stepsBack: Int) -> String {
        guard stepsBack > 0 else { return AppResources.localized("Now") }
        let seconds = Int(TraceGeometry.age(stepsBack: stepsBack))
        let clock = Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
        return AppResources.formatted("trace.scrub.age", fallback: "%@ ago", clock)
    }
}

/// One lane's trace: grid, thresholds, hatch, the inked history and the now dot.
struct TracePlot: View {
    let samples: [Double]
    let isLevel: Bool
    let thresholds: ThresholdLines
    let severity: MetricSeverity
    let isStale: Bool
    let scrub: TraceScrubModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var tone: TraceTone {
        if isStale { return .stale }
        switch severity {
        case .normal: return .ink
        case .warning: return .warning
        case .critical: return .critical
        }
    }

    private var tint: Color {
        if isStale { return Color.primary.opacity(0.5) }
        if severity != .normal { return severity.color }
        return Color.primary.opacity(contrast == .increased ? 1 : 0.85)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let plotWidth = max(1, size.width - TrackLayout.nowInset)
            ZStack(alignment: .topLeading) {
                TraceBackdrop(
                    thresholds: thresholds,
                    hatchColor: severity != .normal && !isStale ? severity.color : nil
                )
                .equatable()

                // The line, its fill and the now dot slide together as one
                // Core Animation layer tree, so the right edge never jumps.
                TraceInk(
                    samples: samples,
                    isLevel: isLevel,
                    tone: tone,
                    increasedContrast: contrast == .increased,
                    animatesFeed: !reduceMotion
                )
                .frame(width: size.width, height: size.height)

                TraceScrubOverlay(
                    scrub: scrub,
                    samples: samples,
                    isLevel: isLevel,
                    tint: tint,
                    plotWidth: plotWidth,
                    height: size.height
                )
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { hover in
                switch hover {
                case let .active(location):
                    scrub.scrub(to: TraceGeometry.stepsBack(forX: location.x, width: plotWidth))
                case .ended:
                    scrub.scrub(to: nil)
                }
            }
        }
        .accessibilityHidden(true)
    }

}

enum TraceTone: Equatable {
    case ink
    case warning
    case critical
    case stale
}

/// The inked trace, drawn with Core Animation shape layers. A new sample
/// rebuilds two paths once; the paper-feed slide is a layer translation run by
/// the render server, so animation frames cost the app no CPU.
struct TraceInk: NSViewRepresentable {
    let samples: [Double]
    let isLevel: Bool
    let tone: TraceTone
    let increasedContrast: Bool
    let animatesFeed: Bool

    func makeNSView(context: Context) -> TraceInkView {
        TraceInkView()
    }

    func updateNSView(_ view: TraceInkView, context: Context) {
        view.update(
            samples: samples,
            isLevel: isLevel,
            tone: tone,
            increasedContrast: increasedContrast,
            animatesFeed: animatesFeed
        )
    }
}

final class TraceInkView: NSView {
    /// Clips the ink at the now line; the dot sits on that line, unclipped.
    private let clip = CALayer()
    private let paper = CALayer()
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let stroke = CAShapeLayer()
    private let dot = CAShapeLayer()

    private var samples: [Double] = []
    private var drawn: [Double] = []
    private var isLevel = false
    private var tone: TraceTone = .ink
    private var increasedContrast = false
    private var drawnSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.masksToBounds = false
        clip.masksToBounds = true
        root.addSublayer(clip)
        clip.addSublayer(paper)
        paper.addSublayer(fill)
        paper.addSublayer(stroke)
        root.addSublayer(dot)
        fill.mask = fillMask
        fill.startPoint = CGPoint(x: 0.5, y: 1)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        stroke.fillColor = nil
        stroke.lineWidth = 1.5
        stroke.lineJoin = .round
        stroke.lineCap = .round
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Purely visual: pointer events belong to the SwiftUI scrubber above.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != drawnSize else { return }
        redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private var plotWidth: CGFloat { max(1, bounds.width - TrackLayout.nowInset) }

    func update(
        samples newSamples: [Double],
        isLevel: Bool,
        tone: TraceTone,
        increasedContrast: Bool,
        animatesFeed: Bool
    ) {
        let styleChanged = tone != self.tone
            || increasedContrast != self.increasedContrast
            || isLevel != self.isLevel
        let feed = isLevel ? nil : TraceFeed.oneStep(from: samples, to: newSamples)
        let dataChanged = newSamples != samples
        let previousDotY = samples.last.map(dotY(for:))
        self.isLevel = isLevel
        self.tone = tone
        self.increasedContrast = increasedContrast
        if dataChanged {
            samples = newSamples
            drawn = feed ?? newSamples
        }
        if styleChanged { applyColors() }
        guard dataChanged || styleChanged else { return }
        redraw()

        guard dataChanged, animatesFeed, feed != nil, bounds.width > 0 else { return }
        let timing = CAMediaTimingFunction(name: .easeOut)
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = TraceGeometry.slot(width: plotWidth)
        slide.toValue = 0
        slide.duration = 0.24
        slide.timingFunction = timing
        paper.add(slide, forKey: "feed")
        // The line crosses the now line along its last segment; moving the dot
        // vertically with the same curve keeps it exactly on that crossing.
        if let previousDotY, let last = newSamples.last {
            let glide = CABasicAnimation(keyPath: "position.y")
            glide.fromValue = previousDotY
            glide.toValue = dotY(for: last)
            glide.duration = 0.24
            glide.timingFunction = timing
            dot.add(glide, forKey: "feed")
        }
    }

    /// Layer space is unflipped (origin bottom-left), so heights are measured up.
    private func dotY(for fraction: Double) -> CGFloat {
        bounds.height - TraceGeometry.y(fraction: fraction, height: bounds.height)
    }

    private func redraw() {
        drawnSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let plot = CGRect(x: 0, y: 0, width: plotWidth, height: bounds.height)
        clip.frame = plot
        paper.frame = plot
        fill.frame = plot
        fillMask.frame = plot
        stroke.frame = plot
        stroke.path = path(closed: false)
        fillMask.path = tone == .stale ? nil : path(closed: true)
        fill.isHidden = tone == .stale
        if let last = samples.last {
            let diameter: CGFloat = tone == .ink ? 5 : 7
            dot.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            dot.path = CGPath(ellipseIn: dot.bounds.insetBy(dx: tone == .stale ? 0.6 : 0, dy: tone == .stale ? 0.6 : 0), transform: nil)
            dot.position = CGPoint(x: plotWidth, y: dotY(for: last))
            dot.isHidden = false
        } else {
            dot.isHidden = true
        }
        CATransaction.commit()
        applyColors()
    }

    private func path(closed: Bool) -> CGPath? {
        let size = CGSize(width: plotWidth, height: bounds.height)
        guard size.width > 0, size.height > 0 else { return nil }
        let inset = TrackLayout.traceVerticalInset
        func y(_ fraction: Double) -> CGFloat {
            size.height - TraceGeometry.y(fraction: fraction, height: size.height, inset: inset)
        }
        let points: [CGPoint]
        if isLevel {
            guard let value = drawn.last else { return nil }
            points = [CGPoint(x: 0, y: y(value)), CGPoint(x: size.width, y: y(value))]
        } else {
            let slot = TraceGeometry.slot(width: size.width)
            let count = drawn.count
            points = drawn.enumerated().map { index, value in
                CGPoint(x: size.width - CGFloat(count - 1 - index) * slot, y: y(value))
            }
        }
        guard let first = points.first, let last = points.last, points.count > 1 || closed else { return nil }
        let path = CGMutablePath()
        if closed {
            // `addLines(between:)` would start a new subpath; extend this one.
            path.move(to: CGPoint(x: first.x, y: inset))
            points.forEach { path.addLine(to: $0) }
            path.addLine(to: CGPoint(x: last.x, y: inset))
            path.closeSubpath()
        } else {
            path.addLines(between: points)
        }
        return path
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let tint: NSColor
            switch tone {
            case .ink: tint = NSColor.labelColor.withAlphaComponent(increasedContrast ? 1 : 0.85)
            case .stale: tint = NSColor.labelColor.withAlphaComponent(0.5)
            case .warning: tint = .systemOrange
            case .critical: tint = .systemRed
            }
            let fillTop = tone == .ink ? 0.22 : 0.32
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stroke.strokeColor = tint.cgColor
            stroke.lineDashPattern = tone == .stale ? [3, 3] : nil
            fill.colors = [
                tint.withAlphaComponent(tint.alphaComponent * fillTop).cgColor,
                tint.withAlphaComponent(0).cgColor
            ]
            if tone == .stale {
                dot.fillColor = nil
                dot.strokeColor = tint.cgColor
                dot.lineWidth = 1.2
            } else {
                dot.fillColor = tint.cgColor
                dot.strokeColor = nil
            }
            CATransaction.commit()
        }
    }
}

/// Pure paper-feed bookkeeping, kept out of the view so it can be tested.
enum TraceFeed {
    /// When `next` is `previous` advanced by exactly one sample, returns what to
    /// draw during the slide: `next`, plus the sample that just scrolled out of a
    /// full window so the leading edge stays continuous. Otherwise nil.
    static func oneStep(from previous: [Double], to next: [Double]) -> [Double]? {
        guard !previous.isEmpty, !next.isEmpty else { return nil }
        if next.count == previous.count + 1, Array(next.dropLast()) == previous {
            return next
        }
        if next.count == previous.count, Array(next.dropLast()) == Array(previous.dropFirst()) {
            return [previous[0]] + next
        }
        return nil
    }
}

/// Static instrument paper: minute grid, now line, threshold hairlines and,
/// once a threshold is crossed, the hatch that also encodes the alarm by shape.
struct TraceBackdrop: View, Equatable {
    let thresholds: ThresholdLines
    let hatchColor: Color?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.thresholds == rhs.thresholds && lhs.hatchColor == rhs.hatchColor
    }

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        TraceBackdropLayers(
            thresholds: thresholds,
            hatchColor: hatchColor.map { NSColor($0) },
            increasedContrast: contrast == .increased
        )
        .allowsHitTesting(false)
    }
}

/// The grid, threshold lines and warning hatch as Core Animation shape layers.
/// A SwiftUI `Canvas` here made SwiftUI render with Metal inside the app and
/// raised the footprint by about 210 MB each time the popover opened; shape
/// layers are drawn by the window server like the trace itself.
struct TraceBackdropLayers: NSViewRepresentable {
    let thresholds: ThresholdLines
    let hatchColor: NSColor?
    let increasedContrast: Bool

    func makeNSView(context: Context) -> TraceBackdropView {
        TraceBackdropView()
    }

    func updateNSView(_ view: TraceBackdropView, context: Context) {
        view.update(thresholds: thresholds, hatchColor: hatchColor, increasedContrast: increasedContrast)
    }
}

final class TraceBackdropView: NSView {
    private let hatchClip = CALayer()
    private let hatch = CAShapeLayer()
    private let grid = CAShapeLayer()
    private let thresholdLines = CAShapeLayer()
    private let nowLine = CAShapeLayer()

    private var thresholds = ThresholdLines.none
    private var hatchColor: NSColor?
    private var increasedContrast = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        hatchClip.masksToBounds = true
        hatchClip.addSublayer(hatch)
        for shape in [hatch, grid, thresholdLines, nowLine] {
            shape.fillColor = nil
        }
        root.addSublayer(hatchClip)
        root.addSublayer(grid)
        root.addSublayer(thresholdLines)
        root.addSublayer(nowLine)
        thresholdLines.lineDashPattern = [2, 3]
        hatch.lineWidth = 1
        nowLine.lineWidth = 1
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(thresholds: ThresholdLines, hatchColor: NSColor?, increasedContrast: Bool) {
        guard thresholds != self.thresholds || hatchColor != self.hatchColor
            || increasedContrast != self.increasedContrast else { return }
        self.thresholds = thresholds
        self.hatchColor = hatchColor
        self.increasedContrast = increasedContrast
        redraw()
    }

    override func layout() {
        super.layout()
        redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    /// Geometry in the same top-down terms as `TraceGeometry`, flipped once
    /// into this unflipped view.
    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let hairline = 1 / max(1, scale)
        let plotWidth = max(1, size.width - TrackLayout.nowInset)
        func up(_ y: CGFloat) -> CGFloat { size.height - y }

        for shape in [grid, thresholdLines, nowLine] {
            shape.frame = bounds
        }

        let gridPath = CGMutablePath()
        let slot = TraceGeometry.slot(width: plotWidth)
        var back = TrackLayout.minuteSlots
        while back < TrackLayout.capacity {
            let x = plotWidth - CGFloat(back) * slot
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: size.height))
            back += TrackLayout.minuteSlots
        }
        let baseY = up(size.height - TrackLayout.traceVerticalInset)
        gridPath.move(to: CGPoint(x: 0, y: baseY))
        gridPath.addLine(to: CGPoint(x: plotWidth, y: baseY))
        grid.path = gridPath
        grid.lineWidth = hairline

        let linesPath = CGMutablePath()
        for level in [thresholds.warning, thresholds.critical].compactMap({ $0 }) {
            let y = up(TraceGeometry.y(fraction: level, height: size.height))
            linesPath.move(to: CGPoint(x: 0, y: y))
            linesPath.addLine(to: CGPoint(x: plotWidth, y: y))
        }
        thresholdLines.path = linesPath
        thresholdLines.lineWidth = max(hairline, 0.75)

        let nowPath = CGMutablePath()
        nowPath.move(to: CGPoint(x: plotWidth, y: 0))
        nowPath.addLine(to: CGPoint(x: plotWidth, y: size.height))
        nowLine.path = nowPath

        if hatchColor != nil, let warning = thresholds.warning {
            let bandHeight = TraceGeometry.y(fraction: warning, height: size.height)
            hatchClip.isHidden = false
            hatchClip.frame = CGRect(x: 0, y: up(bandHeight), width: plotWidth, height: bandHeight)
            hatch.frame = hatchClip.bounds
            let hatchPath = CGMutablePath()
            var x = -bandHeight
            while x < plotWidth {
                hatchPath.move(to: CGPoint(x: x, y: 0))
                hatchPath.addLine(to: CGPoint(x: x + bandHeight, y: bandHeight))
                x += 4
            }
            hatch.path = hatchPath
        } else {
            hatchClip.isHidden = true
            hatch.path = nil
        }
        recolor()
    }

    private func recolor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let separator = NSColor.separatorColor.cgColor
            grid.strokeColor = separator
            thresholdLines.strokeColor = separator
            nowLine.strokeColor = NSColor.labelColor
                .withAlphaComponent(increasedContrast ? 0.5 : 0.22).cgColor
            hatch.strokeColor = hatchColor.map { $0.withAlphaComponent($0.alphaComponent * 0.24).cgColor }
        }
    }
}

struct TraceScrubOverlay: View {
    @ObservedObject var scrub: TraceScrubModel
    let samples: [Double]
    let isLevel: Bool
    let tint: Color
    let plotWidth: CGFloat
    let height: CGFloat

    var body: some View {
        if let stepsBack = scrub.stepsBack {
            let x = TraceGeometry.x(stepsBack: stepsBack, width: plotWidth)
            let value = isLevel ? samples.last : TraceGeometry.sample(stepsBack: stepsBack, in: samples)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 1, height: height)
                    .position(x: x, y: height / 2)
                if let value {
                    let y = TraceGeometry.y(fraction: value, height: height)
                    Circle()
                        .fill(tint)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        .frame(width: 7, height: 7)
                        .position(x: x, y: y)
                    Text(MetricFormat.percent(value * 100))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                        .fixedSize()
                        .position(
                            x: min(max(x, 22), plotWidth - 22),
                            y: y > height / 2 ? y - 11 : y + 11
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// VoiceOver Audio Graph for one lane's recent history.
struct LaneChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let summary: String
    /// Percent of capacity used, oldest first.
    let samples: [Double]

    func makeChartDescriptor() -> AXChartDescriptor {
        let cadence = TrackLayout.cadence
        let newest = Double(max(0, samples.count - 1)) * cadence
        let xAxis = AXNumericDataAxisDescriptor(
            title: AppResources.localized("trace.axis.time", fallback: "Time"),
            range: 0...max(cadence, newest),
            gridlinePositions: []
        ) { seconds in
            TraceText.ageText(stepsBack: Int(((newest - seconds) / cadence).rounded()))
        }
        let yAxis = AXNumericDataAxisDescriptor(
            title: AppResources.localized("trace.axis.percent", fallback: "Percent of capacity used"),
            range: 0...100,
            gridlinePositions: []
        ) { value in
            MetricFormat.percent(value)
        }
        let points = samples.enumerated().map { index, value in
            AXDataPoint(x: Double(index) * cadence, y: value)
        }
        let series = AXDataSeriesDescriptor(name: title, isContinuous: true, dataPoints: points)
        return AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}
