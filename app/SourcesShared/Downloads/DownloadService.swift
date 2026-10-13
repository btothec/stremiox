import Foundation
import os

/// Client for the embedded server's download manager routes. The server is the source of truth
/// for every byte and status; this type only speaks its HTTP dialect (verified against the exact
/// vendored server.js by running it under node and exercising every route):
///
///   GET /add?url=&playerUrl=   start; auto-detects http(s) vs magnet; echoes the new record JSON
///   GET /getAll                array of records (Object.values)
///   GET /get?id=               one record, or 500 {"error":{"message":"there is no download with this id"}}
///   GET /pause?id=             running -> paused, persists a resume state
///   GET /resume?id=            paused -> running (with no in-memory handler this restarts from zero)
///   GET /remove?id=            delete record; finished files are unlinked too
///   GET /stream?id=            byte-range serving of a FINISHED download's file (404 below 100%)
///
/// Mount prefix: the router lives at `/$SERVER_IPC_KEY/downloader` (server.js gates it on the
/// SERVER_IPC_KEY env var), so `routeBase()` composes the per-boot URL from the key the app
/// generated and passed into the node runtime. There is NO /removeAll on this build, and the
/// desktop server.js has no torrent downloader: a magnet /add comes back status "error" with
/// `Protocol "magnet:" not supported` (verified), which the caller must degrade gracefully.
enum DownloadService {
    /// Transport/server-level failure carrying a human message (the server's error envelope
    /// message, an HTTP status, or a URLSession description). `"not mounted"` is a reserved
    /// value: the store keys off it to mean "server answered, download router absent".
    struct Failure: Error, Equatable, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
        /// Lets call sites pattern-match `.failure(Failure("not mounted"))` directly.
        static func ~= (pattern: String, value: Failure) -> Bool { pattern == value.message }
    }

    private static let log = Logger(subsystem: "com.stremiox.app", category: "downloads")

    /// Full base for the downloader routes on the ACTIVE server base (a custom remote server would
    /// need the same key + env to expose these routes; it likely does not, hence callers treat
    /// `.routerMissing` as "downloads off here"). Trailing slash trimmed by callers' URL building.
    static func routeBase() -> String {
        "\(StremioServer.base)/\(DownloadIPCKey.current())/downloader"
    }

    /// URL for one route, with query items percent-encoded exactly as the server's Express/qs
    /// layer parses them: the value charset strips everything that could split or re-shape a
    /// querystring param (`&`, `=`, the RFC3986 reserved set, plus `%`, `+` and `;`). NOTE: qs
    /// decodes a literal `+` as a space and any `%` as an escape lead, so leaving them raw
    /// corrupts URL values (verified against the live server).
    static func url(route: String, query: [String: String]) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+/?#@:%;,[]")
        var q: [String] = []
        for (k, v) in query.sorted(by: { $0.key < $1.key }) {
            guard let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) else { continue }
            q.append("\(k)=\(ev)")
        }
        let s = routeBase() + route + (q.isEmpty ? "" : "?" + q.joined(separator: "&"))
        return URL(string: s)
    }

    /// /add for a URL. Returns the server's fresh record on success, or a message describing the
    /// failure (an error envelope, a non-JSON body, or a transport-level error). A magnet that the
    /// build cannot download returns the record with status "error" (not an error from this func);
    /// callers inspect the record.
    static func add(url downloadURL: String, playerURL: String? = nil) async -> Result<DownloadRecord, Failure> {
        var query = ["url": downloadURL]
        if let playerURL { query["playerUrl"] = playerURL }
        guard let u = url(route: "/add", query: query) else { return .failure(Failure("invalid add URL")) }
        let body = await get(u)
        switch body {
        case .failure(let e): return .failure(e)
        case .success(let data):
            if let env = try? JSONDecoder().decode(DownloadServerError.self, from: data),
               env.error.message != nil {
                return .failure(Failure(env.error.message ?? "server error"))
            }
            guard let rec = try? JSONDecoder().decode(DownloadRecord.self, from: data) else {
                return .failure(Failure("unexpected server response"))
            }
            return .success(rec)
        }
    }

    /// /getAll. On Lite/custom-server builds this 404s fast; callers treat failures as "server
    /// not ready" rather than "no downloads" (the store keeps its mirror meanwhile).
    static func getAll() async -> Result<[DownloadRecord], Failure> {
        guard let u = url(route: "/getAll", query: [:]) else { return .failure(Failure("invalid URL")) }
        switch await get(u) {
        case .failure(let e): return .failure(e)
        case .success(let data):
            if let env = try? JSONDecoder().decode(DownloadServerError.self, from: data),
               env.error.message != nil {
                return .failure(Failure(env.error.message ?? "server error"))
            }
            guard let recs = try? JSONDecoder().decode([DownloadRecord].self, from: data) else {
                return .failure(Failure("unexpected getAll response"))
            }
            return .success(recs)
        }
    }

    /// /get?id= . The "no download with this id" 500 is the server's way of confirming a delete
    /// worked, so it surfaces as `.failure(Failure("missing"))` — callers match on the message string.
    static func getRecord(id: String) async -> Result<DownloadRecord, Failure> {
        guard let u = url(route: "/get", query: ["id": id]) else { return .failure(Failure("invalid URL")) }
        switch await get(u) {
        case .failure(let e): return .failure(e)
        case .success(let data):
            if let env = try? JSONDecoder().decode(DownloadServerError.self, from: data),
               env.error.message != nil {
                return .failure(Failure(env.error.message ?? "server error"))
            }
            guard let rec = try? JSONDecoder().decode(DownloadRecord.self, from: data) else {
                return .failure(Failure("unexpected /get response"))
            }
            return .success(rec)
        }
    }

    static func pause(id: String) async -> Result<Void, Failure> { await action("/pause", id: id) }
    static func resume(id: String) async -> Result<Void, Failure> { await action("/resume", id: id) }
    static func remove(id: String) async -> Result<Void, Failure> { await action("/remove", id: id) }

    /// The playable URL for a finished download: the server's /stream route (verified to serve
    /// byte ranges with the right content type; it 404s for unfinished items). mpv reads it over
    /// loopback, so finished downloads play with airplane mode on (verified end-to-end offline).
    static func streamURL(id: String) -> URL? { url(route: "/stream", query: ["id": id]) }

    // MARK: - plumbing

    private static func action(_ route: String, id: String) async -> Result<Void, Failure> {
        guard let u = url(route: route, query: ["id": id]) else { return .failure(Failure("invalid URL")) }
        switch await get(u) {
        case .failure(let e): return .failure(e)
        case .success(let data):
            if let env = try? JSONDecoder().decode(DownloadServerError.self, from: data),
               env.error.message != nil {
                return .failure(Failure(env.error.message ?? "server error"))
            }
            return .success(())
        }
    }

    private static func get(_ u: URL) async -> Result<Data, Failure> {
        var req = URLRequest(url: u)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                // Distinguish "route not mounted" (Lite build / custom server / no key) so the store
                // can show a precise reason instead of a generic failure.
                if http.statusCode == 404 { return .failure(Failure("not mounted")) }
                return .failure(Failure("HTTP \(http.statusCode)"))
            }
            return .success(data)
        } catch {
            return .failure(Failure(error.localizedDescription))
        }
    }
}
