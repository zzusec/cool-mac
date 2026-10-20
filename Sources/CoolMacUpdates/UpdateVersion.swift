import Foundation

/// Version and build comparison for the update decision.
public enum UpdateVersion {
    /// Decides whether the manifest offers a genuine upgrade over what is running.
    ///
    /// Rules: both versions must be dotted numeric, the offered version must not
    /// be lower than the current one, and the offered build must strictly
    /// increase. A downgrade or an unchanged build throws
    /// `UpdateError.notNewerThanCurrent` instead of returning `false`, so the
    /// caller cannot mistake "not an upgrade" for "no information".
    public static func isNewer(manifest: UpdateManifest, currentVersion: String, currentBuild: Int) throws -> Bool {
        let offered = try parse(manifest.version)
        let current = try parse(currentVersion)
        guard compare(offered, current) >= 0, manifest.build > currentBuild else {
            throw UpdateError.notNewerThanCurrent(currentVersion: currentVersion, currentBuild: currentBuild)
        }
        return true
    }

    /// Parses a dotted numeric version into its segments.
    ///
    /// Rejects empty segments, signs, non-ASCII digits and anything that is not
    /// `[0-9]+(\.[0-9]+)*`.
    public static func parse(_ text: String) throws -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UpdateError.invalidVersionFormat(text) }
        let segments = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { throw UpdateError.invalidVersionFormat(text) }
        var values: [Int] = []
        values.reserveCapacity(segments.count)
        for segment in segments {
            guard !segment.isEmpty else { throw UpdateError.invalidVersionFormat(text) }
            guard segment.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw UpdateError.invalidVersionFormat(text)
            }
            guard let value = Int(segment) else { throw UpdateError.invalidVersionFormat(text) }
            values.append(value)
        }
        return values
    }

    /// Numeric comparison, segment by segment, with missing segments read as 0
    /// (so `1.2` and `1.2.0` are equal). Returns -1, 0 or 1.
    static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    /// Compares two version strings, throwing on malformed input.
    static func compare(_ lhs: String, _ rhs: String) throws -> Int {
        try compare(parse(lhs), parse(rhs))
    }
}
