import Combine
import XCTest
@testable import SysBar

final class TraceGeometryTests: XCTestCase {
    func testNewestSampleIsPinnedToTheTrailingEdgeAndOlderSamplesStepLeftOneSlotEach() {
        let width: CGFloat = 236
        let slot = TraceGeometry.slot(width: width, capacity: 60)

        XCTAssertEqual(TraceGeometry.x(stepsBack: 0, width: width, capacity: 60), width)
        XCTAssertEqual(TraceGeometry.x(stepsBack: 1, width: width, capacity: 60), width - slot, accuracy: 0.0001)
        XCTAssertEqual(TraceGeometry.x(stepsBack: 59, width: width, capacity: 60), 0, accuracy: 0.0001)
    }

    func testShortHistoriesStayRightAnchoredInsteadOfStretchingTime() {
        let samples = [0.1, 0.2, 0.3]

        XCTAssertEqual(TraceGeometry.sample(stepsBack: 0, in: samples), 0.3)
        XCTAssertEqual(TraceGeometry.sample(stepsBack: 2, in: samples), 0.1)
        XCTAssertNil(TraceGeometry.sample(stepsBack: 3, in: samples))
        XCTAssertNil(TraceGeometry.sample(stepsBack: -1, in: samples))
    }

    func testPointerXMapsToTheNearestSampleAndClampsToTheWindow() {
        let width: CGFloat = 236
        let slot = TraceGeometry.slot(width: width, capacity: 60)

        XCTAssertEqual(TraceGeometry.stepsBack(forX: width, width: width, capacity: 60), 0)
        XCTAssertEqual(TraceGeometry.stepsBack(forX: width - slot * 10.4, width: width, capacity: 60), 10)
        XCTAssertEqual(TraceGeometry.stepsBack(forX: width + 50, width: width, capacity: 60), 0)
        XCTAssertEqual(TraceGeometry.stepsBack(forX: -500, width: width, capacity: 60), 59)
        XCTAssertEqual(TraceGeometry.stepsBack(forX: .nan, width: width, capacity: 60), 0)
    }

    func testSampleAgeFollowsTheThreeSecondCollectionCadence() {
        XCTAssertEqual(TraceGeometry.age(stepsBack: 0, cadence: 3), 0)
        XCTAssertEqual(TraceGeometry.age(stepsBack: 20, cadence: 3), 60)
        XCTAssertEqual(TrackLayout.cadence, 3)
        XCTAssertEqual(TrackLayout.minuteSlots, 20)
        XCTAssertEqual(TrackLayout.windowMinutes, 3)
    }

    func testScrubAgeReadsNowForTheNewestSampleAndMinutesSecondsBeforeIt() {
        XCTAssertEqual(TraceText.ageText(stepsBack: 0), "Now")
        XCTAssertEqual(TraceText.ageText(stepsBack: 30), "1:30 ago")
        XCTAssertEqual(TraceText.windowText, "Last 3 minutes")
    }

    func testEveryPrecomputedScrubAgeMatchesTheCadenceAndAgesOutsideTheWindowStillFormat() {
        XCTAssertEqual(TraceText.ageText(stepsBack: 1), "0:03 ago")
        XCTAssertEqual(TraceText.ageText(stepsBack: TrackLayout.capacity - 1), "2:57 ago")
        XCTAssertEqual(TraceText.ageText(stepsBack: TrackLayout.capacity), "3:00 ago")
        XCTAssertEqual(TraceText.ageText(stepsBack: -2), "Now")
    }

    func testPercentFractionsAreClampedAndInvalidValuesDrawAtTheBaseline() {
        XCTAssertEqual(TraceGeometry.fraction(percent: 50), 0.5)
        XCTAssertEqual(TraceGeometry.fraction(percent: 180), 1)
        XCTAssertEqual(TraceGeometry.fraction(percent: -4), 0)
        XCTAssertEqual(TraceGeometry.fraction(percent: .nan), 0)
        XCTAssertEqual(TraceGeometry.y(fraction: 0, height: 60, inset: 6), 54)
        XCTAssertEqual(TraceGeometry.y(fraction: 1, height: 60, inset: 6), 6)
    }

