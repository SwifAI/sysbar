import Darwin
import Foundation
import XCTest
@testable import SysBar

final class ProcessSamplerTests: XCTestCase {
    func testCPUTimesAreMachTicksSoTwoBusyCoresReadAsTwoHundredPercentOnAppleSilicon() {
        let appleSilicon = mach_timebase_info_data_t(numer: 125, denom: 3)
        // Two seconds of CPU in one second of wall time, in 24 MHz ticks.
        let ticks: UInt64 = 2_000_000_000 * 3 / 125
        XCTAssertEqual(ProcessSampler.cpuPercent(deltaTicks: ticks, elapsedSec: 1, timebase: appleSilicon), 200, accuracy: 0.001)
        let nanosecondTimebase = mach_timebase_info_data_t(numer: 1, denom: 1)
        XCTAssertEqual(ProcessSampler.cpuPercent(deltaTicks: 2_000_000_000, elapsedSec: 1, timebase: nanosecondTimebase), 200, accuracy: 0.001)
        XCTAssertEqual(ProcessSampler.cpuPercent(deltaTicks: 10, elapsedSec: 0, timebase: appleSilicon), 0)
    }

    func testTheBaselineSurvivesTheAttentionWatchsOneMinuteCadence() {
        XCTAssertGreaterThan(ProcessSampler.maxDeltaWindowSec, MonitorScheduleState.watchProcessCadence.secondsValue * 2)
    }

    /// Against the real kernel: a thread spinning for a second must show as
    /// most of a core for this process, not a few percent.
    func testABusyThreadInThisProcessReadsAsMostOfACore() async throws {
        let sampler = ProcessSampler()
        _ = await sampler.sampleProcessesResult()
        let deadline = Date().addingTimeInterval(1)
        let spinner = Thread {
            var x = 0.0
            while Date() < deadline { x = sin(x + 1) }
            if x > 2 { print(x) }
        }
        spinner.start()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let samples = try await sampler.sampleProcessesResult().get()
        let own = try XCTUnwrap(samples.first { $0.pid == getpid() })
        XCTAssertGreaterThan(own.cpuPercent, 50, "a spinning thread is about 100%; a units error reads about 2%")
        XCTAssertLessThan(own.cpuPercent, 1_000)
    }

    /// Opening the popover right after a watch sample used to take the next
    /// sample milliseconds later. Over that window this process is on-CPU
    /// doing the sampling itself, so an idle SysBar read about 100%.
    func testBackToBackSamplesRepeatTheLastFullWindowInsteadOfReadingTheSamplerItself() async throws {
        let sampler = ProcessSampler()
        _ = await sampler.sampleProcessesResult()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let full = try await sampler.sampleProcessesResult().get()
        let immediate = try await sampler.sampleProcessesResult().get()
        let fullOwn = try XCTUnwrap(full.first { $0.pid == getpid() })
        let immediateOwn = try XCTUnwrap(immediate.first { $0.pid == getpid() })
        XCTAssertLessThan(immediateOwn.cpuPercent, 50, "an idle process must not read as a full core over a few milliseconds")
        XCTAssertEqual(immediateOwn.cpuPercent, fullOwn.cpuPercent, accuracy: 0.001)
    }

    func testTheMinimumWindowIsShorterThanThePopoverTickSoOpenPanelSamplesStayFresh() {
        XCTAssertGreaterThanOrEqual(ProcessSampler.minDeltaWindowSec, 0.5)
        XCTAssertLessThan(ProcessSampler.minDeltaWindowSec, 3)
    }
}

private extension Duration {
    var secondsValue: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
