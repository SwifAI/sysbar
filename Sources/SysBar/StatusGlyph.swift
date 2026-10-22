import AppKit

/// Quantizes the most recent CPU history into the menu-bar sparkline. Pure so
/// the mapping is testable without drawing.
enum StatusGlyphModel {
    static let columns = 20
    static let maxLevel: UInt8 = 12

    /// The last `columns` samples, newest last, each mapped to 0...maxLevel.
    static func levels(from cpuHistory: [Double]) -> [UInt8] {
        cpuHistory.suffix(columns).map { percent in
            let bounded = percent.isFinite ? min(100, max(0, percent)) : 0
            return UInt8((bounded / 100 * Double(maxLevel)).rounded())
        }
    }
}

/// Draws the living menu-bar glyph: a template sparkline of the last minute of
/// CPU on the same scale and newest-right convention as the popover's CPU lane.
@MainActor
enum StatusGlyphRenderer {
    static let size = NSSize(width: 20, height: 12)

    private static var cache: (key: Key, image: NSImage)?

    private struct Key: Equatable {
        let levels: [UInt8]
        let isDelayed: Bool
        let isLoading: Bool
        let hasAttention: Bool
    }

    static func image(for summary: StatusSummary) -> NSImage {
        let key = Key(
            levels: summary.cpuLevels,
            isDelayed: summary.isDelayed,
            isLoading: summary == .loading,
            hasAttention: summary.hasAttention
        )
        if let cache, cache.key == key { return cache.image }
        let image = draw(key)
        cache = (key, image)
        return image
    }

    /// Rasterized once per distinct key at 1x and 2x, so status-bar redraws
    /// composite a bitmap instead of replaying the vector drawing.
    private static func draw(_ key: Key) -> NSImage {
        let vector = vectorImage(key)
        let image = NSImage(size: size)
        for scale in [1, 2] {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale,
                pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            vector.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        if image.representations.isEmpty { return vector }
        image.isTemplate = true
        return image
    }

    private static func vectorImage(_ key: Key) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let baselineY: CGFloat = 0.75
            let topY = rect.height - 1
            let levels = key.levels

            guard !key.isLoading, levels.count >= 2 else {
                let baseline = NSBezierPath()
                baseline.move(to: NSPoint(x: 0.5, y: baselineY))
                baseline.line(to: NSPoint(x: rect.width - 0.5, y: baselineY))
                baseline.lineWidth = 1
                if key.isLoading { baseline.setLineDash([1, 2], count: 2, phase: 0) }
                NSColor.black.withAlphaComponent(0.6).setStroke()
                baseline.stroke()
                return true
            }

            let step = (rect.width - 1) / CGFloat(StatusGlyphModel.columns - 1)
            let points = levels.enumerated().map { index, level in
                let stepsBack = CGFloat(levels.count - 1 - index)
                let y = baselineY + CGFloat(level) / CGFloat(StatusGlyphModel.maxLevel) * (topY - baselineY)
                return NSPoint(x: rect.width - 0.5 - stepsBack * step, y: y)
            }

            let area = NSBezierPath()
            area.move(to: NSPoint(x: points[0].x, y: 0))
            points.forEach { area.line(to: $0) }
            area.line(to: NSPoint(x: points[points.count - 1].x, y: 0))
            area.close()
            NSColor.black.withAlphaComponent(key.isDelayed ? 0.15 : 0.32).setFill()
            area.fill()

            let line = NSBezierPath()
            line.move(to: points[0])
            points.dropFirst().forEach { line.line(to: $0) }
            line.lineWidth = 1.25
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            if key.isDelayed { line.setLineDash([2, 1.5], count: 2, phase: 0) }
            NSColor.black.withAlphaComponent(key.isDelayed ? 0.6 : 1).setStroke()
            line.stroke()
            if key.hasAttention {
                // A small dot in the top-right corner: same width, template color.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: rect.width - 5.5, y: rect.height - 5.5, width: 5.5, height: 5.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.width - 4, y: rect.height - 4, width: 3.5, height: 3.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
