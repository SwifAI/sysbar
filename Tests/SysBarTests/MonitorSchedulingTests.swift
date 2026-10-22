import XCTest
@testable import SysBar

final class MonitorSchedulingTests: XCTestCase {
    func testMonitorInstantClampsNegativeSecondsToZero() {
        XCTAssertEqual(MonitorInstant.seconds(-1), .zero)
    }

    func testMonitorInstantReturnsNilForReversedDuration() {
        XCTAssertNil(MonitorInstant.seconds(4).duration(since: .seconds(5)))
        XCTAssertEqual(
            MonitorInstant.seconds(5).duration(since: .seconds(4)),
            .seconds(1)
        )
    }

    func testMonitorInstantSupportsLargeMonotonicValues() {
        let earlier = MonitorInstant.seconds(Int64.max - 60)
        let later = MonitorInstant.seconds(Int64.max)

        XCTAssertGreaterThan(later, earlier)
        XCTAssertEqual(later.duration(since: earlier), .seconds(60))
    }

    func testInitialClosedStateSuspendsAllDetailWorkWithoutAlerts() {
        var state = MonitorScheduleState()

        XCTAssertEqual(state.workDue(at: .zero), [])
        XCTAssertFalse(state.isPanelOpen)
        XCTAssertFalse(state.alertsEnabled)
    }

    func testInitialOpenStateMakesAllDetailWorkDue() {
        var state = MonitorScheduleState(isPanelOpen: true)

        XCTAssertEqual(state.workDue(at: .zero), [.processes, .ports, .disk])
    }

    func testInitialClosedStateMakesPortsDueWhenAlertsAreEnabled() {
        var state = MonitorScheduleState(alertsEnabled: true)

        XCTAssertEqual(state.workDue(at: .zero), [.ports])
    }

    func testProcessesAreDueForEveryGrantedCollectionWhileOpen() {
        var state = MonitorScheduleState()
        state.panelDidOpen(at: .zero)

        XCTAssertTrue(state.workDue(at: .zero).contains(.processes))
        XCTAssertTrue(state.workDue(at: .zero).contains(.processes))
        XCTAssertTrue(state.workDue(at: .seconds(1)).contains(.processes))
    }

    func testClosingPanelDisablesProcessSampling() {
        var state = MonitorScheduleState()
        state.panelDidOpen(at: .zero)
        _ = state.workDue(at: .zero)
        state.panelDidClose(at: .seconds(1))

        XCTAssertFalse(state.workDue(at: .seconds(4)).contains(.processes))
        XCTAssertFalse(state.isPanelOpen)
    }

    func testStalePanelCloseCannotOverwriteNewerOpenState() {
        var state = MonitorScheduleState()
        state.panelDidOpen(at: .seconds(10))

        state.panelDidClose(at: .seconds(9))

        XCTAssertTrue(state.isPanelOpen)
    }

    func testStalePanelOpenCannotOverwriteNewerClosedState() {
        var state = MonitorScheduleState(isPanelOpen: true)
        state.panelDidClose(at: .seconds(10))

        state.panelDidOpen(at: .seconds(9))

        XCTAssertFalse(state.isPanelOpen)
    }

    func testOpenPortsUseExactFifteenSecondCadence() {
        var state = MonitorScheduleState(isPanelOpen: true)

        XCTAssertTrue(state.workDue(at: .zero).contains(.ports))
        XCTAssertFalse(state.workDue(at: .seconds(14)).contains(.ports))
        XCTAssertTrue(state.workDue(at: .seconds(15)).contains(.ports))
        XCTAssertFalse(state.workDue(at: .seconds(29)).contains(.ports))
        XCTAssertTrue(state.workDue(at: .seconds(30)).contains(.ports))
    }

    func testClosedPortsUseExactSixtySecondCadenceWithAlerts() {
        var state = MonitorScheduleState(alertsEnabled: true)

        XCTAssertTrue(state.workDue(at: .zero).contains(.ports))
        XCTAssertFalse(state.workDue(at: .seconds(59)).contains(.ports))
        XCTAssertTrue(state.workDue(at: .seconds(60)).contains(.ports))
    }

