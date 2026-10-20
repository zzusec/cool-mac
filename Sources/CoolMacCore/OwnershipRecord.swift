/// A durable journal distinguishes the short manual-entry transition from
/// established ownership. During entry, the system may change its target between
/// the seed and mode write; a crash must still release our newly entered mode.
public struct OwnershipRecord: Codable, Sendable {
    public let allowedTargets: [Double]
    public let enteringManual: Bool
    public let writtenAt: Double

    public init(allowedTargets: [Double], enteringManual: Bool, writtenAt: Double) {
        self.allowedTargets = allowedTargets
        self.enteringManual = enteringManual
        self.writtenAt = writtenAt
    }

    public func permitsManualRecovery(target: Double) -> Bool {
        guard target.isFinite, target >= 0 else { return false }
        return enteringManual || allowedTargets.contains { $0.isFinite && abs($0 - target) <= 3 }
    }
}
