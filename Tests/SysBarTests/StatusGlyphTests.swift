import AppKit
import XCTest
@testable import SysBar

final class StatusGlyphTests: XCTestCase {
    func testGlyphLevelsQuantizeTheLastTwentySamplesIntoThirteenSteps() {
        let history = Array(repeating: 0.0, count: 10) + (0..<20).map { Double($0) * 100 / 19 }

        let levels = StatusGlyphModel.levels(from: history)

        XCTAssertEqual(levels.count, 20)
        XCTAssertEqual(levels.first, 0)
        XCTAssertEqual(levels.last, 12)
        XCTAssertEqual(StatusGlyphModel.levels(from: [50]), [6])
    }

    func testGlyphLevelsKeepShortHistoriesAndClampInvalidSamples() {
        XCTAssertEqual(StatusGlyphModel.levels(from: []), [])
        XCTAssertEqual(StatusGlyphModel.levels(from: [-20, 140, .nan, .infinity]), [0, 12, 0, 0])
    }

    func testStatusSummaryCarriesRecentCPULevelsAndKeepsTheFixedWidthTitle() {
        let summary = StatusSummary.make(
            cpuPercent: 34,
            memory: MemorySnapshot(usedGB: 9, freeMB: 7_168, totalGB: 16),
            cpuHistory: [0, 50, 100],
            isDelayed: true
        )

        XCTAssertEqual(summary.title, " 34%  7.0G")
        XCTAssertEqual(summary.cpuLevels, [0, 6, 12])
        XCTAssertTrue(summary.isDelayed)
        XCTAssertEqual(StatusSummary.loading.cpuLevels, [])
        XCTAssertFalse(StatusSummary.loading.isDelayed)
    }

    @MainActor
    func testGlyphImageIsAFixedSizeTemplateForEveryState() {
        let summaries: [StatusSummary] = [
            .loading,
            .make(cpuPercent: 10, memory: .empty, cpuHistory: [10, 20, 30]),
            .make(cpuPercent: 90, memory: .empty, cpuHistory: Array(repeating: 90, count: 40), isDelayed: true)
        ]
        for summary in summaries {
            let image = StatusGlyphRenderer.image(for: summary)
            XCTAssertEqual(image.size, StatusGlyphRenderer.size)
            XCTAssertTrue(image.isTemplate)
        }
    }

    @MainActor
    func testUnchangedSummariesReuseTheCachedGlyph() {
        let summary = StatusSummary.make(cpuPercent: 10, memory: .empty, cpuHistory: [10, 20])
        XCTAssertTrue(StatusGlyphRenderer.image(for: summary) === StatusGlyphRenderer.image(for: summary))
    }
}
