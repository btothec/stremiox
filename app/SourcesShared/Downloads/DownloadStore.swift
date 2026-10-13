import Foundation
import os

/// The UI-side mirror of the embedded server's download manager. The SERVER is the source of
/// truth for bytes and status (hard constraint: no download logic in Swift); this store only
/// polls /getAll, merges records with the catalogue context the server does not carry
/// (title/poster/add time), persists that mirror so the Downloads page renders before the node
/// server finishes booting, and drives the poll loop (1s while anything is running, else 5s).
///
/// Server lifecycle facts this design is built on (all verified against the exact vendored
/// server.js under real node, 2026-10-13):
/// - On server (re)start, a partial whose record was `running` is AUTO-RESUMED from its stored
///   stats (not forced to paused, unlike the official mobile build's contract the goal doc quoted).
/// - A `paused` record that survives a restart resumes by restarting the file FROM ZERO (the
///   no-handler /resume path unlinks the partial first). So every paused item the UI did not
///   pause in the current session is labelled "interrupted" and its button says Restart.
/// - The desktop server build cannot download torrents/magnets: /add accepts them and immediately
///   records status "error" with a "Protocol \"magnet:\" not supported" message.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    private static let log = Logger(subsystem: "com.stremiox.app", category: "downloads")

    // MARK: Published state

    @Published private(set) var items: [DownloadItem] = []
    /// Server visibility from the store's point of view.
    enum ServerState: Equatable { case unknown, serverDown, routerMissing, ready }
    @Published private(set) var serverState: ServerState = .unknown
    /// Paused items whose Resume will restart the file from zero (see lifecycle notes above).
    @Published private(set) var interruptedIDs: Set<String> = []

    var activeCount: Int { items.filter { $0.isActive }.count }
    var runningCount: Int { items.filter { $0.status == .running }.count }
    var hasInterrupted: Bool { !interruptedIDs.isEmpty }

    /// Total bytes of finished downloads still stored (the files live in the server's dir).
    var totalFinishedBytes: Double {
        items.filter { $0.isDone }.reduce(0) { $0 + $1.total }
    }

    // MARK: Persistence (UI-side mirror keyed by id; the server owns the records)

    struct MirrorEntry: Codable {
        var url: String
        var title: String?
        var poster: String?
        var addedAt: Date
        var isTorrent: Bool
        /// Whether we last saw this id `running` — drives the pending-row label after a restart.
        var wasRunning: Bool
    }
    private var mirror: [String: MirrorEntry] = [:]
    private static let mirrorKey = "stremiox.downloads.mirror.v1"

    /// Ids the user paused via the UI IN THIS SESSION. Paused items NOT in this set were paused
    /// by a previous session (or survive a server restart), and /resume restarts them from zero on
    /// this server build — verified with kill -9 mid-download + restart.
    private var pausedThisSession: Set<String> = []

    private var pollTask: Task<Void, Never>?

    /// Auto-remove finished items once the server reports them finished (client-side policy; the
    /// server has no such option). Default off: silently deleting an offline file is wrong.
    static let autoDeleteKey = "stremiox.downloads.autoDeleteAfterFinish"
    var autoDeleteAfterFinish: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoDeleteKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoDeleteKey) }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.mirrorKey),
           let decoded = try? JSONDecoder().decode([String: MirrorEntry].self, from: data) {
            mirror = decoded
        }
        // Render the mirror immediately (all pending) so the page shows something before boot.
        var interrupted = Set<String>()
        items = Self.render(mirror: mirror, records: nil,
                            pausedThisSession: pausedThisSession, interruptedIDs: &interrupted)
        interruptedIDs = interrupted
    }

    // MARK: Lifecycle

    /// Start the poll loop. Idempotent. Called at app launch; `resumePollingOnForeground` re-syncs
    /// on every foreground (the node runtime is suspended with the app — downloads are
    /// foreground-only, and the UI says so rather than pretending otherwise).
    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncOnce()
                let fast = (self?.runningCount ?? 0) > 0 || self?.serverState == .unknown
                try? await Task.sleep(nanoseconds: fast ? 1_000_000_000 : 5_000_000_000)
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    func resumePollingOnForeground() {
        Task { await syncOnce() }   // immediate resync; the loop picks its cadence from state
    }

    // MARK: Sync

    /// One /getAll round-trip → merged item list. Failures are non-destructive: the mirror stands.
    func syncOnce() async {
        switch await DownloadService.getAll() {
        case .failure("not mounted"):
            // The HTTP server ANSWERED but the download router is not mounted (custom remote
            // server without the key/env). Surface honestly; mirror stands.
            serverState = .routerMissing
        case .failure(let e):
            serverState = .serverDown
            Self.log.warning("getAll failed: \(e, privacy: .public)")
        case .success(let records):
            serverState = .ready
            // Reconcile FIRST so a record the server dropped (deleted elsewhere, or a partial the
            // server pruned on boot) can't render one stale cycle as a phantom "pending" row.
            reconcile(with: records)
            var interrupted = Set<String>()
            items = Self.render(mirror: mirror, records: records,
                                pausedThisSession: pausedThisSession, interruptedIDs: &interrupted)
            interruptedIDs = interrupted
            saveMirror()
            autoDeleteFinishedIfNeeded(records: records)
        }
    }

    /// A successful /getAll is the authoritative list (the Swift store mirrors the server), so ids
    /// the server no longer knows are dropped — including ones we last saw running whose partial
    /// file the server deleted on boot (goal doc #16 note). Ids the server has but the mirror lost
    /// are adopted minimally so they still render and can be deleted. Pure (returns the new mirror)
    /// so the reducer is unit-testable without a network.
    nonisolated static func reconciled(mirror: [String: MirrorEntry], records: [DownloadRecord]) -> [String: MirrorEntry] {
        var m = mirror
        let liveIDs = Set(records.map(\.id))
        for id in m.keys where !liveIDs.contains(id) {
            m.removeValue(forKey: id)
        }
        for r in records where m[r.id] == nil {
            m[r.id] = MirrorEntry(url: r.url ?? "", title: r.resolvedFileName, poster: nil,
                                  addedAt: Date(timeIntervalSince1970: 0),
                                  isTorrent: (r.url ?? "").hasPrefix("magnet:"),
                                  wasRunning: r.status == "running")
        }
        return m
    }

    private func reconcile(with records: [DownloadRecord]) {
        mirror = Self.reconciled(mirror: mirror, records: records)
    }

    /// Merge server records with the mirror into renderable items. A record the server does not
    /// (yet) answer for renders `.pending` so the page keeps showing it while node re-boots.
    nonisolated static func render(mirror: [String: MirrorEntry], records: [DownloadRecord]?,
                       pausedThisSession: Set<String>,
                       interruptedIDs: inout Set<String>) -> [DownloadItem] {
        var items: [DownloadItem] = []
        var seen = Set<String>()
        var byID: [String: Date] = [:]
        for (id, m) in mirror { byID[id] = m.addedAt }

        if let records {
            for r in records {
                seen.insert(r.id)
                let m = mirror[r.id]
                let status: DownloadItem.Status
                switch r.status ?? "" {
                case "running": status = .running
                case "paused": status = .paused
                case "finished": status = .finished
                case "error": status = .error
                default: status = .pending
                }
                // A paused item we did not pause this session will restart from zero on /resume.
                let interrupted = status == .paused && !pausedThisSession.contains(r.id)
                if interrupted { interruptedIDs.insert(r.id) }
                items.append(DownloadItem(
                    id: r.id,
                    url: r.url ?? m?.url ?? "",
                    fileName: r.resolvedFileName,
                    title: m?.title,
                    poster: m?.poster,
                    total: r.total ?? 0,
                    downloaded: r.downloaded ?? 0,
                    speed: status == .running ? (r.speed ?? 0) : 0,
                    status: status,
                    error: r.error,
                    transport: (r.url ?? m?.url ?? "").hasPrefix("magnet:") ? .torrent : .direct,
                    interrupted: interrupted
                ))
            }
        }
        for (id, m) in mirror where !seen.contains(id) {
            items.append(DownloadItem(
                id: id, url: m.url, fileName: nil, title: m.title, poster: m.poster,
                total: 0, downloaded: 0, speed: 0,
                status: .pending, error: nil,
                transport: m.isTorrent ? .torrent : .direct,
                interrupted: false
            ))
        }
        return items.sorted { a, b in
            let (ra, rb) = (rankStatus(a), rankStatus(b))
            if ra != rb { return ra < rb }
            return (byID[a.id] ?? .distantPast) > (byID[b.id] ?? .distantPast)
        }
    }

    nonisolated static func rankStatus(_ i: DownloadItem) -> Int {
        switch i.status {
        case .running: return 0
        case .pending: return 1
        case .paused: return 2
        case .error: return 3
        case .finished: return 4
        }
    }

    private func saveMirror() {
        if let data = try? JSONEncoder().encode(mirror) {
            UserDefaults.standard.set(data, forKey: Self.mirrorKey)
        }
    }

    private func autoDeleteFinishedIfNeeded(records: [DownloadRecord]) {
        guard autoDeleteFinishedRecordsEnabled() else { return }
        for r in records where r.status == "finished" {
            Self.log.info("auto-delete after finish: \(r.id, privacy: .public)")
            Task { await self.remove(id: r.id) }
        }
    }

    /// Split out so the auto-delete policy is one obvious read.
    private func autoDeleteFinishedRecordsEnabled() -> Bool { autoDeleteAfterFinish }

    // MARK: Actions

    enum AddError: Error, Equatable {
        case serverUnreachable        // node not up (yet) / exited / disabled
        case routerMissing            // server alive but downloads not mounted (custom server)
        case unsupportedMagnet        // this server build cannot download torrents (verified error)
        case server(String)           // the server's error message verbatim
    }

    /// Start a download. Direct/debrid HTTP(S) URLs go straight to /add. A magnet is attempted only
    /// where torrents are allowed, and a server that rejects it (the desktop server.js has no
    /// torrent downloader — verified) surfaces `.unsupportedMagnet` WITHOUT keeping a doomed record.
    @discardableResult
    func add(url downloadURL: String, title: String?, poster: String?) async -> Result<Void, AddError> {
        let isMagnet = downloadURL.hasPrefix("magnet:")
        #if STREMIOX_NO_EMBEDDED_SERVER
        if isMagnet { return .failure(.unsupportedMagnet) }
        #endif
        if isMagnet && PlaybackSettings.torrentsDisabled { return .failure(.unsupportedMagnet) }

        switch await DownloadService.add(url: downloadURL, playerURL: nil) {
        case .failure("not mounted"):
            serverState = .routerMissing
            return .failure(.routerMissing)
        case .failure(let msg):
            if serverState == .unknown || serverState == .serverDown {
                return .failure(.serverUnreachable)
            }
            return .failure(.server(msg))
        case .success(let rec):
            if rec.status == "error", (rec.url ?? "").hasPrefix("magnet:") {
                _ = await DownloadService.remove(id: rec.id)
                mirror.removeValue(forKey: rec.id)
                saveMirror()
                return .failure(.unsupportedMagnet)
            }
            // Mark it running NOW so the mirror shows it instantly (no poll wait) and the book-
            // keeping knows it was in flight.
            mirror[rec.id] = MirrorEntry(url: downloadURL, title: title, poster: poster,
                                         addedAt: Date(), isTorrent: isMagnet, wasRunning: true)
            var interrupted = Set<String>()
            items = Self.render(mirror: mirror, records: nil,
                                pausedThisSession: pausedThisSession, interruptedIDs: &interrupted)
            saveMirror()
            Self.log.info("download added id=\(rec.id, privacy: .public) magnet=\(isMagnet)")
            Task { await self.syncOnce() }
            return .success(())
        }
    }

    func pause(id: String) async { await act(.pause, id: id) }
    func resume(id: String) async { await act(.resume, id: id) }
    func remove(id: String) async { await act(.remove, id: id) }

    enum Act { case pause, resume, remove }

    private func act(_ act: Act, id: String) async {
        let result: Result<Void, String>
        switch act {
        case .pause:
            result = await DownloadService.pause(id: id)
            if case .success = result {
                pausedThisSession.insert(id)
                mirror[id]?.wasRunning = false
                interruptedIDs.remove(id)
                saveMirror()
            }
        case .resume:
            result = await DownloadService.resume(id: id)
            if case .success = result {
                pausedThisSession.remove(id)
                interruptedIDs.remove(id)
                mirror[id]?.wasRunning = true
                saveMirror()
            }
        case .remove:
            result = await DownloadService.remove(id: id)
            if case .success = result {
                mirror.removeValue(forKey: id)
                pausedThisSession.remove(id)
                interruptedIDs.remove(id)
                saveMirror()
            }
        }
        if case .failure(let e) = result {
            Self.log.error("downloads action \(String(describing: act), privacy: .public) id=\(id, privacy: .public) failed: \(e, privacy: .public)")
        }
        await syncOnce()
    }

    /// Bulk: restart every interrupted (cross-restart paused) download. Each such /resume restarts
    /// from zero on this server build (verified), which is why the button says Restart.
    func resumeAllInterrupted() async {
        for id in Array(interruptedIDs) { await act(.resume, id: id) }
    }

    /// Bulk: remove every download. This server build has NO /removeAll route (verified: it falls
    /// through to the torrent handler and 500s), so this loops /remove id by id.
    func removeAllConfirmed() async {
        for i in items { await act(.remove, id: i.id) }
        for id in mirror.keys where !items.contains(where: { $0.id == id }) {
            await act(.remove, id: id)
        }
    }

    /// The playable loopback URL for a finished download (works in airplane mode; the server serves
    /// byte ranges — verified). nil for anything not finished.
    func playableURL(for id: String) -> URL? {
        items.first(where: { $0.id == id })?.status == .finished ? DownloadService.streamURL(id: id) : nil
    }

    /// One-line state for the Downloads toolbar / Settings diagnostics row.
    var serverStateText: String {
        switch serverState {
        case .unknown: return "Checking…"
        case .serverDown: return "Streaming server offline"
        case .routerMissing: return "Downloads unavailable on this server"
        case .ready: return "Connected"
        }
    }
}
