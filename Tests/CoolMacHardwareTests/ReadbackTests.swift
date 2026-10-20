import Testing
import CoolMacHardware

@Test func delayedAcknowledgementIsPolledWithoutRewriting() throws {
    var clock = 0.0
    var reads = 0
    let actual = try Readback.verify(target: 1800, now: { clock }, pause: { clock += 0.02 }) {
        reads += 1
        return reads >= 4 ? 1800 : 0
    }
    #expect(actual == 1800)
    #expect(reads == 4)
    #expect(clock < 0.4)
}

@Test func permanentMismatchHasBoundedFailure() {
    var clock = 0.0
    #expect(throws: HardwareError.self) {
        try Readback.verify(target: 1800, now: { clock }, pause: { clock += 0.02 }) { 0 }
    }
    #expect(clock >= 0.4 && clock <= 0.43)
}

@Test func modeZeroCannotAcceptManualOneAsRpmTolerance() {
    var clock = 0.0
    #expect(throws: HardwareError.self) {
        try Readback.verify(target: 0, tolerance: 0, now: { clock }, pause: { clock += 0.02 }) { 1 }
    }
}

@Test func transientAutomaticModeDoesNotConfirmStableRecovery() {
    var clock = 0.0
    #expect(throws: HardwareError.self) {
        try Readback.confirmStable(target: 0, now: { clock }, pause: { clock += 0.05 }) { clock < 0.2 ? 0 : 1 }
    }
}

@Test func stableAutomaticModeIsObservedForTheWholeWindow() throws {
    var clock = 0.0
    try Readback.confirmStable(target: 0, now: { clock }, pause: { clock += 0.05 }) { 0 }
    #expect(clock >= 1)
}

@Test func invalidReadbackDoesNotBecomeSuccess() {
    #expect(throws: HardwareError.self) {
        try Readback.verify(target: 1800) { .nan }
    }
}
