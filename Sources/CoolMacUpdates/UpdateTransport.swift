import Foundation

/// Fetches bytes for the updater.
///
/// Implementations must: carry no credentials, refuse to follow a redirect to a
/// host outside `UpdateSource`'s policy, stop at `byteLimit`, and honour
/// `timeout`. Failures are reported as `UpdateError` where they map onto one of
/// its cases, and never as a truncated-but-successful result.
public protocol UpdateTransport: Sendable {
    func data(from url: URL, byteLimit: Int, timeout: Double) async throws -> (Data, URLResponse)
}

/// The real transport. An ephemeral, credential-free `URLSession` with a hard
/// byte ceiling, a hard deadline and a redirect policy that only allows https
/// `*.githubusercontent.com` targets.
public struct URLSessionUpdateTransport: UpdateTransport, @unchecked Sendable {
    public static let defaultTimeout: Double = 30

    private let session: URLSession

    public init(configuration: URLSessionConfiguration = URLSessionUpdateTransport.credentialFreeConfiguration) {
        self.session = URLSession(configuration: configuration)
    }

    /// Cookies, credential storage and caches are all off: the updater never
    /// authenticates and never reuses anyone else's session state.
    public static var credentialFreeConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [:]
        configuration.timeoutIntervalForRequest = defaultTimeout
        configuration.timeoutIntervalForResource = 600
        return configuration
    }

    public func data(from url: URL, byteLimit: Int, timeout: Double) async throws -> (Data, URLResponse) {
        guard byteLimit > 0 else {
            throw UpdateError.assetTooLarge(limit: byteLimit, reported: 0)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout > 0 ? timeout : Self.defaultTimeout)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let guardrail = TransferGuard(byteLimit: byteLimit)
        do {
            let (data, response) = try await fetch(request, guardrail: guardrail, timeout: timeout)
            if let blocked = guardrail.blockedRedirectTarget {
                throw UpdateError.disallowedURLHost(blocked)
            }
            if guardrail.didExceedByteLimit || data.count > byteLimit {
                throw UpdateError.assetTooLarge(limit: byteLimit, reported: data.count)
            }
            let announced = response.expectedContentLength
            if announced > 0 && announced > Int64(byteLimit) {
                throw UpdateError.assetTooLarge(limit: byteLimit, reported: Int(clamping: announced))
            }
            return (data, response)
        } catch let error as UpdateError {
            throw error
        } catch is CancellationError {
            throw UpdateError.downloadCancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                if guardrail.blockedRedirectTarget != nil {
                    throw UpdateError.disallowedURLHost(guardrail.blockedRedirectTarget ?? url.absoluteString)
                }
                throw UpdateError.downloadCancelled
            case .timedOut:
                throw UpdateError.downloadTimedOut
            default:
                throw UpdateError.downloadFailed("\(error.code.rawValue) \(error.localizedDescription)")
            }
        } catch {
            if Task.isCancelled { throw UpdateError.downloadCancelled }
            throw UpdateError.downloadFailed(String(describing: error))
        }
    }

    /// Runs the request under a hard deadline. `URLSession`'s own request timeout
    /// is only advisory across redirects, so the deadline is enforced here too.
    private func fetch(_ request: URLRequest, guardrail: TransferGuard, timeout: Double) async throws -> (Data, URLResponse) {
        let session = self.session
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (data, response) = try await session.data(for: request, delegate: guardrail)
                guardrail.record(response: response)
                return data
            }
            if timeout > 0 {
                let clamped = min(timeout, 3600)
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
                    throw UpdateError.downloadTimedOut
                }
            }
            guard let data = try await group.next() else {
                throw UpdateError.downloadFailed("传输未返回数据")
            }
            group.cancelAll()
            guard let response = guardrail.response else {
                throw UpdateError.downloadFailed("传输未返回响应")
            }
            return (data, response)
        }
    }
}

/// HTTP response validation shared by the checker and the downloader.
enum UpdateHTTP {
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.downloadFailed("响应不是 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.downloadFailed("HTTP 状态码 \(http.statusCode)")
        }
    }
}

/// Enforces the per-transfer limits from inside the session's delegate callbacks
/// and records why a transfer was stopped, so the caller can raise the precise
/// `UpdateError` instead of a generic cancellation.
final class TransferGuard: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let byteLimit: Int
    private var receivedBytes = 0
    private var exceeded = false
    private var blockedTarget: String?
    private var storedResponse: URLResponse?

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
        super.init()
    }

    var didExceedByteLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return exceeded
    }

    var blockedRedirectTarget: String? {
        lock.lock(); defer { lock.unlock() }
        return blockedTarget
    }

    var response: URLResponse? {
        lock.lock(); defer { lock.unlock() }
        return storedResponse
    }

    func record(response: URLResponse) {
        lock.lock(); defer { lock.unlock() }
        storedResponse = response
    }

    /// Redirect policy in one place: https only, and only onto the CDN suffix.
    static func redirectDecision(for request: URLRequest) -> (allowed: Bool, target: String) {
        guard let url = request.url else { return (false, "<无地址>") }
        let target = url.absoluteString
        guard url.scheme?.lowercased() == "https" else { return (false, target) }
        guard let host = url.host, UpdateSource.isAllowedRedirectHost(host) else { return (false, target) }
        return (true, target)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let decision = TransferGuard.redirectDecision(for: request)
        if decision.allowed {
            completionHandler(request)
        } else {
            lock.lock()
            blockedTarget = decision.target
            lock.unlock()
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        receivedBytes += data.count
        if receivedBytes > byteLimit { exceeded = true }
        let over = exceeded
        lock.unlock()
        if over { dataTask.cancel() }
    }
}
