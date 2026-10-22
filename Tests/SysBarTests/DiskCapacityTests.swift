import XCTest
@testable import SysBar

final class DiskCapacityTests: XCTestCase {
    func testReclaimableCapacityMatchesFinderWhenAvailable() {
        XCTAssertEqual(DiskAPI.availableBytes(important: 500, ordinary: 300, total: 1_000), 500)
    }

    func testFilesystemsWithoutImportantUsageCapacityUseOrdinaryFreeBytes() {
        XCTAssertEqual(DiskAPI.availableBytes(important: nil, ordinary: 300, total: 1_000), 300)
    }

    func testMissingCapacityIsUnknownRatherThanAFalseFullDisk() {
        XCTAssertNil(DiskAPI.availableBytes(important: nil, ordinary: nil, total: 1_000))
        XCTAssertEqual(DiskAPI.availableBytes(important: 0, ordinary: nil, total: 1_000), 0)
    }

    func testImpossibleImportantCapacityFallsBackToValidOrdinaryReading() {
        XCTAssertEqual(DiskAPI.availableBytes(important: -1, ordinary: 300, total: 1_000), 300)
        XCTAssertEqual(DiskAPI.availableBytes(important: 1_001, ordinary: 300, total: 1_000), 300)
    }

    func testImpossibleCapacityRemainsUnknownWhenNeitherReadingIsUsable() {
        XCTAssertNil(DiskAPI.availableBytes(important: -1, ordinary: -1, total: 1_000))
        XCTAssertNil(DiskAPI.availableBytes(important: nil, ordinary: 1_001, total: 1_000))
        XCTAssertNil(DiskAPI.availableBytes(important: 0, ordinary: 0, total: 0))
    }

    func testDiskSelectionPolicyRejectsExternalOnlyInventory() {
        let externalOnly = DiskSnapshot(
            volumes: [
                VolumeInfo(name: "Backup", totalGB: 1_000, freeGB: 5, isExternal: true)
            ]
        )

        XCTAssertNil(DiskPresentationPolicy.internalVolume(in: externalOnly))
    }
}
