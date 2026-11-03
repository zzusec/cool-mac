import Testing
import CoolMacCore
import CoolMacHardware
@testable import CoolMacApp

private enum ModeSamplingFailure: Error { case disconnected }

@MainActor @Test func modeSelectionWaitsForWorkerAcknowledgmentInsteadOfTheRequestReceipt() async throws {
    let initial = ServiceStatus(available: true, commissioned: true, phase: .system)
    var samples = 0
    let confirmed = try await ModeSelection.confirm(.cool, initial: initial, sample: {
        samples += 1
        if samples < 3 { return initial }
        return ServiceStatus(available: true, commissioned: true, selectedMode: .cool, phase: .cooling)
    }, pause: {})
    #expect(samples == 3)
    #expect(confirmed.selectedMode == .cool)
    #expect(confirmed.phase == .cooling)
}

@MainActor @Test func coolModeBelowTheTemperatureThresholdIsStillAnAcknowledgedSelection() async throws {
    let initial = ServiceStatus(available: true, commissioned: true, selectedMode: .cool, phase: .system)
    var sampled = false
    let confirmed = try await ModeSelection.confirm(.cool, initial: initial, sample: {
        sampled = true
        return initial
    }, pause: {})
    #expect(!sampled)
    #expect(confirmed.selectedMode == .cool)
}

@MainActor @Test func modeSelectionDoesNotReportSuccessForFaultedOrRestoringStatus() async throws {
    let fault = ServiceStatus(available: true, commissioned: true, selectedMode: .cool, phase: .fault, message: "fixture fault")
    await #expect(throws: HardwareError.self) {
        try await ModeSelection.confirm(.cool, initial: fault, sample: { fault }, pause: {})
    }
    let restoring = ServiceStatus(available: true, commissioned: true, selectedMode: .cool, phase: .restoring)
    await #expect(throws: HardwareError.self) {
        try await ModeSelection.confirm(.cool, initial: restoring, sample: { restoring }, pause: {})
    }
}

@MainActor @Test func missingModeAcknowledgmentStopsAtTheBoundedDeadline() async throws {
    let initial = ServiceStatus(available: true, commissioned: true, phase: .system)
    var samples = 0
    await #expect(throws: HardwareError.self) {
        try await ModeSelection.confirm(.cool, initial: initial, sample: {
            samples += 1
            return initial
        }, pause: {})
    }
    #expect(samples == 14)
}

@MainActor @Test func modeAcknowledgmentDoesNotRetryTransportFailures() async throws {
    let initial = ServiceStatus(available: true, commissioned: true, phase: .system)
    var samples = 0
    await #expect(throws: ModeSamplingFailure.disconnected) {
        try await ModeSelection.confirm(.cool, initial: initial, sample: {
            samples += 1
            throw ModeSamplingFailure.disconnected
        }, pause: {})
    }
    #expect(samples == 1)
}

@MainActor @Test func supersededModeSelectionCanCancelTheAcknowledgmentWait() async throws {
    let initial = ServiceStatus(available: true, commissioned: true, phase: .system)
    await #expect(throws: CancellationError.self) {
        try await ModeSelection.confirm(.cool, initial: initial, sample: {
            throw CancellationError()
        }, pause: {})
    }
}
