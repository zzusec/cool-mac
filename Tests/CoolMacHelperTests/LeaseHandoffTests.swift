import Testing
import CoolMacCore
@testable import CoolMacHelper

@Test func completedCommissioningRetainsTheUnextendedLeaseForTheNextPollAndRenewal() {
    let session = "commissioning-session"
    let handoff = LeaseHandoff.receive(phase: .system, commissioningCompleted: true,
                                      current: (.system, 105, session))
    #expect(handoff.mode == .system)
    #expect(handoff.until == 105)
    #expect(handoff.session == session)
    #expect(104 < handoff.until)
    #expect(!(106 < handoff.until))
}

@Test func commissioningHandoffDoesNotCreateAnOwnerOrExtendAnExpiredLease() {
    let handoff = LeaseHandoff.receive(phase: .system, commissioningCompleted: true,
                                      current: (.system, 0, nil))
    #expect(handoff.mode == .system)
    #expect(handoff.until == 0)
    #expect(handoff.session == nil)
}

@Test func faultsStillRevokeTheLeaseEvenAtTheCommissioningBoundary() {
    for completed in [false, true] {
        let handoff = LeaseHandoff.receive(phase: .fault, commissioningCompleted: completed,
                                          current: (.cool, 105, "active-session"))
        #expect(handoff.mode == .system)
        #expect(handoff.until == 0)
        #expect(handoff.session == nil)
    }
}

@Test func ordinaryWorkerStatusDoesNotChangeTheActiveControlLease() {
    let handoff = LeaseHandoff.receive(phase: .cooling, commissioningCompleted: false,
                                      current: (.cool, 105, "active-session"))
    #expect(handoff.mode == .cool)
    #expect(handoff.until == 105)
    #expect(handoff.session == "active-session")
}
