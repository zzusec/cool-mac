import Foundation
import CoolMacCore

enum AppInstallation {
    static func shouldOfferInstaller(
        backgroundAvailable: Bool,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard !backgroundAvailable else { return false }
        return [Product.helperPath, Product.installToolPath, Product.manifestPath,
                "/Library/LaunchDaemons/\(Product.service).plist"].contains { !fileExists($0) }
    }

    static func matches(at bundle: URL, version: String, build: Int) -> Bool {
        guard let installed = metadata(at: bundle) else { return false }
        return installed.version == version && installed.build == String(build)
    }

    static func wasReplaced(at bundle: URL) -> Bool {
        guard let installed = metadata(at: bundle) else { return false }
        return installed.build != String(Product.build) || installed.version != Product.version
    }

    private static func metadata(at bundle: URL) -> (version: String, build: String)? {
        // Bundle caches Info.plist; read fresh bytes and compare to the running
        // executable's compiled-in version, not to another file on disk.
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let build = info["CFBundleVersion"] as? String,
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return (version, build)
    }
}