    func testClosedPortsRemainSuspendedWithoutAlerts() {
        var state = MonitorScheduleState()

        XCTAssertFalse(state.workDue(at: .zero).contains(.ports))
        XCTAssertFalse(state.workDue(at: .seconds(Int64.max)).contains(.ports))
    }

    func testClosingPanelUsesLastPortCollectionForClosedCadence() {
        var state = MonitorScheduleState(isPanelOpen: true, alertsEnabled: true)
        _ = state.workDue(at: .zero)
        state.panelDidClose(at: .seconds(1))

        XCTAssertFalse(state.workDue(at: .seconds(59)).contains(.ports))
        XCTAssertTrue(state.workDue(at: .seconds(60)).contains(.ports))
    }

    func testOpeningPanelImmediatelyRequestsStalePorts() {
        var state = MonitorScheduleState(alertsEnabled: true)
        _ = state.workDue(at: .zero)

        state.panelDidOpen(at: .seconds(15))

        XCTAssertTrue(state.workDue(at: .seconds(15)).contains(.ports))
    }

    func testOpeningPanelDoesNotDuplicateFreshPorts() {
        var state = MonitorScheduleState(alertsEnabled: true)
        _ = state.workDue(at: .zero)

        state.panelDidOpen(at: .seconds(14))

        XCTAssertFalse(state.workDue(at: .seconds(14)).contains(.ports))
        XCTAssertTrue(state.workDue(at: .seconds(15)).contains(.ports))
    }

    func testDiskUsesExactSixtySecondCadenceOnlyWhileOpen() {
        var state = MonitorScheduleState(isPanelOpen: true)

        XCTAssertTrue(state.workDue(at: .zero).contains(.disk))
        XCTAssertFalse(state.workDue(at: .seconds(59)).contains(.disk))
        XCTAssertTrue(state.workDue(at: .seconds(60)).contains(.disk))

        state.panelDidClose(at: .seconds(61))
        XCTAssertFalse(state.workDue(at: .seconds(120)).contains(.disk))
    }

    func testOpeningPanelImmediatelyRequestsStaleDisk() {
        var state = MonitorScheduleState(isPanelOpen: true)
        _ = state.workDue(at: .zero)
        state.panelDidClose(at: .seconds(1))

        state.panelDidOpen(at: .seconds(60))

        XCTAssertTrue(state.workDue(at: .seconds(60)).contains(.disk))
    }

    func testOpeningPanelDoesNotDuplicateFreshDisk() {
        var state = MonitorScheduleState(isPanelOpen: true)
        _ = state.workDue(at: .zero)
        state.panelDidClose(at: .seconds(1))

        state.panelDidOpen(at: .seconds(59))

        XCTAssertFalse(state.workDue(at: .seconds(59)).contains(.disk))
        XCTAssertTrue(state.workDue(at: .seconds(60)).contains(.disk))
    }

    func testEnablingAlertsWhileClosedMakesStalePortsDue() {
        var state = MonitorScheduleState(isPanelOpen: true)
        _ = state.workDue(at: .zero)
        state.panelDidClose(at: .seconds(1))

        state.setAlertsEnabled(true, at: .seconds(60))

        XCTAssertTrue(state.workDue(at: .seconds(60)).contains(.ports))
        XCTAssertTrue(state.alertsEnabled)
    }

    func testEnablingAlertsWhileClosedDoesNotDuplicateFreshPorts() {
        var state = MonitorScheduleState(isPanelOpen: true)
        _ = state.workDue(at: .zero)
        state.panelDidClose(at: .seconds(1))

        state.setAlertsEnabled(true, at: .seconds(59))

        XCTAssertFalse(state.workDue(at: .seconds(59)).contains(.ports))
        XCTAssertTrue(state.workDue(at: .seconds(60)).contains(.ports))
    }

