import Foundation

public enum ProtocolValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidSession
    case missingMode
    case unexpectedMode(RequestOperation)
    case invalidEnhancement(Int)
    case unexpectedEnhancement(RequestOperation)
    case missingUpdateID
    case invalidUpdateID
    case unexpectedUpdateID(RequestOperation)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "不支持协议版本 \(version)，必须使用版本 \(Product.protocolVersion)。"
        case .invalidSession:
            "session 必须是规范的 36 字符 UUID，不允许空白或其他附加字符。"
        case .missingMode:
            "select 请求必须指定 mode。"
        case .unexpectedMode(let operation):
            "\(operation.rawValue) 请求不允许携带 mode；只有 select 可以选择模式。"
        case .invalidEnhancement(let value):
            "增强档位 \(value) 无效；只接受关闭或 10…\(Enhancement.maximumPercent) 之间的 10 的倍数。"
        case .unexpectedEnhancement(let operation):
            "\(operation.rawValue) 请求不允许携带增强档位；只有 select 和 renew 可以设置。"
        case .missingUpdateID:
            "installUpdate 请求必须携带已暂存更新的规范 UUID。"
        case .invalidUpdateID:
            "updateID 必须是规范的小写 UUID。"
        case .unexpectedUpdateID(let operation):
            "\(operation.rawValue) 请求不允许携带 updateID；只有 installUpdate 可以。"
        }
    }
}

/// Validates the typed, decoded request before dispatch or any control side effect.
/// This is not an authentication check; the IPC boundary must authenticate peers.
/// `commission` has no mode: it only commissions the helper's fixed capability.
public enum ProtocolValidation {
    public static func validate(_ request: ServiceRequest) throws {
        guard request.version == Product.protocolVersion else {
            throw ProtocolValidationError.unsupportedVersion(request.version)
        }
        guard request.session.utf8.count == 36,
              let uuid = UUID(uuidString: request.session),
              uuid.uuidString.lowercased() == request.session.lowercased() else {
            throw ProtocolValidationError.invalidSession
        }
        if let enhancement = request.enhancement, !Enhancement.isValid(enhancement) {
            throw ProtocolValidationError.invalidEnhancement(enhancement)
        }
        switch request.operation {
        case .select:
            guard request.mode != nil else { throw ProtocolValidationError.missingMode }
            guard request.updateID == nil else {
                throw ProtocolValidationError.unexpectedUpdateID(request.operation)
            }
        case .renew:
            guard request.mode == nil else {
                throw ProtocolValidationError.unexpectedMode(request.operation)
            }
            guard request.updateID == nil else {
                throw ProtocolValidationError.unexpectedUpdateID(request.operation)
            }
        case .status, .restore, .commission:
            guard request.mode == nil else {
                throw ProtocolValidationError.unexpectedMode(request.operation)
            }
            guard request.enhancement == nil else {
                throw ProtocolValidationError.unexpectedEnhancement(request.operation)
            }
            guard request.updateID == nil else {
                throw ProtocolValidationError.unexpectedUpdateID(request.operation)
            }
        case .installUpdate:
            guard request.mode == nil else {
                throw ProtocolValidationError.unexpectedMode(request.operation)
            }
            guard request.enhancement == nil else {
                throw ProtocolValidationError.unexpectedEnhancement(request.operation)
            }
            guard let identifier = request.updateID else {
                throw ProtocolValidationError.missingUpdateID
            }
            guard let uuid = UUID(uuidString: identifier), uuid.uuidString.lowercased() == identifier else {
                throw ProtocolValidationError.invalidUpdateID
            }
        }
    }
}
