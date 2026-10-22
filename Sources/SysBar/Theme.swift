import SwiftUI
import AppKit
import Foundation

enum MetricSeverity: String, CaseIterable, Equatable, Sendable {
    case normal
    case warning
    case critical

    var word: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    var systemImage: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}

struct MetricPresentation: Equatable, Sendable {
    let label: String
    let value: String
    let unit: String
    let fraction: Double
    let severity: MetricSeverity
    let symbolName: String
    let detail: String?
    let accessibilityLabel: String
    let accessibilityValue: String

    static func cpu(percent rawPercent: Double, peakPercent rawPeak: Double? = nil) -> Self {
        let percent = sanitized(rawPercent)
        let severity: MetricSeverity
        if percent >= 85 {
            severity = .critical
        } else if percent >= 60 {
            severity = .warning
        } else {
            severity = .normal
        }
        let peak = rawPeak.map(sanitized)
        let peakNumber = peak.map(number)
        let detail = peakNumber.map {
            AppResources.formatted("metric.cpu.peak.detail", fallback: "Peak %@%%", $0)
        }
        let accessibilityValue: String
        if let peakNumber {
            accessibilityValue = AppResources.formatted(
                "metric.cpu.accessibility.peak",
                fallback: "%@ percent, %@. Peak %@ percent.",
                number(percent),
                AppResources.localized(severity.word),
                peakNumber
            )
        } else {
            accessibilityValue = AppResources.formatted(
                "metric.cpu.accessibility",
                fallback: "%@ percent, %@.",
                number(percent),
                AppResources.localized(severity.word)
            )
        }
        return Self(
            label: "CPU",
            value: number(percent),
            unit: "%",
            fraction: clampedFraction(percent / 100),
            severity: severity,
            symbolName: "cpu",
            detail: detail,
            accessibilityLabel: "CPU usage",
            accessibilityValue: accessibilityValue
        )
    }

    static func memory(
        usedGB rawUsedGB: Double,
        availableMB rawAvailableMB: Double,
        totalGB rawTotalGB: Double,
        peakPercent rawPeak: Double? = nil
    ) -> Self {
        let usedGB = sanitized(rawUsedGB)
        let availableMB = sanitized(rawAvailableMB)
        let totalGB = sanitized(rawTotalGB)
        let fifteenPercentMB = totalGB * 1_024 * 0.15
        let warningThreshold = max(2_048, fifteenPercentMB.isFinite ? fifteenPercentMB : .greatestFiniteMagnitude)
        let severity: MetricSeverity
        if availableMB <= 1_024 {
            severity = .critical
        } else if availableMB <= warningThreshold {
            severity = .warning
        } else {
            severity = .normal
        }

        let available = capacity(megabytes: availableMB)
        let peak = rawPeak.map(sanitized)
        let peakNumber = peak.map(number)
        let detail: String
        let accessibilityValue: String
        if let peakNumber {
            detail = AppResources.formatted(
                "metric.memory.detail.peak",
                fallback: "%@ %@ available · Peak %@%%",
                available.value,
                AppResources.localized(available.unit),
                peakNumber
            )
            accessibilityValue = AppResources.formatted(
                "metric.memory.accessibility.peak",
                fallback: "%@ %@ used of %@ %@, %@ %@ available, %@. Peak %@ percent.",
                number(usedGB),
                AppResources.localized("GB"),
                number(totalGB),
                AppResources.localized("GB"),
                available.value,
                AppResources.localized(available.unit),
                AppResources.localized(severity.word),
                peakNumber
            )
        } else {
            detail = AppResources.formatted(
                "metric.memory.detail",
                fallback: "%@ %@ available",
                available.value,
                AppResources.localized(available.unit)
            )
            accessibilityValue = AppResources.formatted(
                "metric.memory.accessibility",
                fallback: "%@ %@ used of %@ %@, %@ %@ available, %@.",
                number(usedGB),
                AppResources.localized("GB"),
                number(totalGB),
                AppResources.localized("GB"),
                available.value,
                AppResources.localized(available.unit),
                AppResources.localized(severity.word)
            )
        }
        return Self(
            label: "Memory",
            value: number(usedGB),
            unit: "GB",
            fraction: totalGB > 0 ? clampedFraction(usedGB / totalGB) : 0,
            severity: severity,
            symbolName: "memorychip",
            detail: detail,
            accessibilityLabel: "Memory usage",
            accessibilityValue: accessibilityValue
        )
    }

