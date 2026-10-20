import Foundation
import Testing
import CoolMacCore
import CoolMacUpdates
@testable import CoolMacApp

@MainActor
private final class FetchGate {
    var calls = 0
    var continuation: CheckedContinuation<VerifiedUpdate?, any Error>?

    func fetch() async throws -> VerifiedUpdate? {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: VerifiedUpdate?) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private struct UpdateFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let update: VerifiedUpdate
    let gate = FetchGate()
    let coordinator: UpdateCoordinator

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let package = directory.appendingPathComponent("download.pkg")
        try Data("fixture-only; never passed to a real installer".utf8).write(to: package)
        let manifest = UpdateManifest(bundleID: Product.bundleID, version: "999.1.0", build: Product.build + 1,
                                      minimumSystemVersion: "14.0", architectures: ["arm64"],
                                      assetURL: URL(string: "https://example.com/update.pkg")!,
                                      assetBytes: 1, assetSHA256: String(repeating: "0", count: 64), notes: "test")
        update = VerifiedUpdate(manifest: manifest, envelope: Data("exact signed envelope fixture".utf8), packageURL: package)
        suite = "CoolMacUpdateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        let gate = self.gate
        coordinator = UpdateCoordinator(defaults: defaults, downloadDirectory: directory,
                                        fetch: { _, _ in try await gate.fetch() })
    }

    func clean() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func ready() async {
        coordinator.check(autoInstall: false)
        await eventually { gate.continuation != nil }
        gate.finish(update)
        await eventually { coordinator.state == .ready(update.manifest) }
    }
}

@MainActor
private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(condition(), sourceLocation: sourceLocation)
}

@MainActor @Test func automaticUpdatesDefaultOnAndDownloadClosureHonorsLivePreference() async throws {
    let f = try UpdateFixture()
    defer { f.clean() }
    let c = f.coordinator
    #expect(c.automaticEnabled)
    var deliveries = 0
    var automatic = false
    c.onVerifiedUpdate = { _, value in deliveries += 1; automatic = value }
    c.checkIfDue()
    c.checkIfDue()
    c.check(autoInstall: true)
    await eventually { f.gate.continuation != nil }
    #expect(f.gate.calls == 1)
    c.automaticEnabled = false
    f.gate.finish(f.update)
    await eventually { c.state == .ready(f.update.manifest) }
    #expect(deliveries == 0)
    c.check(autoInstall: true)
    #expect(deliveries == 1)
    #expect(!automatic)
    c.automaticEnabled = true
    c.checkIfDue()
    #expect(deliveries == 1) // The actual background attempt consumed the interval.
}

@MainActor @Test func automaticDeliveryReleasesCheckLockBeforeInstallAndKeepsSingleFlight() async throws {
    let f = try UpdateFixture()
    defer { f.clean() }
    let c = f.coordinator
    var applyCount = 0
    var confirmation: CheckedContinuation<Bool, Never>?
    var installation: Task<Void, Never>?
    c.onVerifiedUpdate = { manifest, automatic in
        #expect(automatic)
        installation = Task { @MainActor in
            await c.install(manifest, automatic: automatic, prepare: {}, apply: { id in
                applyCount += 1
                let envelope = f.directory.appendingPathComponent("\(id.uuidString.lowercased()).json")
                let stagedEnvelope = try Data(contentsOf: envelope)
                #expect(stagedEnvelope == f.update.envelope)
            }, confirm: { _, _ in await withCheckedContinuation { confirmation = $0 } })
        }
    }
    c.checkIfDue()
    await eventually { f.gate.continuation != nil }
    f.gate.finish(f.update)
    await eventually { confirmation != nil }
    #expect(c.state == .installing)
    #expect(c.requiresInstallConfirmation)
    c.check(autoInstall: true)
    c.checkIfDue()
    await c.install(f.update.manifest, prepare: {}, apply: { _ in applyCount += 1 })
    #expect(applyCount == 1)
    #expect(f.gate.calls == 1)
    confirmation?.resume(returning: true)
    await installation?.value
    #expect(c.state == .installed(f.update.manifest.version))
    #expect(!c.requiresInstallConfirmation)
}