    func testDisablingAlertsWhileClosedSuspendsPorts() {
        var state = MonitorScheduleState(alertsEnabled: true)
        _ = state.workDue(at: .zero)

        state.setAlertsEnabled(false, at: .seconds(60))

        XCTAssertFalse(state.workDue(at: .seconds(60)).contains(.ports))
    }

    func testStaleAlertDisableCannotOverwriteNewerEnabledState() {
        var state = MonitorScheduleState()
        state.setAlertsEnabled(true, at: .seconds(10))

        state.setAlertsEnabled(false, at: .seconds(9))

        XCTAssertTrue(state.alertsEnabled)
    }

    func testStaleAlertEnableCannotOverwriteNewerDisabledState() {
        var state = MonitorScheduleState(alertsEnabled: true)
        state.setAlertsEnabled(false, at: .seconds(10))

        state.setAlertsEnabled(true, at: .seconds(9))

        XCTAssertFalse(state.alertsEnabled)
    }

    func testReversedWorkInstantCreatesNoFalseDueWork() {
        var state = MonitorScheduleState(isPanelOpen: true)
        _ = state.workDue(at: .seconds(60))

        XCTAssertEqual(state.workDue(at: .seconds(59)), [])
    }

    func testDiscardedCollectionBecomesDueWithoutWaitingForCadence() {
        var state = MonitorScheduleState(isPanelOpen: true)
        let work = state.workDue(at: .zero)
        state.panelDidClose(at: .seconds(1))
        state.panelDidOpen(at: .seconds(2))

        state.invalidate(work, collectedAt: .zero)

        XCTAssertEqual(state.workDue(at: .seconds(2)), [.processes, .ports, .disk])
        XCTAssertEqual(state.workDue(at: .seconds(3)), [.processes])
    }

    func testDiscardedOldReservationDoesNotResetNewerCollectionCadence() {
        var state = MonitorScheduleState(isPanelOpen: true)
        let oldWork = state.workDue(at: .zero)
        _ = state.workDue(at: .seconds(60))

        state.invalidate(oldWork, collectedAt: .zero)

        XCTAssertEqual(state.workDue(at: .seconds(61)), [.processes])
    }

    func testCollectionGateStartsImmediatelyWhenIdle() {
        var gate = CollectionGate()

        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.hasPending)
    }

    func testCollectionGateFinishesWithoutRepeatWhenNothingIsPending() {
        var gate = CollectionGate()
        _ = gate.request()

        XCTAssertFalse(gate.finishedAndShouldRepeat())
        XCTAssertFalse(gate.isActive)
        XCTAssertFalse(gate.hasPending)
    }

    func testCollectionGateCoalescesAnyNumberOfRequestsToOneRepeat() {
        var gate = CollectionGate()
        XCTAssertTrue(gate.request())

        XCTAssertFalse(gate.request())
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.hasPending)

        XCTAssertTrue(gate.finishedAndShouldRepeat())
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.hasPending)

        XCTAssertFalse(gate.finishedAndShouldRepeat())
        XCTAssertFalse(gate.isActive)
    }

    func testCollectionGateIgnoresFinishWhileIdle() {
        var gate = CollectionGate()

        XCTAssertFalse(gate.finishedAndShouldRepeat())
        XCTAssertFalse(gate.isActive)
        XCTAssertFalse(gate.hasPending)
    }

    func testASummaryThatLandsDuringAProcessSamplePublishesOnceWithIt() {
        var barrier = PanelPublicationBarrier()
        barrier.processSampleStarted()

        XCTAssertFalse(barrier.resultApplied(), "held behind the running process sample")
        XCTAssertTrue(barrier.processSampleFinished(applied: true))
        XCTAssertFalse(barrier.isHoldingResult)
        XCTAssertFalse(barrier.isAwaitingProcesses)
    }

    func testAResultWithNoProcessSampleRunningPublishesImmediately() {
        var barrier = PanelPublicationBarrier()

        XCTAssertTrue(barrier.resultApplied())
        XCTAssertFalse(barrier.isHoldingResult)
    }

    func testADiscardedProcessSampleStillReleasesTheResultHeldBehindIt() {
        var barrier = PanelPublicationBarrier()
        barrier.processSampleStarted()
        XCTAssertFalse(barrier.resultApplied())

        XCTAssertTrue(barrier.processSampleFinished(applied: false))
    }

    func testADiscardedProcessSampleWithNothingHeldDoesNotPublish() {
        var barrier = PanelPublicationBarrier()
        barrier.processSampleStarted()

        XCTAssertFalse(barrier.processSampleFinished(applied: false))
    }

    func testAResultThatChangesNothingOnScreenWaitsForTheNextPublication() {
        var barrier = PanelPublicationBarrier()

        XCTAssertFalse(barrier.resultApplied(changesContent: false))
        XCTAssertTrue(barrier.isHoldingResult)
        XCTAssertFalse(barrier.tickStarted(), "the next tick's own publication carries it")

        barrier.processSampleStarted()
        XCTAssertFalse(barrier.resultApplied())
        XCTAssertTrue(barrier.processSampleFinished(applied: true))
        XCTAssertFalse(barrier.isHoldingResult)
    }

    func testAResultHeldBehindAStuckProcessSamplePublishesAtTheNextTick() {
        var barrier = PanelPublicationBarrier()
        barrier.processSampleStarted()
        XCTAssertFalse(barrier.resultApplied())

        XCTAssertTrue(barrier.tickStarted())
        XCTAssertFalse(barrier.tickStarted(), "published once, not on every tick")
        XCTAssertTrue(barrier.isAwaitingProcesses)
    }

    func testPublishingDropsAnyHeldResult() {
        var barrier = PanelPublicationBarrier()
        barrier.processSampleStarted()
        XCTAssertFalse(barrier.resultApplied())

        barrier.didPublish()

        XCTAssertFalse(barrier.isHoldingResult)
        XCTAssertFalse(barrier.processSampleFinished(applied: false))
    }
}

