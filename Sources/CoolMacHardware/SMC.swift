import Foundation
import CSMC
import CoolMacCore
import Darwin

func decodedCString(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

public struct HardwareError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct HardwareOwnershipLost: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public enum ContinuousClock {
    public static var now: Double { cm_continuous_seconds() }
}

public struct SMCValue {
    var raw: CMValue
    public var type: String {
        let n = raw.type
        return String(bytes: [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)], encoding: .ascii) ?? "????"
    }
    public var size: Int { Int(raw.size) }
    public var attributes: UInt8 { raw.attributes }
    public var number: Double? {
        var copy = raw
        var value: Double = 0
        return cm_decode_number(&copy, &value) == 0 ? value : nil
    }
}

public final class SMC {
    private var connection: UInt32 = 0

    public init() throws {
        var error = [CChar](repeating: 0, count: 256)
        guard cm_smc_open(&connection, &error, error.count) == 0 else { throw HardwareError(decodedCString(error)) }
    }

    deinit { cm_smc_close(connection) }

    public func read(_ key: String) throws -> SMCValue {
        var value = CMValue()
        var error = [CChar](repeating: 0, count: 256)
        let code = key.withCString { cm_smc_read(connection, $0, &value, &error, error.count) }
        guard code == 0 else { throw HardwareError("\(key)：\(decodedCString(error))") }
        return SMCValue(raw: value)
    }

    public func number(_ key: String) throws -> Double {
        let value = try read(key)
        guard let number = value.number else { throw HardwareError("\(key)：不支持的数据类型 \(value.type)/\(value.size)") }
        return number
    }

    public func keys() throws -> [String] {
        let count = try number("#KEY")
        guard count >= 0, count <= 20000 else { throw HardwareError("SMC key 数量异常：\(count)") }
        return try (0..<Int(count)).map { index in
            var key = [CChar](repeating: 0, count: 5)
            var error = [CChar](repeating: 0, count: 256)
            guard cm_smc_key_at(connection, UInt32(index), &key, &error, error.count) == 0 else { throw HardwareError(decodedCString(error)) }
            return decodedCString(key)
        }
    }

    func clearFanOverrideForRecovery() throws {
        guard geteuid() == 0 else { throw HardwareError("恢复风扇需要已安装的管理员后台组件") }
        var error = [CChar](repeating: 0, count: 256)
        guard cm_smc_clear_fan0_override(connection, &error, error.count) == 0 else { throw HardwareError(decodedCString(error)) }
    }

    func writeFan(_ key: String, number: Double, verifyValue: Bool = true) throws {
        guard geteuid() == 0 else { throw HardwareError("写入风扇需要已安装的管理员后台组件") }
        var metadata = try read(key).raw
        var encoded = CMValue()
        guard cm_encode_number(&metadata, number, &encoded) == 0 else { throw HardwareError("\(key)：无法安全编码目标值") }
        var error = [CChar](repeating: 0, count: 256)
        guard key.withCString({ cm_smc_write_fan(connection, $0, &encoded, &error, error.count) }) == 0 else { throw HardwareError(decodedCString(error)) }
        if verifyValue {
            do { try Readback.verify(target: number, timeout: 0.8, tolerance: key.hasSuffix("Md") ? 0 : 1) { try self.number(key) } }
            catch { throw HardwareError("\(key)：\(error.localizedDescription)") }
        }
    }
}

public func machineModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size < 256 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return decodedCString(buffer)
}
