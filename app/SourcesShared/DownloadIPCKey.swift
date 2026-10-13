import Foundation

/// The per-install secret that mounts the embedded server's download router. server.js registers
/// the downloader routes at `/$SERVER_IPC_KEY/downloader` ONLY when the SERVER_IPC_KEY env var is
/// set (`process.env.SERVER_IPC_KEY && enginefs.router.use(...)` — verified against both the
/// vendored desktop server.js 4.21.0 and the official app's mobile build), which is how the
/// official iOS app gates its own loopback download API. We generate one random key per install,
/// persist it, and hand it to the node runtime at boot.
///
/// Deliberately a tiny Foundation-only file: it is the ONE place the key is derived, and it has to
/// be reachable from both the node boot paths (Sources/NodeServer.swift on iOS/tvOS,
/// SourcesShared/MacNodeServer.swift on macOS) and the shared download client, including the
/// web-host target that compiles almost none of SourcesShared. It guards loopback access from
/// other apps on the device, not a trust boundary against the user.
enum DownloadIPCKey {
    static let defaultsKey = "stremiox.serverIPCKey"

    /// Whether the key's hex-only shape holds (guards a restored/corrupted default).
    static func isValid(_ k: String) -> Bool {
        k.count >= 16 && k.allSatisfy { $0.isHexDigit }
    }

    /// The active key: a stable 32-char hex string, generated once and reused across launches
    /// (a fresh key per boot would orphan the previous session's records under the old prefix).
    static func current() -> String {
        if let k = UserDefaults.standard.string(forKey: defaultsKey),
           k.count >= 16, k.allSatisfy({ $0.isHexDigit }) {
            return k
        }
        let bytes = (0 ..< 16).map { _ in UInt8.random(in: .min ... .max) }
        let k = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(k, forKey: defaultsKey)
        return k
    }
}
