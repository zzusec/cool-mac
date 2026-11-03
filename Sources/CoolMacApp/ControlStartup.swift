import Foundation
import CoolMacCore

struct ControlStartup {
    private(set) var attempted = false
    private var initialModeApplied = false

    mutating func shouldStart(status: ServiceStatus, now: Double = Date().timeIntervalSince1970) -> Bool {
        if status.phase == .fault { cancel() }
        guard !attempted, status.available, !status.commissioned, status.phase == .system,
              let snapshot = status.snapshot, snapshot.supported,
              abs(now - snapshot.sampledAt) <= 5 else { return false }
        attempted = true
        return true
    }

    mutating func cancel() {
        attempted = true
        initialModeApplied = true
    }

    mutating func didCompleteCommissioning() {
        initialModeApplied = true
    }

    mutating func modeToApply(status: ServiceStatus, preferredMode: CoolingMode) -> CoolingMode? {
        guard !initialModeApplied, status.available, status.commissioned, status.phase != .fault else { return nil }
        initialModeApplied = true
        return preferredMode == .cool ? .cool : nil
    }

    mutating func didWake() {
        initialModeApplied = false
    }
}
