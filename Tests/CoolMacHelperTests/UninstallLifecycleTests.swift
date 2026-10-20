import Testing
@testable import CoolMacHelper

private enum InjectedFailure: Error { case stopped, untrusted, removal }

@Test func uninstallConfirmsRecoveryBeforeRemovingFilesOrState() throws {
    var events: [String] = []
    let removed = try SafeUninstall.run(
        verifyFiles: { events.append("verify") },
        stopAndRestore: { events.append("stop-and-confirm") },
        shouldRemove: { events.append("app-missing"); return true },
        removeFiles: { events.append("files") },
        removeState: { events.append("state") }
    )
    #expect(removed)
    #expect(events == ["verify", "stop-and-confirm", "app-missing", "verify", "files", "state"])
}

@Test func failedRecoveryPreservesAllFilesAndOwnershipState() {
    var removed = false
    #expect(throws: InjectedFailure.stopped) {
        try SafeUninstall.run(
            verifyFiles: {},
            stopAndRestore: { throw InjectedFailure.stopped },
            shouldRemove: { true },
            removeFiles: { removed = true },
            removeState: { removed = true }
        )
    }
    #expect(!removed)
}

@Test func returningAppCancelsCleanupAfterRecovery() throws {
    var removed = false
    let result = try SafeUninstall.run(
        verifyFiles: {},
        stopAndRestore: {},
        shouldRemove: { false },
        removeFiles: { removed = true },
        removeState: { removed = true }
    )
    #expect(!result)
    #expect(!removed)
}

@Test func changedOwnershipAfterRecoveryPreventsDeletion() {
    var checks = 0
    var removed = false
    #expect(throws: InjectedFailure.untrusted) {
        try SafeUninstall.run(
            verifyFiles: {
                checks += 1
                if checks == 2 { throw InjectedFailure.untrusted }
            },
            stopAndRestore: {},
            shouldRemove: { true },
            removeFiles: { removed = true },
            removeState: { removed = true }
        )
    }
    #expect(checks == 2)
    #expect(!removed)
}

@Test func failedFileRemovalDoesNotDiscardRecoveryState() {
    var stateRemoved = false
    #expect(throws: InjectedFailure.removal) {
        try SafeUninstall.run(
            verifyFiles: {},
            stopAndRestore: {},
            shouldRemove: { true },
            removeFiles: { throw InjectedFailure.removal },
            removeState: { stateRemoved = true }
        )
    }
    #expect(!stateRemoved)
}
