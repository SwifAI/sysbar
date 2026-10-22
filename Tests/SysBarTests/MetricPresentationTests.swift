import XCTest
@testable import SysBar

final class MetricPresentationTests: XCTestCase {
    func testCPUThresholdBoundariesAreInclusive() {
        XCTAssertEqual(MetricPresentation.cpu(percent: 59.9).severity, .normal)
        XCTAssertEqual(MetricPresentation.cpu(percent: 60).severity, .warning)
        XCTAssertEqual(MetricPresentation.cpu(percent: 84.9).severity, .warning)
        XCTAssertEqual(MetricPresentation.cpu(percent: 85).severity, .critical)
    }

    func testMemoryUsesTheLargerWarningThreshold() {
        XCTAssertEqual(
            MetricPresentation.memory(usedGB: 14, availableMB: 1_024, totalGB: 16).severity,
            .critical
        )
        XCTAssertEqual(
            MetricPresentation.memory(usedGB: 14, availableMB: 1_024.1, totalGB: 16).severity,
            .warning
        )
        XCTAssertEqual(
            MetricPresentation.memory(usedGB: 13.6, availableMB: 2_457.6, totalGB: 16).severity,
            .warning
        )
        XCTAssertEqual(
            MetricPresentation.memory(usedGB: 13.5, availableMB: 2_457.7, totalGB: 16).severity,
            .normal
        )

        XCTAssertEqual(
            MetricPresentation.memory(usedGB: 6, availableMB: 2_048, totalGB: 8).severity,
            .warning
        )
        XCTAssertEqual(
            MetricPresentation.memory(usedGB: 6, availableMB: 2_048.1, totalGB: 8).severity,
            .normal
        )
    }

    func testSwapQuantityAloneNeverEscalatesPastWarning() {
        XCTAssertEqual(MetricPresentation.swap(usedMB: 511.9, totalMB: 4_096).severity, .normal)
        XCTAssertEqual(MetricPresentation.swap(usedMB: 512, totalMB: 4_096).severity, .warning)
        XCTAssertEqual(MetricPresentation.swap(usedMB: 2_047.9, totalMB: 4_096).severity, .warning)
        XCTAssertEqual(MetricPresentation.swap(usedMB: 2_048, totalMB: 4_096).severity, .warning)
        XCTAssertEqual(MetricPresentation.swap(usedMB: 8_192, totalMB: 8_192).severity, .warning)
    }

    func testDiskFreeSpaceThresholdBoundariesAreInclusive() {
        XCTAssertEqual(MetricPresentation.disk(freeGB: 50.1, totalGB: 500).severity, .normal)
        XCTAssertEqual(MetricPresentation.disk(freeGB: 50, totalGB: 500).severity, .warning)
        XCTAssertEqual(MetricPresentation.disk(freeGB: 10.1, totalGB: 500).severity, .warning)
        XCTAssertEqual(MetricPresentation.disk(freeGB: 10, totalGB: 500).severity, .critical)
    }

    func testFractionsAreClampedAndInvalidInputsAreSanitized() {
        XCTAssertEqual(MetricPresentation.cpu(percent: 175).fraction, 1)
        XCTAssertEqual(MetricPresentation.cpu(percent: -20).fraction, 0)
        XCTAssertEqual(MetricPresentation.cpu(percent: .nan).value, "0")
        XCTAssertEqual(MetricPresentation.cpu(percent: .infinity).fraction, 0)

        XCTAssertEqual(
            MetricPresentation.memory(usedGB: 24, availableMB: 0, totalGB: 16).fraction,
            1
        )
        XCTAssertEqual(
            MetricPresentation.memory(usedGB: -.infinity, availableMB: .nan, totalGB: -1).fraction,
            0
        )
        XCTAssertEqual(MetricPresentation.swap(usedMB: -1, totalMB: .infinity).fraction, 0)
        XCTAssertEqual(MetricPresentation.disk(freeGB: -10, totalGB: .nan).fraction, 0)
    }