    func testPaperFeedSlidesOnlyWhenHistoryAdvancedByExactlyOneSample() {
        XCTAssertEqual(TraceFeed.oneStep(from: [1, 2], to: [1, 2, 3]), [1, 2, 3])
        XCTAssertNil(TraceFeed.oneStep(from: [1, 2], to: [1, 2, 3, 4]))
        XCTAssertNil(TraceFeed.oneStep(from: [1, 2], to: [9, 2, 3]))
        XCTAssertNil(TraceFeed.oneStep(from: [], to: [1]))
        XCTAssertNil(TraceFeed.oneStep(from: [1, 2, 3], to: [1, 2, 3]))
    }

    func testFullWindowFeedCarriesTheDepartingSampleSoTheLeadingEdgeStaysContinuous() {
        XCTAssertEqual(TraceFeed.oneStep(from: [1, 2, 3], to: [2, 3, 4]), [1, 2, 3, 4])
    }

    func testCPUThresholdLinesMatchTheSeverityThresholds() {
        XCTAssertEqual(MetricThresholdLines.cpu, ThresholdLines(warning: 0.60, critical: 0.85))
    }

    func testMemoryThresholdLinesAreExpressedAsUsedFractionsOfTotal() {
        let lines = MetricThresholdLines.memory(totalGB: 64)
        XCTAssertEqual(try XCTUnwrap(lines.warning), 0.85, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(lines.critical), 1 - 1_024.0 / 65_536, accuracy: 0.0001)

        let small = MetricThresholdLines.memory(totalGB: 8)
        XCTAssertEqual(try XCTUnwrap(small.warning), 0.75, accuracy: 0.0001)
        XCTAssertEqual(MetricThresholdLines.memory(totalGB: 0), .none)
    }

    func testSwapThresholdLineIsOmittedWhenThereIsNoSwapCapacity() {
        XCTAssertEqual(MetricThresholdLines.swap(totalMB: 0), .none)
        XCTAssertEqual(MetricThresholdLines.swap(totalMB: 2_048), ThresholdLines(warning: 0.25, critical: nil))
        XCTAssertEqual(MetricThresholdLines.swap(totalMB: 256), ThresholdLines(warning: 1, critical: nil))
    }

    func testDiskThresholdLinesComeFromFreeGigabyteThresholds() {
        let lines = MetricThresholdLines.disk(totalGB: 500)
        XCTAssertEqual(try XCTUnwrap(lines.warning), 0.9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(lines.critical), 0.98, accuracy: 0.0001)
        XCTAssertEqual(MetricThresholdLines.disk(totalGB: 30), ThresholdLines(warning: 0, critical: 1 - 10.0 / 30))
    }

    @MainActor
    func testKeyboardScrubStepsWithinTheRecordedWindow() {
        let scrub = TraceScrubModel()
        scrub.step(by: 1)
        XCTAssertEqual(scrub.stepsBack, 1)
        scrub.step(by: 100)
        XCTAssertEqual(scrub.stepsBack, TrackLayout.capacity - 1)
        scrub.step(by: -500)
        XCTAssertEqual(scrub.stepsBack, 0)
    }

    @MainActor
    func testScrubPublishesOnlyWhenTheCursorMovesToADifferentSample() {
        let scrub = TraceScrubModel()
        var publications = 0
        let subscription = scrub.objectWillChange.sink { publications += 1 }
        scrub.scrub(to: 12)
        scrub.scrub(to: 12)
        scrub.scrub(to: 12)
        scrub.scrub(to: nil)
        scrub.scrub(to: nil)
        subscription.cancel()
        XCTAssertEqual(publications, 2)
    }
}
