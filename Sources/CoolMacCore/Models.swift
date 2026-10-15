import Foundation

public enum Product {
    public static let name = "清凉风扇"
    public static let version = "1.1.4"
    /// Monotonic build number for update comparison. Never reused or decreased.
    public static let build = 6
    public static let bundleID = "local.hx10.coolmac"
    public static let service = "local.hx10.coolmac.helper"
    public static let helperPath = "/Library/PrivilegedHelperTools/local.hx10.coolmac.helper"
    public static let installToolPath = "/Library/PrivilegedHelperTools/local.hx10.coolmac.install"
    public static let manifestPath = "/Library/Application Support/CoolMac/identity.plist"
    public static let stateDirectory = "/var/db/CoolMac"
    /// Downloaded, signature-verified update packages. This directory is owned by
    /// the desktop user; the root install tool re-verifies the package after
    /// copying it into a root-private staging directory.
    public static let updateCacheDirectory = "Library/Application Support/CoolMac/Updates"
    public static let updateCacheDirectoryAbsolute = "/Users/hx10/Library/Application Support/CoolMac/Updates"
    public static let protocolVersion = 2
}

/// Fan speeds above this fraction of the rated maximum are never commanded by
/// this app, including boost. The system may still use its full range once
/// control is handed back.
public enum Enhancement {
    public static let steps = [0, 10, 20, 30, 40, 50, 60, 70, 80]
    public static let maximumPercent = 80
    public static let maximumManualFraction = 0.8

    public static func isValid(_ percent: Int) -> Bool { steps.contains(percent) }

    public static func title(_ percent: Int) -> String {
        percent == 0 ? "关闭" : "＋\(percent)%"
    }
}

public enum CoolingMode: String, Codable, CaseIterable, Sendable {
    case system, cool, boost

    public var title: String {
        switch self {
        case .system: "系统自动"
        case .cool: "凉爽自动"
        case .boost: "强力散热（2 分钟）"
        }
    }
}

public enum ControlPhase: String, Codable, Sendable {
    case monitoring, system, cooling, boosting, restoring, fault, unavailable
}

public struct TemperatureReading: Codable, Sendable, Equatable {
    public let key: String
    public let name: String
    public let celsius: Double
    public let group: String

    public init(key: String, name: String, celsius: Double, group: String) {
        self.key = key
        self.name = name
        self.celsius = celsius
        self.group = group
    }
}

public struct FanReading: Codable, Sendable, Equatable {
    public let id: Int
    public let actualRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let targetRPM: Double
    public let manual: Bool

    public init(id: Int, actualRPM: Double, minimumRPM: Double, maximumRPM: Double, targetRPM: Double, manual: Bool) {
        self.id = id
        self.actualRPM = actualRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM
        self.manual = manual
    }
}

public struct HardwareSnapshot: Codable, Sendable, Equatable {
    public let sampledAt: Double
    public let model: String
    public let temperatures: [TemperatureReading]
    public let fans: [FanReading]
    public let thermalPressure: Int
    public let supported: Bool
    public let issues: [String]

    public init(sampledAt: Double, model: String, temperatures: [TemperatureReading], fans: [FanReading], thermalPressure: Int, supported: Bool, issues: [String]) {
        self.sampledAt = sampledAt
        self.model = model
        self.temperatures = temperatures
        self.fans = fans
        self.thermalPressure = thermalPressure
        self.supported = supported
        self.issues = issues
    }

    public var hottest: Double? { temperatures.map(\.celsius).filter(\.isFinite).max() }
}

public struct ServiceStatus: Codable, Sendable, Equatable {
    public var version: Int = Product.protocolVersion
    public var available: Bool
    public var commissioned: Bool
    public var selectedMode: CoolingMode
    public var phase: ControlPhase
    public var message: String
    public var snapshot: HardwareSnapshot?
    public var updatedAt: Double
    public var guardianPID: Int32?
    public var workerPID: Int32?
    public var boostRemaining: Int?
    public var enhancement: Int
    /// The system's own target observed while automatic, used as the enhancement base.
    public var baselineRPM: Double?
    public var commandedRPM: Double?

    public init(available: Bool = false, commissioned: Bool = false, selectedMode: CoolingMode = .system, phase: ControlPhase = .unavailable, message: String = "后台组件尚未安装", snapshot: HardwareSnapshot? = nil, updatedAt: Double = Date().timeIntervalSince1970, guardianPID: Int32? = nil, workerPID: Int32? = nil, boostRemaining: Int? = nil, enhancement: Int = 0, baselineRPM: Double? = nil, commandedRPM: Double? = nil) {
        self.available = available
        self.commissioned = commissioned
        self.selectedMode = selectedMode
        self.phase = phase
        self.message = message
        self.snapshot = snapshot
        self.updatedAt = updatedAt
        self.guardianPID = guardianPID
        self.workerPID = workerPID
        self.boostRemaining = boostRemaining
        self.enhancement = enhancement
        self.baselineRPM = baselineRPM
        self.commandedRPM = commandedRPM
    }
}

public enum RequestOperation: String, Codable, Sendable {
    case status, select, renew, restore, commission
}

public struct ServiceRequest: Codable, Sendable {
    public var version: Int = Product.protocolVersion
    public let operation: RequestOperation
    public let session: String
    public let mode: CoolingMode?
    public let enhancement: Int?

    public init(operation: RequestOperation, session: String, mode: CoolingMode? = nil, enhancement: Int? = nil) {
        self.operation = operation
        self.session = session
        self.mode = mode
        self.enhancement = enhancement
    }
}

public struct ServiceResponse: Codable, Sendable {
    public let ok: Bool
    public let error: String?
    public let status: ServiceStatus

    public init(ok: Bool, error: String? = nil, status: ServiceStatus) {
        self.ok = ok
        self.error = error
        self.status = status
    }
}

public enum WorkerOperation: String, Codable, Sendable {
    case sample, select, renew, restore, commission, shutdown
}

public struct WorkerCommand: Codable, Sendable {
    public let operation: WorkerOperation
    public let mode: CoolingMode?
    public let enhancement: Int?
    public let deadline: Double

    public init(operation: WorkerOperation, mode: CoolingMode? = nil, enhancement: Int? = nil, deadline: Double = 0) {
        self.operation = operation
        self.mode = mode
        self.enhancement = enhancement
        self.deadline = deadline
    }
}

public struct WorkerEvent: Codable, Sendable {
    public let status: ServiceStatus
    public let progress: Double
    public let restored: Bool
    public let commissioningCompleted: Bool

    public init(status: ServiceStatus, progress: Double, restored: Bool = false, commissioningCompleted: Bool = false) {
        self.status = status
        self.progress = progress
        self.restored = restored
        self.commissioningCompleted = commissioningCompleted
    }
}