    func testFactoriesExposeClearLabelsValuesAndUnits() {
        let cpu = MetricPresentation.cpu(percent: 63.4)
        XCTAssertEqual(cpu.label, "CPU")
        XCTAssertEqual(cpu.value, "63.4")
        XCTAssertEqual(cpu.unit, "%")
        XCTAssertEqual(cpu.symbolName, "cpu")

        let memory = MetricPresentation.memory(usedGB: 8.5, availableMB: 7_680, totalGB: 16)
        XCTAssertEqual(memory.label, "Memory")
        XCTAssertEqual(memory.value, "8.5")
        XCTAssertEqual(memory.unit, "GB")
        XCTAssertEqual(memory.detail, "7.5 GB available")

        let swap = MetricPresentation.swap(usedMB: 1_536, totalMB: 4_096)
        XCTAssertEqual(swap.label, "Swap")
        XCTAssertEqual(swap.value, "1.5")
        XCTAssertEqual(swap.unit, "GB")
        XCTAssertEqual(swap.detail, "of 4 GB")

        let disk = MetricPresentation.disk(freeGB: 128.5, totalGB: 500)
        XCTAssertEqual(disk.label, "Disk Free")
        XCTAssertEqual(disk.value, "128.5")
        XCTAssertEqual(disk.unit, "GB")
        XCTAssertEqual(disk.detail, "of 500 GB total")
    }

    func testPeakIsSecondaryDetailInsteadOfASecondGaugeValue() {
        let presentation = MetricPresentation.cpu(percent: 42, peakPercent: 73.2)

        XCTAssertEqual(presentation.fraction, 0.42, accuracy: 0.000_001)
        XCTAssertEqual(presentation.detail, "Peak 73.2%")
        XCTAssertEqual(
            presentation.accessibilityValue,
            "42 percent, Normal. Peak 73.2 percent."
        )
    }

    func testEverySeverityProvidesAWordAndSystemSymbol() {
        XCTAssertEqual(MetricSeverity.normal.word, "Normal")
        XCTAssertEqual(MetricSeverity.normal.systemImage, "checkmark.circle.fill")
        XCTAssertEqual(MetricSeverity.warning.word, "Warning")
        XCTAssertEqual(MetricSeverity.warning.systemImage, "exclamationmark.triangle.fill")
        XCTAssertEqual(MetricSeverity.critical.word, "Critical")
        XCTAssertEqual(MetricSeverity.critical.systemImage, "xmark.octagon.fill")

        XCTAssertEqual(MetricPresentation.cpu(percent: 60).severity.word, "Warning")
    }

    func testAccessibilityValuesStateMeaningAndSeverityExplicitly() {
        let memory = MetricPresentation.memory(
            usedGB: 14,
            availableMB: 2_048,
            totalGB: 16,
            peakPercent: 91
        )
        XCTAssertEqual(memory.accessibilityLabel, "Memory usage")
        XCTAssertEqual(
            memory.accessibilityValue,
            "14 GB used of 16 GB, 2 GB available, Warning. Peak 91 percent."
        )

        let swap = MetricPresentation.swap(usedMB: 2_048, totalMB: 8_192)
        XCTAssertEqual(swap.accessibilityLabel, "Swap usage")
        XCTAssertEqual(swap.accessibilityValue, "2 GB used of 8 GB, Warning.")
    }

    func testDiskAccessibilityAlwaysSaysFree() {
        let disk = MetricPresentation.disk(freeGB: 10, totalGB: 500, peakUsedPercent: 98)

        XCTAssertEqual(disk.accessibilityLabel, "Disk free space")
        XCTAssertEqual(
            disk.accessibilityValue,
            "10 GB free of 500 GB, Critical. Peak used 98 percent."
        )
        XCTAssertTrue(disk.label.localizedCaseInsensitiveContains("free"))
        XCTAssertEqual(disk.detail?.localizedCaseInsensitiveContains("total"), true)
    }

    func testDiskGaugeFractionRepresentsFreeSpace() {
        let disk = MetricPresentation.disk(freeGB: 40, totalGB: 460)

        XCTAssertEqual(disk.fraction, 40.0 / 460.0, accuracy: 0.000_001)
    }
}
