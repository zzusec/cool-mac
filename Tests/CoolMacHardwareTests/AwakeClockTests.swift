import Testing
import CSMC
import CoolMacHardware

/// Liveness must be measured on a clock that stops while the whole system is
/// asleep. `ContinuousClock` keeps counting through sleep, so after a long
/// sleep every progress timestamp looks hours old; treating that as a stall
/// killed a healthy worker and latched a fault (2026-10-20).
@Test func awakeClockNeverExceedsContinuousClock() {
    let awake = AwakeClock.now
    let continuous = ContinuousClock.now
    #expect(awake.isFinite && continuous.isFinite)
    #expect(awake <= continuous)
    #expect(continuous - awake >= 0)
}

@Test func awakeClockAdvancesWhileTheMachineIsAwake() async throws {
    let first = AwakeClock.now
    try await Task.sleep(nanoseconds: 20_000_000)
    let second = AwakeClock.now
    #expect(second > first)
}

/// The gap between the two clocks is exactly the time spent asleep, so it must
/// be stable between two readings taken in the same awake period.
@Test func sleepGapIsStableWhileAwake() {
    let gapA = ContinuousClock.now - AwakeClock.now
    let gapB = ContinuousClock.now - AwakeClock.now
    #expect(abs(gapB - gapA) < 0.5)
}
