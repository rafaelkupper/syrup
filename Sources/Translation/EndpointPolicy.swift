import Foundation

/// Rules about where an OpenAI-compatible endpoint sends data.
enum EndpointPolicy {
    /// The endpoint is on this Mac, so the request itself stays here. A local server can still pass
    /// it on elsewhere, which Syrup cannot see.
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if host == "localhost" || host == "[::1]" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && UInt8($0) != nil
        }
    }

    /// Plain http to another machine. It stays allowed for local-network servers, but the API key
    /// and the text travel unencrypted, so Settings warns about it.
    static func isUnencryptedRemote(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "http",
              url.host() != nil else { return false }
        return isLoopback(url) == false
    }
}
