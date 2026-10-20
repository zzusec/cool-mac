import Foundation
import CoolMacCore
import CoolMacHardware
import CoolMacClient
import Darwin

@main
struct CoolMacCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let command = args.first ?? "diagnose"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if command == "diagnose" {
                let snapshot = try FanHardware().sample()
                print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
                return
            }
            if command == "keys" {
                let smc = try SMC()
                for key in try smc.keys() where key.hasPrefix("T") || key.hasPrefix("F") {
                    do {
                        let value = try smc.read(key)
                        print("\(key)\t\(value.type)\t\(value.size)\t\(value.number.map { String(format: "%.3f", $0) } ?? "not numeric")")
                    } catch { fputs("\(error.localizedDescription)\n", stderr) }
                }
                return
            }
            let client = ServiceClient()
            let session = UUID().uuidString
            let operation: RequestOperation
            var mode: CoolingMode?
            var enhancement: Int?
            if let index = args.firstIndex(of: "--enhancement"), index + 1 < args.count {
                guard let value = Int(args[index + 1]), Enhancement.isValid(value) else {
                    throw HardwareError("--enhancement 只接受关闭或 10…80 的 10 的倍数")
                }
                enhancement = value
            }
            switch command {
            case "status": operation = .status
            case "restore": operation = .restore
            case "commission": operation = .commission
            case "cool", "boost", "system": operation = .select; mode = CoolingMode(rawValue: command)
            case "install":
                guard let value = args.dropFirst().first else { throw HardwareError("用法：coolmacctl install <已暂存的更新 UUID>") }
                guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { throw HardwareError("必须是规范小写 UUID") }
                let response = try await client.request(ServiceRequest(operation: .installUpdate, session: session, updateID: value))
                print(String(decoding: try encoder.encode(response), as: UTF8.self))
                if !response.ok { throw HardwareError(response.error ?? response.status.message) }
                return
            default: throw HardwareError("用法：coolmacctl diagnose|keys|status|restore|commission|cool|boost|system [--seconds N] [--enhancement 0…80]")
            }
            var response = try await client.request(ServiceRequest(operation: operation, session: session, mode: mode, enhancement: mode == .system ? nil : enhancement))
            print(String(decoding: try encoder.encode(response), as: UTF8.self))
            guard response.ok else { throw HardwareError(response.error ?? response.status.message) }
            if command == "commission" {
                for _ in 0..<20 {
                    try await Task.sleep(for: .seconds(1))
                    response = try await client.request(ServiceRequest(operation: .status, session: session))
                    if response.status.commissioned || response.status.phase == .fault { break }
                }
                print(String(decoding: try encoder.encode(response), as: UTF8.self))
                guard response.status.commissioned else { throw HardwareError(response.status.message) }
            } else if mode == .cool || mode == .boost {
                let index = args.firstIndex(of: "--seconds")
                let duration = index.flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 10
                guard (1...120).contains(duration) else { throw HardwareError("--seconds 范围为 1–120") }
                for _ in 0..<duration {
                    try await Task.sleep(for: .seconds(1))
                    response = try await client.request(ServiceRequest(operation: .renew, session: session, enhancement: enhancement))
                    guard response.ok else { throw HardwareError(response.error ?? response.status.message) }
                }
                response = try await client.request(ServiceRequest(operation: .restore, session: session))
                print(String(decoding: try encoder.encode(response), as: UTF8.self))
            }
        } catch {
            FileHandle.standardError.write(Data(("错误：\(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }
}
