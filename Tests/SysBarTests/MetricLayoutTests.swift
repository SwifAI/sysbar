import AppKit
import SwiftUI
import XCTest
@testable import SysBar

@MainActor
final class MetricLayoutTests: XCTestCase {
    func testLaneSummaryFitsTheLeadingColumnWithoutGrowingTheLane() {
        let content = MetricLaneContent(
            id: .storageLow,
            title: AppResources.localized("Disk Free"),
            symbolName: "internaldrive",
            isPrimary: false,
            state: .value(
                .disk(freeGB: 40, totalGB: 460),
                detail: MetricPresentation.disk(freeGB: 40, totalGB: 460).detail,
                isStale: false
            ),
            samples: [0.91],
            isLevel: true,
            thresholds: MetricThresholdLines.disk(totalGB: 460)
        )
        let host = NSHostingController(
            rootView: MetricLane(content: content, scrub: TraceScrubModel())
                .frame(width: PopoverSizePolicy.contentWidth)
        )
        host.sizingOptions = [.preferredContentSize]
        host.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(host.view.fittingSize.height, TrackLayout.secondaryLaneHeight + 14)
    }

    func testHeroColumnsSpanThePopoverWidth() {
        let traceWidth = PopoverSizePolicy.contentWidth - TrackLayout.gutter * 2 - TrackLayout.leadingColumnWidth
        XCTAssertGreaterThanOrEqual(traceWidth, 200)
    }
}
