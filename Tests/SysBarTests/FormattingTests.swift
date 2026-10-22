import XCTest
@testable import SysBar

final class FormattingTests: XCTestCase {
    func testDecimalFormattingRespectsLocaleWithoutGroupingOrTrailingZeros() {
        XCTAssertEqual(MetricFormat.decimal(1234.5, maximumFractionDigits: 1,
                                          locale: Locale(identifier: "en_US")), "1234.5")
        XCTAssertEqual(MetricFormat.decimal(1234.5, maximumFractionDigits: 1,
                                          locale: Locale(identifier: "de_DE")), "1234,5")
        XCTAssertEqual(MetricFormat.decimal(42, maximumFractionDigits: 1,
                                          locale: Locale(identifier: "en_US")), "42")
    }

    func testNonfiniteMeasurementsHaveReadableZeroValues() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(MetricFormat.percent(value), "0%")
            XCTAssertFalse(MetricFormat.rate(bytesPerSecond: value).contains("∞"))
            XCTAssertEqual(MetricPresentation.cpu(percent: value).value, "0")
        }
    }

    func testMemoryUsesMegabytesBelowOneGigabyte() {
        XCTAssertEqual(MetricFormat.memory(megabytes: 512), "512 MB")
    }

    func testMemoryUsesFractionalGigabytesAboveOneGigabyte() {
        XCTAssertEqual(MetricFormat.memory(megabytes: 1_536), "1.5 GB")
    }

    func testRateClampsNegativeValuesToZero() {
        XCTAssertEqual(MetricFormat.rate(bytesPerSecond: -1), "0 KB/s")
    }

    func testRateUsesKilobytesBelowOneMegabytePerSecond() {
        XCTAssertEqual(MetricFormat.rate(bytesPerSecond: 512 * 1_024), "512 KB/s")
    }

    func testRateUsesFractionalMegabytesAtOneMegabytePerSecondOrMore() {
        XCTAssertEqual(MetricFormat.rate(bytesPerSecond: 1.5 * 1_048_576), "1.5 MB/s")
    }

    func testPortIdentifiersNeverUseLocaleGroupingSeparators() {
        XCTAssertEqual(
            PortDisplayText.endpoint(transport: "TCP", bindAddress: "*", port: 53_008),
            "TCP · *:53008"
        )
        XCTAssertEqual(PortDisplayText.actionLabel(port: 53_008), "Actions for port 53008")
        XCTAssertEqual(
            PortDisplayText.help(
                processName: "rapportd",
                pid: 12_345,
                bindAddress: "*",
                port: 61_826
            ),
            "rapportd, process 12345, listening on *:61826"
        )
        XCTAssertEqual(
            PortDisplayText.listenerAlertBody(
                processName: "rapportd",
                bindAddress: "*",
                port: 61_826
            ),
            "rapportd is listening on *:61826"
        )
    }
}
