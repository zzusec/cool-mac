import Foundation
import CoolMacCore
import CoolMacHardware

enum ModeSelection {
    @MainActor
    static func confirm(
        _ mode: CoolingMode,
        initial: ServiceStatus,
        sample: () async throws -> ServiceStatus,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) }
    ) async throws -> ServiceStatus {
        var status = initial
        for attempt in 0..<15 {
            if status.phase == .fault || status.phase == .unavailable { throw HardwareError(status.message) }
            if status.selectedMode == mode && status.phase != .restoring && status.phase != .monitoring { return status }
            if attempt < 14 {
                try await pause()
                status = try await sample()
            }
        }
        throw HardwareError("\(mode.title)切换未获得后台确认")
    }
}
