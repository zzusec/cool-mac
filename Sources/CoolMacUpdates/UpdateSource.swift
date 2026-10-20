import Foundation

/// Fixed update source and the host policy that goes with it.
///
/// Policy: the manifest and the initial asset URL must live on `github.com` over
/// https; a redirect may only land on an https `*.githubusercontent.com` host.
/// Anything else is refused before a single byte is downloaded.
public enum UpdateSource {
    /// 固定更新清单地址。
    ///
    /// TODO(主代理): 仓库/发布路径确定后核对此处；地址必须是 https 且主机为
    /// `allowedInitialHost`，否则 `UpdateChecker` 会在联网前直接拒绝。
    public static let manifestURL = URL(string: "https://github.com/zzusec/cool-mac/releases/latest/download/update.json")!

    /// The only host the manifest URL and the initial asset URL may use.
    public static let allowedInitialHost = "github.com"

    /// Bundle identifier this build accepts. Must match `Product.bundleID`.
    public static let bundleID = "local.hx10.coolmac"

    /// Hosts an asset may ultimately come from: `github.com` itself, or any
    /// `*.githubusercontent.com` host. The bare `githubusercontent.com` and
    /// look-alikes such as `evilgithubusercontent.com` are not accepted.
    public static func isAllowedAssetHost(_ host: String) -> Bool {
        let candidate = host.lowercased()
        guard !candidate.isEmpty else { return false }
        return candidate == allowedInitialHost || candidate.hasSuffix(".githubusercontent.com")
    }

    /// Hosts a *redirect* may land on. GitHub's `releases/latest/download/...`
    /// redirects within `github.com` to the versioned release path, and release
    /// bytes are then served from the CDN, so both are accepted. Everything else
    /// is refused.
    public static func isAllowedRedirectHost(_ host: String) -> Bool {
        let candidate = host.lowercased()
        guard !candidate.isEmpty else { return false }
        return candidate == allowedInitialHost || candidate.hasSuffix(".githubusercontent.com")
    }

    /// True when the URL is https and its host is a host an asset may come from.
    public static func isAllowedAssetURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host else { return false }
        return isAllowedAssetHost(host)
    }

    /// Throws `UpdateError.disallowedURLHost` unless the URL may be fetched: the
    /// initial manifest and asset URLs must be https on the fixed initial host.
    static func validateInitialHost(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw UpdateError.disallowedURLHost(url.absoluteString)
        }
        guard let host = url.host?.lowercased(), host == allowedInitialHost else {
            throw UpdateError.disallowedURLHost(url.absoluteString)
        }
    }
}
