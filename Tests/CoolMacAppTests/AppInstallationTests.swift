import Foundation
import Testing
import CoolMacCore
@testable import CoolMacApp

@Test func installedBackgroundOutageDoesNotOfferReinstallation() {
    #expect(!AppInstallation.shouldOfferInstaller(backgroundAvailable: false, fileExists: { _ in true }))
}

@Test func onlyMissingComponentsOfferInstallation() {
    for missing in [Product.helperPath, Product.installToolPath, Product.manifestPath,
                    "/Library/LaunchDaemons/\(Product.service).plist"] {
        #expect(AppInstallation.shouldOfferInstaller(backgroundAvailable: false, fileExists: { $0 != missing }))
        #expect(!AppInstallation.shouldOfferInstaller(backgroundAvailable: true, fileExists: { $0 != missing }))
    }
}

@Test func bundleReplacementUsesTheRunningBuildAndUncachedMetadata() throws {
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    let info = contents.appendingPathComponent("Info.plist")
    func write(version: String = Product.version, build: Int = Product.build) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleShortVersionString": version, "CFBundleVersion": String(build),
        ], format: .xml, options: 0)
        try data.write(to: info, options: .atomic)
    }
    try write()
    #expect(!AppInstallation.wasReplaced(at: bundle))
    try write(build: Product.build + 1)
    #expect(AppInstallation.wasReplaced(at: bundle))
    try write(version: "999.0.0")
    #expect(AppInstallation.wasReplaced(at: bundle))
    try write()
    #expect(!AppInstallation.wasReplaced(at: bundle))
    try Data("incomplete installation".utf8).write(to: info)
    #expect(!AppInstallation.wasReplaced(at: bundle))
    try FileManager.default.removeItem(at: info)
    #expect(!AppInstallation.wasReplaced(at: bundle))
}
