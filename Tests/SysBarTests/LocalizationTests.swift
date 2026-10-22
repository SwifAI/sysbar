import XCTest
@testable import SysBar

final class LocalizationTests: XCTestCase {
    func testEnglishCatalogLoadsThroughRuntimeResourceResolver() {
        XCTAssertNotNil(
            AppResources.bundle.path(
                forResource: "Localizable",
                ofType: "strings",
                inDirectory: nil,
                forLocalization: "en"
            )
        )
        XCTAssertEqual(AppResources.localized("SysBar"), "SysBar")
        XCTAssertEqual(AppResources.localized("Alerts"), "Alerts")
        XCTAssertEqual(
            AppResources.bundle.localizedString(
                forKey: "System Services",
                value: "__missing__",
                table: "Localizable"
            ),
            "System Services"
        )
    }

    func testMissingKeyUsesExplicitReadableFallback() {
        XCTAssertEqual(
            AppResources.localized("missing.key", fallback: "Readable fallback"),
            "Readable fallback"
        )
    }

    func testEnglishPluralRulesDistinguishOneAndMany() {
        XCTAssertEqual(AppResources.plural("processes.count", count: 1), "1 process")
        XCTAssertEqual(AppResources.plural("processes.count", count: 2), "2 processes")
        XCTAssertEqual(AppResources.plural("trace.window.minutes", count: 1), "Last 1 minute")
        XCTAssertEqual(AppResources.plural("trace.window.minutes", count: 3), "Last 3 minutes")
    }

    func testRepeatedLookupsKeepAnsweringWithTheBundlesStringForEachKeyFallbackAndCount() {
        for _ in 0..<3 {
            XCTAssertEqual(AppResources.localized("Alerts"), "Alerts")
            XCTAssertEqual(AppResources.localized("missing.key", fallback: "Readable fallback"), "Readable fallback")
            XCTAssertEqual(AppResources.localized("missing.key", fallback: "Another fallback"), "Another fallback")
            XCTAssertEqual(AppResources.localized("missing.key"), "missing.key")
            XCTAssertEqual(AppResources.plural("processes.count", count: 1), "1 process")
            XCTAssertEqual(AppResources.plural("processes.count", count: 2), "2 processes")
            XCTAssertEqual(AppResources.plural("missing.plural", count: 7), "7")
        }
    }

    func testDynamicPresentationUsesLocalizableFormatKeys() {
        let requiredFormatKeys = [
            "updated.time",
            "last.updated.error",
            "network.transfer",
            "metric.value.unit",
            "metric.percent.value",
            "metric.cpu.peak.detail",
            "metric.cpu.accessibility",
            "metric.cpu.accessibility.peak",
            "metric.memory.detail",
            "metric.memory.detail.peak",
            "metric.memory.accessibility",
            "metric.memory.accessibility.peak",
            "metric.swap.detail",
            "metric.swap.detail.peak",
            "metric.swap.accessibility",
            "metric.swap.accessibility.peak",
            "metric.disk.detail",
            "metric.disk.detail.peak",
            "metric.disk.accessibility",
            "metric.disk.accessibility.peak",
            "process.confirmation",
            "process.action.title",
            "process.failed.pids",
            "process.changed.failed.pids",
            "status.summary.accessibility",
            "status.loading.accessibility",
            "accessibility.status",
            "accessibility.collection.status",
            "accessibility.detail.status",
            "actions.process",
            "process.help",
            "process.count.badge",
            "actions.port",
            "port.endpoint.detail",
            "port.help",
            "port.accessibility.label",
            "port.accessibility.value",
            "error.cpu.statistics",
            "error.memory.statistics",
            "error.memory.truncated",
            "error.memory.totalram",
            "error.memory.implausible",
            "error.swap.statistics",
            "error.process.list",
            "error.process.list.read",
            "error.network.interfaces",
            "error.lsof.launch",
            "error.lsof.failure",
            "error.lsof.exit.status",
            "error.lsof.timeout",
            "error.lsof.invalid.utf8",
            "error.disk.inventory",
            "trace.scrub.age",
            "trace.scrub.hint",
            "trace.axis.time",
            "trace.axis.percent"
        ]

        for key in requiredFormatKeys {
            XCTAssertNotEqual(
                AppResources.bundle.localizedString(
                    forKey: key,
                    value: "__missing__",
                    table: "Localizable"
                ),
                "__missing__",
                "Missing localizable format key: \(key)"
            )
        }
    }

    func testStatusDetailToggleAndDiskFallbackStringsAreLocalized() {
        let requiredKeys = [
            "Show details and actions",
            "Hide details and actions",
            "No internal volume detected"
        ]

        for key in requiredKeys {
            XCTAssertNotEqual(
                AppResources.bundle.localizedString(
                    forKey: key,
                    value: "__missing__",
                    table: "Localizable"
                ),
                "__missing__",
                "Missing localization: \(key)"
            )
        }
    }

    func testStringCatalogAndEnglishRuntimeTableStayInSync() throws {
        let catalogURL = try XCTUnwrap(
            AppResources.bundle.url(forResource: "Localizable", withExtension: "xcstrings")
        )
        let englishTableURL = try XCTUnwrap(
            AppResources.bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: "en"
            )
        )
        let catalogObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let catalogStrings = try XCTUnwrap(catalogObject["strings"] as? [String: Any])
        let englishTable = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: englishTableURL),
                options: [],
                format: nil
            ) as? [String: String]
        )

        let pluralTableURL = try XCTUnwrap(
            AppResources.bundle.url(
                forResource: "Localizable",
                withExtension: "stringsdict",
                subdirectory: nil,
                localization: "en"
            )
        )
        let pluralTable = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: pluralTableURL),
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(
            Set(catalogStrings.keys),
            Set(englishTable.keys).union(pluralTable.keys)
        )
    }
}
