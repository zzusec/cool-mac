import Testing
@testable import CoolMacCore

/// A system shutdown, an OS upgrade or a power loss kills the controller before
/// it can finish its shutdown handshake, which leaves the ownership journal
/// behind. That is routine, not a control failure: releasing the fans and
/// verifying the readback is the whole recovery, so it must not latch the
/// takeover lock and force a fresh safety check.
@Test func leftoverOwnershipJournalWithoutRecordedFaultIsNotAFault() {
    #expect(StartupJournal.condition(hasOwnershipJournal: true, hasRecordedFault: false) == .interrupted)
}

/// A fault the failing session recorded stays latched, with or without the
/// journal: that is the case where the hardware or the handshake really failed.
@Test func recordedFaultKeepsTheTakeoverLock() {
    #expect(StartupJournal.condition(hasOwnershipJournal: true, hasRecordedFault: true) == .faulted)
    #expect(StartupJournal.condition(hasOwnershipJournal: false, hasRecordedFault: true) == .faulted)
}

@Test func nothingDurableLeftBehindIsClean() {
    #expect(StartupJournal.condition(hasOwnershipJournal: false, hasRecordedFault: false) == .clean)
}

@Test func interruptedMessageDiffersFromLatchedFaultMessage() {
    #expect(StartupJournal.interruptedMessage != StartupJournal.faultMessage(recorded: nil))
    #expect(!StartupJournal.interruptedMessage.contains("故障"))
}

@Test func faultMessageKeepsTheRecordedReasonOnOneLine() {
    let message = StartupJournal.faultMessage(recorded: "监督进程失联，已停止接管；\n需要重新安全自检\n")
    #expect(message == "上次控制发生故障：监督进程失联，已停止接管； 需要重新安全自检；请先恢复再重新安全自检")
}

@Test func faultMessageFallsBackWhenNothingWasRecorded() {
    let fallback = "上次控制发生故障；已停止接管，请先恢复再重新安全自检"
    #expect(StartupJournal.faultMessage(recorded: nil) == fallback)
    #expect(StartupJournal.faultMessage(recorded: "  \n\t ") == fallback)
}

@Test func faultMessageIsBounded() {
    let message = StartupJournal.faultMessage(recorded: String(repeating: "长", count: 400))
    #expect(message.count < 200)
    #expect(message.hasSuffix("；请先恢复再重新安全自检"))
}

@Test func restoringAutomaticHardwareDoesNotClearARecordedControlFault() {
    #expect(StartupJournal.phaseAfterRestore(hasRecordedFault: true) == .fault)
    #expect(StartupJournal.phaseAfterRestore(hasRecordedFault: false) == .system)
}
