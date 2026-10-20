import Foundation
import CSMC
import CoolMacCore

public final class FanHardware {
    public let smc: SMC
    public let model: String
    private var sensors: [(key: String, name: String, group: String)] = []
    private var catalogIssues: [String] = []

    public init(discoverSensors: Bool = true) throws {
        smc = try SMC()
        model = machineModel()
        if discoverSensors { try self.discoverSensors() }
    }

    private func discoverSensors() throws {
        // The M2 profile is deliberately bounded. Unknown keys remain diagnostic-only.
        // Reference: Stats c9e7ebe3, Modules/Sensors/values.swift (M2 family).
        // Series-wide labels do not establish physical core numbering on Mac14,7.
        let cpuKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tp1h", "Tp1t", "Tp1p", "Tp1l"]
        let gpuKeys = ["Tg0f", "Tg0j"]
        let catalog: [(String, String, String)] = cpuKeys.map { ($0, "CPU 测点 \($0)", "cpu") } + gpuKeys.map { ($0, "GPU 测点 \($0)", "gpu") }
        let available = Set(try smc.keys())
        for (key, name, group) in catalog where available.contains(key) {
            let value = try smc.read(key)
            guard ["flt ", "sp78"].contains(value.type), let number = value.number, number > 0, number < 120 else {
                catalogIssues.append("\(key)：传感器类型或读数不受支持")
                continue
            }
            sensors.append((key, name, group))
        }
    }

    public func sample() throws -> HardwareSnapshot {
        var issues = catalogIssues
        let countValue = try smc.number("FNum")
        guard countValue.rounded() == countValue, countValue >= 1, countValue <= 4 else { throw HardwareError("风扇数量不受支持：\(countValue)") }
        var fans: [FanReading] = []
        for id in 0..<Int(countValue) {
            let prefix = "F\(id)"
            let minimum = try smc.number(prefix + "Mn")
            let maximum = try smc.number(prefix + "Mx")
            let actual = try smc.number(prefix + "Ac")
            let target = try smc.number(prefix + "Tg")
            let modeValue = try smc.read(prefix + "Md")
            guard modeValue.type == "ui8 ", modeValue.size == 1, let mode = modeValue.number, mode == 0 || mode == 1 else { throw HardwareError("\(prefix)Md：未验证的风扇模式类型或值") }
            guard minimum >= 1000, maximum > minimum, maximum <= 10000, actual >= 0, actual <= maximum * 1.2, target >= 0, target <= maximum * 1.2 else { throw HardwareError("风扇 \(id + 1) 转速范围异常") }
            let targetInfo = try smc.read(prefix + "Tg")
            guard ["flt ", "fpe2"].contains(targetInfo.type) else { throw HardwareError("\(prefix)Tg：不支持的目标转速类型") }
            fans.append(FanReading(id: id, actualRPM: actual, minimumRPM: minimum, maximumRPM: maximum, targetRPM: target, manual: mode == 1))
        }
        let temperatures = try sensors.map { sensor in
            let value = try smc.number(sensor.key)
            guard value > 0, value < 120 else { throw HardwareError("\(sensor.key)：温度读数无效") }
            return TemperatureReading(key: sensor.key, name: sensor.name, celsius: value, group: sensor.group)
        }
        if !temperatures.contains(where: { $0.group == "cpu" }) { issues.append("缺少已确认的 CPU 温度传感器") }
        if !temperatures.contains(where: { $0.group == "gpu" }) { issues.append("缺少已确认的 GPU 温度传感器") }
        if model != "Mac14,7" { issues.append("首版仅验证 Mac14,7，当前机型 \(model) 保持只读") }
        if model == "Mac14,7" && fans.count != 1 { issues.append("风扇数量与 Mac14,7 已验证 profile 不符") }
        return HardwareSnapshot(sampledAt: Date().timeIntervalSince1970, model: model, temperatures: temperatures, fans: fans, thermalPressure: ProcessInfo.processInfo.thermalState.rawValue, supported: issues.isEmpty, issues: issues)
    }

    public func restoreSystem() throws {
        // Restoration must not depend on temperature sensors or target telemetry.
        guard model == "Mac14,7" else { throw HardwareError("未知机型禁止写入") }
        let count = try smc.number("FNum")
        guard count == 1 else { throw HardwareError("Mac14,7 风扇数量与已验证 profile 不符") }
        let metadata = try smc.read("F0Md")
        guard metadata.type == "ui8 ", metadata.size == 1 else { throw HardwareError("F0Md 元数据变化，禁止未知写入") }
        try smc.writeFan("F0Md", number: 0, verifyValue: false)
        try smc.clearFanOverrideForRecovery()
        try Readback.verify(target: 0, timeout: 1, tolerance: 0) { try smc.number("F0Md") }
        try Readback.confirmStable(target: 0) { try smc.number("F0Md") }
    }

    public func conflictingController() throws -> String? {
        var name = [CChar](repeating: 0, count: 128)
        let result = cm_conflicting_controller(&name, name.count)
        guard result >= 0 else { throw HardwareError("无法核实其他风扇控制程序，暂不接管") }
        return result == 1 ? decodedCString(name) : nil
    }

    public func setTargets(_ targets: [Int: Double], ownedTargets: [Int: Double]) throws {
        let snapshot = try sample()
        guard snapshot.supported else { throw HardwareError(snapshot.issues.joined(separator: "；")) }
        for fan in snapshot.fans {
            // The 80% ceiling is enforced here, not only in the UI or policy.
            let ceiling = max(fan.minimumRPM, fan.maximumRPM * Enhancement.maximumManualFraction)
            guard let target = targets[fan.id], target.isFinite, target >= fan.minimumRPM, target <= ceiling else {
                throw HardwareError("风扇目标超出已验证范围或 80% 上限")
            }
            if fan.manual {
                guard let owned = ownedTargets[fan.id], abs(fan.targetRPM - owned) <= 3 else { throw HardwareOwnershipLost("写入前发现外部手动控制，未写入任何目标") }
            } else if ownedTargets[fan.id] != nil {
                throw HardwareOwnershipLost("写入前系统已收回控制，未重新接管")
            }
        }
        for fan in snapshot.fans {
            let target = targets[fan.id]!
            // Seed the target before entering manual mode to avoid a stale low target.
            try smc.writeFan("F\(fan.id)Tg", number: target, verifyValue: fan.manual)
            if !fan.manual { try smc.writeFan("F\(fan.id)Md", number: 1) }
            try smc.writeFan("F\(fan.id)Tg", number: target)
        }
    }
}
