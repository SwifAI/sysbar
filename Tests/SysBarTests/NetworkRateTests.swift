import XCTest
@testable import SysBar

final class NetworkRateTests: XCTestCase {
    func testFirstSampleEstablishesBaselineInsteadOfShowingLifetimeTraffic() {
        var rates = NetworkRateAccumulator()
        XCTAssertEqual(rates.sample(["en0": bytes(9_000_000, 3_000_000)], at: 100), .zero)
        XCTAssertEqual(
            rates.sample(["en0": bytes(9_000_600, 3_000_300)], at: 103),
            NetworkRates(received: 200, sent: 100)
        )
    }

    func testImmediateRefreshPreservesRatesAndOriginalBaseline() {
        var rates = NetworkRateAccumulator()
        _ = rates.sample(["en0": bytes(0, 0)], at: 0)
        let established = rates.sample(["en0": bytes(600, 300)], at: 3)
        XCTAssertEqual(rates.sample(["en0": bytes(650, 320)], at: 3.2), established)
        XCTAssertEqual(
            rates.sample(["en0": bytes(1_200, 900)], at: 6),
            NetworkRates(received: 200, sent: 200)
        )
    }

    func testNewInterfaceDoesNotProduceLifetimeCounterSpike() {
        var rates = NetworkRateAccumulator()
        _ = rates.sample(["en0": bytes(1_000, 500)], at: 0)
        XCTAssertEqual(
            rates.sample(["en0": bytes(1_600, 800), "en5": bytes(4_000_000, 2_000_000)], at: 3),
            NetworkRates(received: 200, sent: 100)
        )
        XCTAssertEqual(
            rates.sample(["en0": bytes(2_200, 1_100), "en5": bytes(4_000_300, 2_000_600)], at: 6),
            NetworkRates(received: 300, sent: 300)
        )
    }

    func testRemovingInterfaceDoesNotEraseRemainingTraffic() {
        var rates = NetworkRateAccumulator()
        _ = rates.sample(["en0": bytes(1_000, 500), "en5": bytes(4_000_000, 2_000_000)], at: 0)
        XCTAssertEqual(
            rates.sample(["en0": bytes(1_600, 800)], at: 3),
            NetworkRates(received: 200, sent: 100)
        )
    }

    func testCounterResetDoesNotEraseOtherInterfacesOrDirections() {
        var rates = NetworkRateAccumulator()
        _ = rates.sample(["en0": bytes(4_000_000, 500), "en5": bytes(100, 100)], at: 0)
        XCTAssertEqual(
            rates.sample(["en0": bytes(100, 800), "en5": bytes(700, 400)], at: 3),
            NetworkRates(received: 200, sent: 200)
        )
        XCTAssertEqual(
            rates.sample(["en0": bytes(400, 1_100), "en5": bytes(1_300, 700)], at: 6),
            NetworkRates(received: 300, sent: 200)
        )
    }

    func testLongSamplingGapRebaselinesThenResumesLiveRate() {
        var rates = NetworkRateAccumulator()
        _ = rates.sample(["en0": bytes(0, 0)], at: 0)
        _ = rates.sample(["en0": bytes(600, 300)], at: 3)
        XCTAssertEqual(rates.sample(["en0": bytes(30_000, 10_000)], at: 100), .zero)
        XCTAssertEqual(
            rates.sample(["en0": bytes(30_600, 10_300)], at: 103),
            NetworkRates(received: 200, sent: 100)
        )
    }

    func testReversedAndNonfiniteInstantsCannotPoisonFutureRates() {
        var rates = NetworkRateAccumulator()
        _ = rates.sample(["en0": bytes(100, 100)], at: 10)
        XCTAssertEqual(rates.sample(["en0": bytes(200, 200)], at: 5), .zero)
        XCTAssertEqual(rates.sample(["en0": bytes(UInt64.max, UInt64.max)], at: .infinity), .zero)
        XCTAssertEqual(
            rates.sample(["en0": bytes(800, 500)], at: 8),
            NetworkRates(received: 200, sent: 100)
        )
    }

    private func bytes(_ received: UInt64, _ sent: UInt64) -> NetworkByteCounters {
        NetworkByteCounters(received: received, sent: sent)
    }
}
