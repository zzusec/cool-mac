import Foundation
import Testing
import CoolMacCore
@testable import CoolMacApp

private func commissioningStatus(sampledAt: Double = 100, supported: Bool = true) -> ServiceStatus {
    ServiceStatus(available: true, phase: .system, snapshot: HardwareSnapshot(
        sampledAt: sampledAt,
        model: "test",
        temperatures: [TemperatureReading(key: "test", name: "test", celsius: 65, group: "cpu")],
        fans: [FanReading(id: 0, actualRPM: 1200, minimumRPM: 1200, maximumRPM: 7200, targetRPM: 1200, manual: false)],
        thermalPressure: 0,
        supported: supported,
        issues: []
    ))
}

private func expectAutomaticStart(_ expected: Bool, using commissioning: inout ControlStartup,
                                  status: ServiceStatus, sourceLocation: SourceLocation = #_sourceLocation) {
    let starts = commissioning.shouldStart(status: status, now: 100)
    #expect(starts == expected, sourceLocation: sourceLocation)
}

@Test func firstReadyLaunchAutomaticallyStartsCommissioningWithoutAnotherAction() {
    var commissioning = ControlStartup()
    expectAutomaticStart(true, using: &commissioning, status: commissioningStatus())
    expectAutomaticStart(false, using: &commissioning, status: commissioningStatus())
}

@Test func temporaryStartupOutagesDoNotConsumeAutomaticCommissioning() {
    var commissioning = ControlStartup()
    var status = commissioningStatus()
    status.available = false
    expectAutomaticStart(false, using: &commissioning, status: status)
    status.available = true
    status.snapshot = nil
    expectAutomaticStart(false, using: &commissioning, status: status)
    expectAutomaticStart(false, using: &commissioning, status: commissioningStatus(sampledAt: 90))
    expectAutomaticStart(false, using: &commissioning, status: commissioningStatus(sampledAt: 110))
    expectAutomaticStart(true, using: &commissioning, status: commissioningStatus())
}

@Test func unsupportedHardwareDoesNotStartAutomaticCommissioning() {
    var commissioning = ControlStartup()
    expectAutomaticStart(false, using: &commissioning, status: commissioningStatus(supported: false))
}

@Test func validatedInstallationDoesNotRepeatCommissioning() {
    var commissioning = ControlStartup()
    var status = commissioningStatus()
    status.commissioned = true
    expectAutomaticStart(false, using: &commissioning, status: status)
}

@Test func faultsAndOtherControlPhasesDoNotAutomaticallyRearm() {
    for phase: ControlPhase in [.monitoring, .cooling, .boosting, .restoring, .fault, .unavailable] {
        var commissioning = ControlStartup()
        var status = commissioningStatus()
        status.phase = phase
        expectAutomaticStart(false, using: &commissioning, status: status)
    }
}

@Test func failedAttemptIsNotAutomaticallyRetriedAfterReconnection() {
    var commissioning = ControlStartup()
    expectAutomaticStart(true, using: &commissioning, status: commissioningStatus())
    var failed = commissioningStatus()
    failed.phase = .fault
    expectAutomaticStart(false, using: &commissioning, status: failed)
    expectAutomaticStart(false, using: &commissioning, status: commissioningStatus())
}

@Test func preexistingFaultRequiresManualVerificationEvenAfterSystemRestore() {
    var commissioning = ControlStartup()
    var status = commissioningStatus()
    status.phase = .fault
    expectAutomaticStart(false, using: &commissioning, status: status)
    status.phase = .system
    expectAutomaticStart(false, using: &commissioning, status: status)
}

@Test func explicitSystemSelectionOrManualVerificationPreventsAutomaticStart() {
    var commissioning = ControlStartup()
    commissioning.cancel()
    expectAutomaticStart(false, using: &commissioning, status: commissioningStatus())
    var status = commissioningStatus()
    status.commissioned = true
    let mode = commissioning.modeToApply(status: status, preferredMode: .cool)
    #expect(mode == nil)
}

@Test func faultedValidatedInstallationDoesNotResumeAfterSystemRestore() {
    var startup = ControlStartup()
    var status = commissioningStatus()
    status.commissioned = true
    status.phase = .fault
    expectAutomaticStart(false, using: &startup, status: status)
    status.phase = .system
    let mode = startup.modeToApply(status: status, preferredMode: .cool)
    #expect(mode == nil)
}

@Test func commissioningCompletionConsumesStartupModeBeforeAConnectionOutage() {
    var startup = ControlStartup()
    var status = commissioningStatus()
    expectAutomaticStart(true, using: &startup, status: status)
    status.commissioned = true
    startup.didCompleteCommissioning()
    status.available = false
    let disconnected = startup.modeToApply(status: status, preferredMode: .cool)
    #expect(disconnected == nil)
    status.available = true
    let reconnected = startup.modeToApply(status: status, preferredMode: .cool)
    #expect(reconnected == nil)
}

@Test func validatedInstallationAppliesTheSavedModeOnlyOnceUnlessWoken() {
    var startup = ControlStartup()
    var status = commissioningStatus()
    status.commissioned = true
    let initial = startup.modeToApply(status: status, preferredMode: .cool)
    #expect(initial == .cool)
    let reconnected = startup.modeToApply(status: status, preferredMode: .cool)
    #expect(reconnected == nil)
    startup.didWake()
    let woken = startup.modeToApply(status: status, preferredMode: .cool)
    #expect(woken == .cool)
}

@Test func savedSystemModeIsNotChangedByStartup() {
    var startup = ControlStartup()
    var status = commissioningStatus()
    status.commissioned = true
    let initial = startup.modeToApply(status: status, preferredMode: .system)
    #expect(initial == nil)
    let subsequent = startup.modeToApply(status: status, preferredMode: .cool)
    #expect(subsequent == nil)
}

@Test func cleanupAfterAFailedSelectionCannotUnlockAutomaticCommissioningInANewSession() {
    var status = commissioningStatus()
    status.phase = .fault
    status.phase = StartupJournal.phaseAfterRestore(hasRecordedFault: true)
    var restarted = ControlStartup()
    expectAutomaticStart(false, using: &restarted, status: status)
    #expect(status.phase == .fault)
}
