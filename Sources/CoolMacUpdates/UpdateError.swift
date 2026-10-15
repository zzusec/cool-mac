import Foundation

/// Every failure this module can report. Nothing here is recoverable by
/// guessing: each case names the exact check that failed so the caller can
/// surface a locatable message instead of a silent downgrade.
public enum UpdateError: LocalizedError, Equatable, Sendable {
    /// The envelope signature does not match the payload bytes.
    case invalidSignature
    /// The configured public key is not 32 raw Ed25519 bytes, or is not a usable point.
    case invalidPublicKey
    /// The envelope or the payload is not the expected JSON/base64 shape.
    case invalidManifestJSON(String)
    /// The payload declares a schema this build does not understand.
    case unsupportedSchema(Int)
    /// The payload is signed but belongs to another app.
    case bundleIDMismatch(expected: String, found: String)
    /// The payload carries no architecture this machine can run.
    case unsupportedArchitecture(String)
    /// The payload requires a newer macOS than the one running.
    case systemVersionTooOld(required: String, current: String)
    /// A dotted-numeric version field is malformed.
    case invalidVersionFormat(String)
    /// The offered build is a downgrade, or does not increase the build number.
    case notNewerThanCurrent(currentVersion: String, currentBuild: Int)
    /// The URL is not https, or its host is outside the allowed update hosts.
    case disallowedURLHost(String)
    /// The asset is larger than the size this build is willing to fetch.
    case assetTooLarge(limit: Int, reported: Int)
    /// The downloaded bytes do not hash to the signed digest.
    case digestMismatch(expected: String, actual: String)
    /// The downloaded byte count differs from the signed byte count.
    case byteCountMismatch(expected: Int, actual: Int)
    /// The destination directory or file is a symbolic link, or is unusable.
    case unsafeDestination(String)
    /// The transfer itself failed (DNS, TLS, HTTP status, disk write, ...).
    case downloadFailed(String)
    /// The transfer exceeded its deadline.
    case downloadTimedOut
    /// The transfer was cancelled by the caller.
    case downloadCancelled

    public var errorDescription: String? {
        switch self {
        case .invalidSignature:
            return "更新清单签名无效，已拒绝。"
        case .invalidPublicKey:
            return "更新公钥无效：需要 32 字节 Ed25519 raw 公钥的 base64。"
        case .invalidManifestJSON(let detail):
            return "更新清单不是合法的 JSON：\(detail)"
        case .unsupportedSchema(let schema):
            return "更新清单 schema 不受支持：\(schema)（本机支持 \(UpdateManifest.currentSchema)）。"
        case .bundleIDMismatch(let expected, let found):
            return "更新清单属于其他应用：期望 \(expected)，实际 \(found)。"
        case .unsupportedArchitecture(let architecture):
            return "更新包不支持本机架构：\(architecture)。"
        case .systemVersionTooOld(let required, let current):
            return "更新包要求 macOS \(required)，本机为 \(current)。"
        case .invalidVersionFormat(let value):
            return "版本号格式非法：\(value)（必须为点分数字）。"
        case .notNewerThanCurrent(let version, let build):
            return "不是更新版本：当前 \(version)(build \(build))，build 必须严格递增。"
        case .disallowedURLHost(let url):
            return "不允许的更新地址：\(url)"
        case .assetTooLarge(let limit, let reported):
            return "更新包过大：上限 \(limit) 字节，实际 \(reported) 字节。"
        case .digestMismatch(let expected, let actual):
            return "更新包摘要不符：期望 \(expected)，实际 \(actual)。"
        case .byteCountMismatch(let expected, let actual):
            return "更新包字节数不符：期望 \(expected)，实际 \(actual)。"
        case .unsafeDestination(let detail):
            return "下载目标不安全：\(detail)"
        case .downloadFailed(let detail):
            return "更新包下载失败：\(detail)"
        case .downloadTimedOut:
            return "更新包下载超时。"
        case .downloadCancelled:
            return "更新包下载已取消。"
        }
    }

    /// True for the "there is simply nothing to install" outcome, which callers
    /// translate into `nil` rather than an error.
    public var isNotNewerThanCurrent: Bool {
        if case .notNewerThanCurrent = self { return true }
        return false
    }

    /// Maps a failure from a transport onto this module's cases.
    ///
    /// A transport that already speaks `UpdateError` passes through untouched, so
    /// its more specific verdict (a blocked redirect, for example) is preserved.
    /// Everything else is classified here rather than flattened into
    /// `downloadFailed`, so a timeout or a cancellation stays distinguishable no
    /// matter which transport is plugged in.
    public static func classify(_ error: Error) -> UpdateError {
        if let error = error as? UpdateError { return error }
        if error is CancellationError { return .downloadCancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .downloadCancelled
            case .timedOut:
                return .downloadTimedOut
            default:
                return .downloadFailed("\(urlError.code.rawValue) \(urlError.localizedDescription)")
            }
        }
        if Task.isCancelled { return .downloadCancelled }
        return .downloadFailed(String(describing: error))
    }
}
