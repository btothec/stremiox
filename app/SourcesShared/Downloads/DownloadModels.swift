import Foundation

// MARK: - Server DTOs (embedded Stremio server /$KEY/downloader routes)
//
// Verified against the exact vendored server.js (desktop 4.21.0, the file
// scripts/fetch-server-deps.sh pins + checksums) on 2026-10-13 by running it under plain node
// and exercising every route. The record shape is what DownloaderHelper.getStats() merges into
// the manager's store: `{ total, name, downloaded, progress, speed }` plus `{ id, url, status }`
// and a lazily-filled `fileName`. NOTE the camelCase `fileName`: the official mobile server build
// uses `file_name` (from its TorrentDownloader path), so decoding accepts BOTH spellings. All
// decoding is tolerant to extra/missing fields (the server adds fields across versions).

/// One download record exactly as the server's /getAll and /add return it.
struct DownloadRecord: Decodable {
    let id: String
    let url: String?
    let fileName: String?
    let file_name: String?          // mobile-build spelling, accepted defensively
    let name: String?
    let total: Double?
    let downloaded: Double?
    let speed: Double?
    let progress: Double?           // 0...100 (percent, float)
    let status: String?
    let error: String?

    /// The file name under which the server stores the download (its `downloads/` dir).
    var resolvedFileName: String? {
        if let fileName, !fileName.isEmpty { return fileName }
        if let file_name, !file_name.isEmpty { return file_name }
        if let name, !name.isEmpty { return name }
        return nil
    }
}

/// `{"error":{"message":"..."}}`, the server's error envelope on every route (HTTP 500).
struct DownloadServerError: Decodable {
    struct Inner: Decodable { let code: Double?; let message: String? }
    let error: Inner
}

// MARK: - UI model

/// A download as the UI knows it: the server record mirrored + enriched with the catalogue
/// metadata (title / poster, the stream's context at add time) the server does not carry.
struct DownloadItem: Identifiable, Equatable {
    enum Status: String {
        case running, paused, finished, error
        /// Client-side only: a record the mirror knows about but the server has not answered
        /// for yet (app launched, node still booting). Renders so the page is never blank-shocked.
        case pending
    }
    enum Transport: String {
        case direct        // plain HTTP/HTTPS (debrid links included)
        case torrent       // magnet URL (only the torrent-capable server build downloads these)
    }

    let id: String
    let url: String
    let fileName: String?
    let title: String?              // catalogue: the stream's release title at add time
    let poster: String?             // catalogue: the show/movie poster at add time
    let total: Double               // bytes
    let downloaded: Double          // bytes
    let speed: Double               // bytes/second (0 when not running)
    let status: Status
    let error: String?
    let transport: Transport
    /// True when this item was in flight (running) in the PREVIOUS app session and the server
    /// came back with it paused. On this server build resume restarts such a download from zero
    /// (verified: restartDownload unlinks the partial), so the UI labels the Resume honestly.
    let interrupted: Bool

    /// 0...1 completion, preferring the server's own progress percent, falling back to bytes.
    var fraction: Double {
        if total > 0 {
            let byBytes = min(max(downloaded / total, 0), 1)
            if status == .finished { return 1 }
            return byBytes
        }
        return status == .finished ? 1 : 0
    }

    var isDone: Bool { status == .finished }
    var isActive: Bool { status == .running || status == .paused }

    /// Seconds remaining at the current speed; nil when uncomputable (no size, no speed, done).
    var estimatedSecondsRemaining: Double? {
        guard status == .running, total > 0, speed > 1, downloaded < total else { return nil }
        return (total - downloaded) / speed
    }

    /// Human file size ("1.2 GiB"), nil when the server hasn't reported a size yet.
    var humanTotal: String? {
        guard total > 0 else { return nil }
        return Self.humanBytes(total)
    }

    /// Human rate, e.g. "12.3 MiB/s".
    var humanSpeed: String { Self.humanBytes(speed) + "/s" }

    /// Short human ETA ("12m 30s"), nil when unknown.
    var humanETA: String? {
        guard let s = estimatedSecondsRemaining else { return nil }
        return Self.humanDuration(s)
    }

    /// What to show as the row title: catalogue title, then server file name, then URL tail.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let fileName, !fileName.isEmpty { return fileName }
        if let last = url.split(separator: "/").last, !last.isEmpty {
            return String(last).removingPercentEncoding ?? String(last)
        }
        return "Download"
    }

    static func humanBytes(_ bytes: Double) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var v = max(bytes, 0), u = 0
        while v >= 1024 && u < units.count - 1 { v /= 1024; u += 1 }
        if u == 0 { return "\(Int(v)) \(units[u])" }
        return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[u])
    }

    static func humanDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}
