import XCTest
@testable import SysBar

final class HistoryBufferTests: XCTestCase {
    func testAppendKeepsOnlyNewestValues() {
        var history = HistoryBuffer<Double>(capacity: 3)

        [1, 2, 3, 4].forEach { history.append($0) }

        XCTAssertEqual(history.values, [2, 3, 4])
    }

    func testCapacityIsClampedToAtLeastOne() {
        var history = HistoryBuffer<Int>(capacity: 0)

        history.append(1)
        history.append(2)

        XCTAssertEqual(history.capacity, 1)
        XCTAssertEqual(history.values, [2])
    }
}
