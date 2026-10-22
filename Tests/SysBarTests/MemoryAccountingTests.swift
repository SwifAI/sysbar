import XCTest
import Darwin
@testable import SysBar

final class MemoryAccountingTests: XCTestCase {
    func testOlderKernelRevisionsDecodeWhenBuiltWithANewerSDK() throws {
        // Revision 1 and 2 return 38 and 40 integer words. SDK 27 adds more
        // trailing counters, but all memory-accounting fields are in this prefix.
        for count in [mach_msg_type_number_t(38), 40] {
            let snapshot = try MemoryAPI.snapshot(
                from: accountingStatistics(),
                count: count,
                totalRAMBytes: 16 * Bytes.gb,
                pageSize: 16_384
            ).get()

            XCTAssertEqual(snapshot.usedGB, 6)
            XCTAssertEqual(snapshot.freeMB, 10 * 1_024)
            XCTAssertEqual(snapshot.totalGB, 16)
        }
    }

    func testMinimumPrefixIncludesTheEntireLastRequiredField() throws {
        let endOffset = try XCTUnwrap(
            MemoryLayout<vm_statistics64_data_t>.offset(of: \.internal_page_count)
        ) + MemoryLayout<natural_t>.size
        XCTAssertEqual(
            Int(MemoryAPI.requiredStatisticsCount) * MemoryLayout<integer_t>.size,
            endOffset
        )
        let snapshot = try MemoryAPI.snapshot(
            from: accountingStatistics(),
            count: MemoryAPI.requiredStatisticsCount,
            totalRAMBytes: 16 * Bytes.gb,
            pageSize: 16_384
        ).get()
        XCTAssertEqual(snapshot.usedGB, 6)
    }

    func testPrefixMissingTheLastRequiredFieldRemainsUnavailable() {
        XCTAssertThrowsError(try MemoryAPI.snapshot(
            from: accountingStatistics(),
            count: MemoryAPI.requiredStatisticsCount - 1,
            totalRAMBytes: 16 * Bytes.gb,
            pageSize: 16_384
        ).get())
    }

    func testLegacyPrefixCannotTurnMissingAccountingFieldsIntoZeroUsage() {
        // Revision 0 stops before compressor and anonymous-page accounting.
        XCTAssertThrowsError(try MemoryAPI.snapshot(
            from: vm_statistics64_data_t(),
            count: 24,
            totalRAMBytes: 16 * Bytes.gb,
            pageSize: 16_384
        ).get())
    }

    func testCurrentSDKStatisticsAndImpossibleSampleValidationRemainSupported() throws {
        let count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let snapshot = try MemoryAPI.snapshot(
            from: accountingStatistics(),
            count: count,
            totalRAMBytes: 16 * Bytes.gb,
            pageSize: 16_384
        ).get()
        XCTAssertEqual(snapshot.usedGB, 6)
        XCTAssertThrowsError(try MemoryAPI.snapshot(
            from: accountingStatistics(),
            count: count,
            totalRAMBytes: Bytes.gb,
            pageSize: 16_384
        ).get())
    }

    private func accountingStatistics() -> vm_statistics64_data_t {
        var stats = vm_statistics64_data_t()
        stats.internal_page_count = 262_144
        stats.purgeable_count = 65_536
        stats.wire_count = 131_072
        stats.compressor_page_count = 65_536
        return stats
    }

    func testUsedBytesMatchesActivityMonitorFormula() {
        // 4 GiB anonymous, 1 GiB purgeable, 2 GiB wired, 1 GiB compressed @ 16 KiB pages
        let used = MemoryAPI.usedBytes(
            internalPages: 262_144,
            purgeablePages: 65_536,
            wiredPages: 131_072,
            compressorPages: 65_536,
            pageSize: 16_384
        )
        XCTAssertEqual(used, 6 * Bytes.gb)
    }

    func testUsedBytesClampsWhenPurgeableExceedsInternal() {
        // Non-atomic host_statistics64 snapshot: purgeable > internal must
        // clamp App Memory to zero, never wrap toward 2^64 bytes (the
        // "17179869184 GB used / 0 MB available / Peak 100%" regression).
        let used = MemoryAPI.usedBytes(
            internalPages: 100,
            purgeablePages: 200,
            wiredPages: 50,
            compressorPages: 25,
            pageSize: 16_384
        )
        XCTAssertEqual(used, 75 * 16_384)
    }

    func testUsedBytesEqualInternalAndPurgeableYieldsZeroAppMemory() {
        // Boundary between the clamp and the subtraction: equal nonzero counts
        // must produce zero app memory, not underflow or one stray page.
        let used = MemoryAPI.usedBytes(
            internalPages: 500,
            purgeablePages: 500,
            wiredPages: 50,
            compressorPages: 25,
            pageSize: 16_384
        )
        XCTAssertEqual(used, 75 * 16_384)
    }

    func testUsedBytesScalesByIntelPageSize() {
        // Same counts as the Activity Monitor test at Intel's 4 KiB pages: the
        // result must scale by the passed page size, not a hard-coded 16 KiB.
        let used = MemoryAPI.usedBytes(
            internalPages: 262_144,
            purgeablePages: 65_536,
            wiredPages: 131_072,
            compressorPages: 65_536,
            pageSize: 4_096
        )
        XCTAssertEqual(used, 393_216 * 4_096)
    }

    func testUsedBytesMaxCountsCannotOverflow() {
        // Worst case: three saturated 32-bit natural_t counts at 16 KiB pages
        // stays far below UInt64.max — the multiply must not trap.
        let maxCount = UInt64(UInt32.max)
        let used = MemoryAPI.usedBytes(
            internalPages: maxCount,
            purgeablePages: 0,
            wiredPages: maxCount,
            compressorPages: maxCount,
            pageSize: 16_384
        )
        XCTAssertEqual(used, 3 * maxCount * 16_384)
    }
}