    static func swap(
        usedMB rawUsedMB: Double,
        totalMB rawTotalMB: Double,
        peakPercent rawPeak: Double? = nil
    ) -> Self {
        let usedMB = sanitized(rawUsedMB)
        let totalMB = sanitized(rawTotalMB)
        let severity: MetricSeverity
        if usedMB >= 512 {
            severity = .warning
        } else {
            severity = .normal
        }
        let used = capacity(megabytes: usedMB)
        let total = capacity(megabytes: totalMB)
        let peak = rawPeak.map(sanitized)
        let peakNumber = peak.map(number)
        let detail: String
        let accessibilityValue: String
        if let peakNumber {
            detail = AppResources.formatted(
                "metric.swap.detail.peak",
                fallback: "of %@ %@ · Peak %@%%",
                total.value,
                AppResources.localized(total.unit),
                peakNumber
            )
            accessibilityValue = AppResources.formatted(
                "metric.swap.accessibility.peak",
                fallback: "%@ %@ used of %@ %@, %@. Peak %@ percent.",
                used.value,
                AppResources.localized(used.unit),
                total.value,
                AppResources.localized(total.unit),
                AppResources.localized(severity.word),
                peakNumber
            )
        } else {
            detail = AppResources.formatted(
                "metric.swap.detail",
                fallback: "of %@ %@",
                total.value,
                AppResources.localized(total.unit)
            )
            accessibilityValue = AppResources.formatted(
                "metric.swap.accessibility",
                fallback: "%@ %@ used of %@ %@, %@.",
                used.value,
                AppResources.localized(used.unit),
                total.value,
                AppResources.localized(total.unit),
                AppResources.localized(severity.word)
            )
        }
        return Self(
            label: "Swap",
            value: used.value,
            unit: used.unit,
            fraction: totalMB > 0 ? clampedFraction(usedMB / totalMB) : 0,
            severity: severity,
            symbolName: "arrow.left.arrow.right.square",
            detail: detail,
            accessibilityLabel: "Swap usage",
            accessibilityValue: accessibilityValue
        )
    }

    static func disk(
        freeGB rawFreeGB: Double,
        totalGB rawTotalGB: Double,
        peakUsedPercent rawPeak: Double? = nil
    ) -> Self {
        let freeGB = sanitized(rawFreeGB)
        let totalGB = sanitized(rawTotalGB)
        let severity: MetricSeverity
        if freeGB <= 10 {
            severity = .critical
        } else if freeGB <= 50 {
            severity = .warning
        } else {
            severity = .normal
        }
        let free = capacity(gigabytes: freeGB)
        let total = capacity(gigabytes: totalGB)
        let peak = rawPeak.map(sanitized)
        let peakNumber = peak.map(number)
        let detail: String
        let accessibilityValue: String
        if let peakNumber {
            detail = AppResources.formatted(
                "metric.disk.detail.peak",
                fallback: "of %@ %@ total · Peak used %@%%",
                total.value,
                AppResources.localized(total.unit),
                peakNumber
            )
            accessibilityValue = AppResources.formatted(
                "metric.disk.accessibility.peak",
                fallback: "%@ %@ free of %@ %@, %@. Peak used %@ percent.",
                free.value,
                AppResources.localized(free.unit),
                total.value,
                AppResources.localized(total.unit),
                AppResources.localized(severity.word),
                peakNumber
            )
        } else {
            detail = AppResources.formatted(
                "metric.disk.detail",
                fallback: "of %@ %@ total",
                total.value,
                AppResources.localized(total.unit)
            )
            accessibilityValue = AppResources.formatted(
                "metric.disk.accessibility",
                fallback: "%@ %@ free of %@ %@, %@.",
                free.value,
                AppResources.localized(free.unit),
                total.value,
                AppResources.localized(total.unit),
                AppResources.localized(severity.word)
            )
        }
        let freeFraction = totalGB > 0 ? min(freeGB, totalGB) / totalGB : 0
        return Self(
            label: "Disk Free",
            value: free.value,
            unit: free.unit,
            fraction: clampedFraction(freeFraction),
            severity: severity,
            symbolName: "internaldrive",
            detail: detail,
            accessibilityLabel: "Disk free space",
            accessibilityValue: accessibilityValue
        )
    }

    private static func sanitized(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }

    private static func clampedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func number(_ value: Double) -> String {
        MetricFormat.decimal(sanitized(value), maximumFractionDigits: 1)
    }

    private static func capacity(megabytes: Double) -> (value: String, unit: String) {
        if megabytes >= 1_024 {
            return (number(megabytes / 1_024), "GB")
        }
        return (number(megabytes), "MB")
    }

    private static func capacity(gigabytes: Double) -> (value: String, unit: String) {
        if gigabytes >= 1_024 {
            return (number(gigabytes / 1_024), "TB")
        }
        return (number(gigabytes), "GB")
    }
}

extension MetricSeverity {
    var color: Color {
        switch self {
        case .normal: return .sbSuccess
        case .warning: return .sbWarning
        case .critical: return .sbDanger
        }
    }
}

extension Color {
    // These compatibility names intentionally resolve through AppKit dynamic
    // system colors so contrast and appearance follow the user's macOS theme.
    static let sbDanger = Color(nsColor: .systemRed)
    static let sbWarning = Color(nsColor: .systemOrange)
    static let sbSuccess = Color(nsColor: .systemGreen)
}

extension ShapeStyle where Self == Color {
    static var sbDanger: Color  { .sbDanger }
    static var sbWarning: Color { .sbWarning }
    static var sbSuccess: Color { .sbSuccess }
}

enum Thresholds {
    static let cpuWarn: Double = 60
    static let cpuDanger: Double = 85

    static let memCriticalMB = 1024

    static let swapWarnMB = 512

    static let diskCriticalGB: Double = 10
    static let diskLowGB: Double = 50
}

enum SectionKey: String {
    case systemServices = "section.systemServices"
    case topCPU = "section.topCPU"
    // v2 applies the more glanceable collapsed default once for existing builds.
    case topMem = "section.topMem.v2"
    // v2 key resets any previously-stored expansion so the new default takes effect
    case ports = "section.ports.v2"

    var defaultExpanded: Bool {
        self == .topCPU
    }
}
