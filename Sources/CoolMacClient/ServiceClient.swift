import CIPC
import CoolMacCore
import Foundation

public enum ServiceClientError: Error, LocalizedError, Sendable {
    case encoding(String)
    case requestTooLarge(Int)
    case transport(String)
    case invalidResponse(String)
    case unsupportedVersion(Int)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .encoding(let detail):
            "无法编码后台请求：\(detail)"
        case .requestTooLarge(let count):
            "后台请求超过 16 KiB 限制（\(count) 字节）"
        case .transport(let detail):
            "后台连接失败：\(detail)"
        case .invalidResponse(let detail):
            "后台响应无效：\(detail)"
        case .unsupportedVersion(let version):
            "后台协议版本不兼容（收到 \(version)，需要 \(Product.protocolVersion)）"
        case .rejected(let detail):
            "后台拒绝请求：\(detail)"
        }
    }
}

// C owns exactly one retained reference until its exactly-once completion. The
// callback copies C buffers and consumes that reference before returning. Task
// cancellation does not abandon the context: C still completes within 3 seconds.
private final class RequestContinuation: Sendable {
    let continuation: CheckedContinuation<Data, any Error>

    init(_ continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }
}

private func serviceCompletion(
    _ response: UnsafePointer<CChar>?,
    _ error: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let pending = Unmanaged<RequestContinuation>.fromOpaque(context).takeRetainedValue()
    if let error {
        // The bridge only supplies bounded, NUL-terminated error strings.
        pending.continuation.resume(throwing: ServiceClientError.transport(String(cString: error)))
    } else if let response, let json = String(validatingCString: response) {
        pending.continuation.resume(returning: Data(json.utf8))
    } else {
        pending.continuation.resume(throwing: ServiceClientError.invalidResponse("响应缺失或不是 UTF-8"))
    }
}

public actor ServiceClient {
    public init() {}

    public func request(_ request: ServiceRequest) async throws -> ServiceResponse {
        try Task.checkCancellation()
        let data: Data
        do {
            data = try JSONEncoder().encode(request)
        } catch {
            throw ServiceClientError.encoding(error.localizedDescription)
        }
        guard data.count <= Int(CM_REQUEST_MAX_BYTES) else {
            throw ServiceClientError.requestTooLarge(data.count)
        }
        let json = String(decoding: data, as: UTF8.self)
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            let context = Unmanaged.passRetained(RequestContinuation(continuation)).toOpaque()
            Product.service.withCString { service in
                json.withCString { bytes in
                    cm_client_request(service, bytes, serviceCompletion, context)
                }
            }
        }
        try Task.checkCancellation()
        let response: ServiceResponse
        do {
            response = try JSONDecoder().decode(ServiceResponse.self, from: responseData)
        } catch {
            throw ServiceClientError.invalidResponse(error.localizedDescription)
        }
        guard response.status.version == Product.protocolVersion else {
            throw ServiceClientError.unsupportedVersion(response.status.version)
        }
        guard response.ok else {
            throw ServiceClientError.rejected(response.error ?? response.status.message)
        }
        return response
    }
}