final class MonitorWatchSchedulingTests: XCTestCase {
    func testWatchSamplesProcessesOncePerMinuteOnlyWhileClosed() {
        var schedule = MonitorScheduleState(watchEnabled: true)
        XCTAssertTrue(schedule.watchProcessesDue(at: .zero))
        XCTAssertFalse(schedule.watchProcessesDue(at: .seconds(30)))
        XCTAssertTrue(schedule.watchProcessesDue(at: .seconds(60)))

        schedule.panelDidOpen(at: .seconds(120))
        XCTAssertFalse(schedule.watchProcessesDue(at: .seconds(180)))
    }

    func testWatchOffNeverSamplesProcessesOrDiskWhileClosed() {
        var schedule = MonitorScheduleState()
        XCTAssertFalse(schedule.watchProcessesDue(at: .zero))
        XCTAssertEqual(schedule.workDue(at: .zero), [])
    }

    func testWatchScansPortsEveryMinuteAndDiskEveryFiveMinutesWhileClosed() {
        var schedule = MonitorScheduleState(watchEnabled: true)
        XCTAssertEqual(schedule.workDue(at: .zero), [.ports, .disk])
        XCTAssertEqual(schedule.workDue(at: .seconds(60)), [.ports])
        XCTAssertEqual(schedule.workDue(at: .seconds(300)), [.ports, .disk])
    }

    func testAVerificationSampleRunsOnceRegardlessOfCadenceOrTheWatch() {
        var schedule = MonitorScheduleState()
        schedule.requestVerificationSample(slow: true)
        XCTAssertTrue(schedule.watchProcessesDue(at: .seconds(5)))
        XCTAssertFalse(schedule.watchProcessesDue(at: .seconds(6)), "one sample per request")
        XCTAssertEqual(schedule.workDue(at: .seconds(6)), [.ports, .disk])
        XCTAssertEqual(schedule.workDue(at: .seconds(7)), [])

        schedule.requestVerificationSample(slow: false)
        XCTAssertEqual(schedule.workDue(at: .seconds(8)), [], "only a slow request re-scans ports and disk")
    }
}
