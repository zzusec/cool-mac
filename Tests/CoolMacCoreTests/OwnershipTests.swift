import Foundation
import Testing
@testable import CoolMacCore

@Test func entryTransitionRecoversEvenIfSystemChangedTheSeedTarget() {
    let journal = OwnershipRecord(allowedTargets: [3600], enteringManual: true, writtenAt: 100)
    #expect(journal.permitsManualRecovery(target: 3400))
}

@Test func establishedOwnershipDoesNotOverwriteForeignManualTarget() {
    let journal = OwnershipRecord(allowedTargets: [3200], enteringManual: false, writtenAt: 100)
    #expect(journal.permitsManualRecovery(target: 3200))
    #expect(!journal.permitsManualRecovery(target: 4000))
}

@Test func interruptedUpdateAcceptsOnlyPreviousOrNextOwnedTarget() {
    let journal = OwnershipRecord(allowedTargets: [3200, 3600], enteringManual: false, writtenAt: 100)
    #expect(journal.permitsManualRecovery(target: 3200))
    #expect(journal.permitsManualRecovery(target: 3600))
    #expect(!journal.permitsManualRecovery(target: 4000))
    #expect(!journal.permitsManualRecovery(target: .nan))
}

@Test func ownershipJournalRoundTripsWithoutLosingTransitionState() throws {
    let original = OwnershipRecord(allowedTargets: [3600], enteringManual: true, writtenAt: 100)
    let restored = try JSONDecoder().decode(OwnershipRecord.self, from: JSONEncoder().encode(original))
    #expect(restored.enteringManual)
    #expect(restored.allowedTargets == [3600])
    #expect(restored.permitsManualRecovery(target: 3400))
}