@MainActor @Test func disablingAutomaticDuringRestoreLeavesReadyAndManualStillInstalls() async throws {
    let f = try UpdateFixture()
    defer { f.clean() }
    let c = f.coordinator
    await f.ready()
    var applies = 0
    await c.install(f.update.manifest, automatic: true, prepare: { c.automaticEnabled = false },
                    apply: { _ in applies += 1 })
    #expect(applies == 0)
    #expect(c.state == .ready(f.update.manifest))
    await c.install(f.update.manifest, prepare: {}, apply: { _ in applies += 1 }, confirm: { _, _ in true })
    #expect(applies == 1)
    #expect(c.state == .installed(f.update.manifest.version))
}

private struct UpdateTestError: LocalizedError {
    var errorDescription: String? { "test rejection" }
}

@MainActor @Test func restoreAndApplyFailuresStayVisibleWithoutAuthorizationFallback() async throws {
    for restoreFailure in [true, false] {
        let f = try UpdateFixture()
        defer { f.clean() }
        let c = f.coordinator
        await f.ready()
        var applies = 0
        await c.install(f.update.manifest, prepare: { if restoreFailure { throw UpdateTestError() } },
                        apply: { _ in applies += 1; throw UpdateTestError() })
        #expect(applies == (restoreFailure ? 0 : 1))
        #expect(c.state == .failed("test rejection"))
        #expect(c.needsAttention)
        #expect(c.requiresInstallConfirmation == !restoreFailure)
        c.check(autoInstall: false)
        await eventually { f.gate.continuation != nil }
        f.gate.finish(nil)
        await eventually { c.state == .upToDate }
        #expect(!c.needsAttention)
    }
}

@MainActor @Test func busyManualCheckDoesNotConsumeNextAutomaticAttemptAndDisabledDoesNotFetch() async throws {
    let f = try UpdateFixture()
    defer { f.clean() }
    let c = f.coordinator
    c.automaticEnabled = false
    c.checkIfDue()
    #expect(c.state == .idle)
    c.check(autoInstall: false)
    await eventually { f.gate.continuation != nil }
    c.automaticEnabled = true
    c.checkIfDue()
    f.gate.finish(nil)
    await eventually { c.state == .upToDate }
    c.checkIfDue()
    await eventually { f.gate.calls == 2 }
    f.gate.finish(nil)
    await eventually { c.state == .upToDate }
}

@MainActor @Test func missingInstallCompletionStaysUnconfirmedEvenAfterAnotherCheck() async throws {
    let f = try UpdateFixture()
    defer { f.clean() }
    let c = f.coordinator
    await f.ready()
    await c.install(f.update.manifest, prepare: {}, apply: { _ in }, confirm: { _, _ in false })
    guard case .failed = c.state else { Issue.record("Missing completion must fail"); return }
    #expect(c.requiresInstallConfirmation)
    c.check(autoInstall: false)
    await eventually { f.gate.continuation != nil }
    f.gate.finish(nil)
    await eventually { c.state == .upToDate }
    #expect(c.requiresInstallConfirmation)
}

@MainActor @Test func successfulInstallationRequiresFreshExactVersionBuildAndFinalLog() throws {
    let f = try UpdateFixture()
    defer { f.clean() }
    let bundle = f.directory.appendingPathComponent("Test.app")
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info = contents.appendingPathComponent("Info.plist")
    let log = f.directory.appendingPathComponent("result.log")
    let m = f.update.manifest
    func write(_ version: String, _ build: Int) throws {
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version,
                                                              "CFBundleVersion": String(build)],
                                          format: .xml, options: 0).write(to: info, options: .atomic)
    }
    func completed() -> Bool { UpdateCoordinator.installationCompleted(bundle: bundle, log: log, manifest: m) }
    try write(Product.version, Product.build)
    #expect(!completed())
    try "安装完成：/Applications/\(Product.name).app 已更新到 \(m.version)（build \(m.build)）\n".write(to: log, atomically: true, encoding: .utf8)
    #expect(!completed())
    try write(m.version, m.build - 1)
    #expect(!completed())
    try write(m.version, m.build)
    #expect(completed())
    try "installer: package payload copied\n".write(to: log, atomically: true, encoding: .utf8)
    #expect(!completed())
    try Data("broken".utf8).write(to: info, options: .atomic)
    #expect(!completed())
    try FileManager.default.removeItem(at: info)
    #expect(!completed())
}
