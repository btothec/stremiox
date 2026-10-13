import XCTest
import Foundation

// Unit tests for the 0.7 download manager's client layer: the server contract decoding (fixtures
// are the EXACT JSON the vendored server.js returned when exercised under real node on 2026-10-13),
// URL building (percent-encoding of the /add url= parameter), ETA math, and the /getAll→store
// reducer (mirror reconcile + render ordering). The code under test (the five download files +
// StremioServer/TorrentTrackers/TrackPreferences) compiles INTO this bundle (no app host), so the
// types are visible directly with no import. No network, no server, no player.

private let fixtures = Bundle(for: BundleToken.self).url(forResource: "fixtures", withExtension: "json")

private final class BundleToken {}

final class DownloadContractTests: XCTestCase {

    // MARK: Fixtures (real captured responses)

    static func fixture(_ name: String) -> Data {
        guard let url = fixtures,
              let all = try? JSONData.read(url),
              let obj = all[name] as? [String: Any],
              let raw = obj["json"] as? String,
              let data = raw.data(using: .utf8) else {
            XCTFail("fixture \(name) missing"); return Data()
        }
        return data
    }

    // MARK: Record decoding

    func testRunningRecordDecodes() throws {
        let data = Self.fixture("add_running")
        let r = try JSONDecoder().decode(DownloadRecord.self, from: data)
        XCTAssertEqual(r.id, "dmf4fqij6za")
        XCTAssertEqual(r.url, "http://127.0.0.1:18081/big.mp4")
        XCTAssertEqual(r.status, "running")
        XCTAssertEqual(r.total, 0)
        XCTAssertEqual(r.downloaded, 0)
        XCTAssertNil(r.resolvedFileName)
    }

    func testProgressRecordDecodesWithPercentFloatAndFileName() throws {
        // Real shape: progress is a FLOAT percent (31.457279999999997), fileName is camelCase.
        let data = Self.fixture("get_running_with_progress")
        let r = try JSONDecoder().decode(DownloadRecord.self, from: data)
        XCTAssertEqual(r.id, "dmf4fqij6za")
        XCTAssertEqual(r.total, 40_000_000)
        XCTAssertEqual(r.downloaded, 12_582_912)
        XCTAssertEqual(r.progress!, 31.45728, accuracy: 0.0001)
        XCTAssertEqual(r.speed, 2_097_152)
        XCTAssertEqual(r.status, "running")
        XCTAssertEqual(r.resolvedFileName, "big.mp4")
    }

    func testErrorRecordDecodesMessage() throws {
        // The desktop server.js rejects magnets with an error RECORD (status "error"), not an error
        // envelope. The store keys off exactly this to surface "torrents cannot download".
        let data = Self.fixture("get_error_magnet")
        let r = try JSONDecoder().decode(DownloadRecord.self, from: data)
        XCTAssertEqual(r.status, "error")
        XCTAssertTrue(r.url!.hasPrefix("magnet:"))
        XCTAssertEqual(r.error, "Protocol \"magnet:\" not supported. Expected \"http:\"")
    }

    func testErrorEnvelopeDecodes() throws {
        let data = Self.fixture("get_missing_id")
        let env = try JSONDecoder().decode(DownloadServerError.self, from: data)
        XCTAssertEqual(env.error.message, "there is no download with this id")
    }

    func testUnknownExtraFieldsIgnored() throws {
        // Tolerant decoding: a future server build adding fields must not break us.
        let json = #"{"id":"x","url":"http://a/b","total":1,"downloaded":1,"progress":100,"speed":0,"status":"finished","fileName":"b","resume_data":{"anything":true},"brand_new_field":42,"playerUrl":"http://c"}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(DownloadRecord.self, from: json)
        XCTAssertEqual(r.status, "finished")
        XCTAssertEqual(r.resolvedFileName, "b")
    }

    func testSnakeCaseFileNameAccepted() throws {
        // The official MOBILE server build's records carry file_name (torrent transport); accept both.
        let json = #"{"id":"x","url":"http://a/b","status":"running","file_name":"mob.mkv"}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(DownloadRecord.self, from: json)
        XCTAssertEqual(r.resolvedFileName, "mob.mkv")
    }

    // MARK: URL building

    func testAddURLEncodesNestedURL() {
        // The url= value is itself a URL with :/?&= chars — they must be percent-encoded so the
        // server's querystring parser sees ONE url param (verified live: the server returns an error
        // envelope when the encoding is wrong).
        let u = DownloadService.url(route: "/add", query: ["url": "http://d.example/x/a.mp4?token=1&x=2"])
        XCTAssertNotNil(u)
        let s = u!.absoluteString
        XCTAssertTrue(s.hasPrefix("http://127.0.0.1:11470/"))
        XCTAssertTrue(s.contains("/downloader/add?url="))
        XCTAssertTrue(s.contains("token%3D1"))
        XCTAssertTrue(s.contains("%26x%3D2"))
        XCTAssertFalse(s.contains("&x=2"))   // the & must never survive raw into the value
    }

    func testStreamAndQueryItemsEncode() {
        let u = DownloadService.url(route: "/stream", query: ["id": "abc-123"])
        XCTAssertTrue(u!.absoluteString.hasSuffix("/downloader/stream?id=abc-123"))
    }

    func testRouteBaseCarriesIPCKeyUnderDownloader() {
        // Verified mount: /$SERVER_IPC_KEY/downloader
        let base = DownloadService.routeBase()
        XCTAssertTrue(base.hasSuffix("/\(DownloadIPCKey.current())/downloader"), base)
    }

    // MARK: ETA math

    func testETABasic() {
        let item = DownloadItem(id: "a", url: "http://h/f", fileName: "f", title: nil, poster: nil,
                                total: 1000, downloaded: 600, speed: 100, status: .running,
                                error: nil, transport: .direct, interrupted: false)
        XCTAssertEqual(item.fraction, 0.6, accuracy: 0.0001)
        XCTAssertEqual(item.estimatedSecondsRemaining, 4)
        XCTAssertEqual(item.humanETA, "4s")
    }

    func testETANilWhenPausedOrDoneOrNoSpeed() {
        func mk(status: DownloadItem.Status, total: Double, dl: Double, speed: Double) -> DownloadItem {
            DownloadItem(id: "a", url: "u", fileName: nil, title: nil, poster: nil,
                         total: total, downloaded: dl, speed: speed, status: status,
                         error: nil, transport: .direct, interrupted: false)
        }
        XCTAssertNil(mk(status: .paused, total: 1000, dl: 100, speed: 0).estimatedSecondsRemaining)
        XCTAssertNil(mk(status: .finished, total: 1000, dl: 1000, speed: 0).estimatedSecondsRemaining)
        XCTAssertNil(mk(status: .running, total: 1000, dl: 100, speed: 0).estimatedSecondsRemaining)
        XCTAssertNil(mk(status: .running, total: 0, dl: 0, speed: 500).estimatedSecondsRemaining)
    }

    func testHumanize() {
        XCTAssertEqual(DownloadItem.humanBytes(999), "999 B")
        XCTAssertEqual(DownloadItem.humanBytes(2048), "2.0 KiB")
        XCTAssertEqual(DownloadItem.humanBytes(20_971_520), "20.0 MiB")
        XCTAssertEqual(DownloadItem.humanBytes(3_221_225_472), "3.0 GiB")
        XCTAssertEqual(DownloadItem.humanDuration(90), "1m 30s")
        XCTAssertEqual(DownloadItem.humanDuration(3661), "1h 01m")
    }

    // MARK: Store reducer (/getAll → mirror + items)

    private func rec(_ id: String, _ url: String, _ status: String, total: Double = 0,
                     dl: Double = 0, speed: Double = 0) -> DownloadRecord {
        DownloadRecord(id: id, url: url, fileName: nil, file_name: nil, name: nil,
                       total: total, downloaded: dl, speed: speed,
                       progress: total > 0 ? dl / total * 100 : nil, status: status, error: nil)
    }
    private func entry(_ url: String = "u", running: Bool = false) -> DownloadStore.MirrorEntry {
        DownloadStore.MirrorEntry(url: url, title: "T", poster: nil, addedAt: Date(timeIntervalSince1970: 100),
                                  isTorrent: url.hasPrefix("magnet:"), wasRunning: running)
    }

    func testReconcileDropsServerGoneAndAdoptsUnknown() {
        let mirror = ["a": entry("http://x/a"), "b": entry("http://x/b", running: true)]
        let records = [rec("c", "http://x/c", "running")]
        let out = DownloadStore.reconciled(mirror: mirror, records: records)
        XCTAssertNil(out["a"])
        // 'b' was last seen running but the server does NOT list it (server deleted the partial on
        // boot, verified behavior): it must be DROPPED — the server is authoritative.
        XCTAssertNil(out["b"])
        XCTAssertNotNil(out["c"])
        XCTAssertEqual(out["c"]?.wasRunning, true)   // adopted from the record's own status
    }

    func testRenderInterruptedWhenPausedNotPausedThisSession() {
        var interrupted = Set<String>()
        let mirror = ["p": entry("http://x/p")]
        let records = [rec("p", "http://x/p", "paused", total: 100, dl: 40)]
        let items = DownloadStore.render(mirror: mirror, records: records,
                                         pausedThisSession: [], interruptedIDs: &interrupted)
        XCTAssertEqual(items.first?.status, .paused)
        XCTAssertEqual(items.first?.interrupted, true)
        XCTAssertEqual(interrupted, ["p"])
    }

    func testRenderNotInterruptedWhenUserPausedThisSession() {
        var interrupted = Set<String>()
        let mirror = ["p": entry("http://x/p")]
        let records = [rec("p", "http://x/p", "paused", total: 100, dl: 40)]
        let items = DownloadStore.render(mirror: mirror, records: records,
                                         pausedThisSession: ["p"], interruptedIDs: &interrupted)
        XCTAssertEqual(items.first?.interrupted, false)
        XCTAssertTrue(interrupted.isEmpty)
    }

    func testRenderPendingForMirrorWithoutServerRecordsAndOrdering() {
        var interrupted = Set<String>()
        let now = Date()
        let mirror = [
            "old": DownloadStore.MirrorEntry(url: "http://x/old", title: nil, poster: nil, addedAt: now.addingTimeInterval(-1000), isTorrent: false, wasRunning: false),
            "run": DownloadStore.MirrorEntry(url: "http://x/run", title: nil, poster: nil, addedAt: now, isTorrent: false, wasRunning: true),
        ]
        let records = [
            rec("fin", "http://x/fin", "finished", total: 100, dl: 100),
            rec("run", "http://x/run", "running", total: 100, dl: 10, speed: 5),
        ]
        let items = DownloadStore.render(mirror: mirror, records: records,
                                         pausedThisSession: [], interruptedIDs: &interrupted)
        // ordering: running first (rank 0), then the mirror-only PENDING row (rank 1) before
        // finished (rank 4) — active work stays on top of the page.
        XCTAssertEqual(items.map(\.id), ["run", "old", "fin"])
        XCTAssertEqual(items[0].status, .running)
        XCTAssertEqual(items[1].status, .pending)
        XCTAssertEqual(items[2].status, .finished)
    }

    func testTransportDerivedFromURL() {
        var interrupted = Set<String>()
        let records = [rec("m", "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567", "running")]
        let items = DownloadStore.render(mirror: [:], records: records,
                                         pausedThisSession: [], interruptedIDs: &interrupted)
        XCTAssertEqual(items.first?.transport, .torrent)
    }

    func testIPCKeyStableAndHex() {
        let a = DownloadIPCKey.current()
        let b = DownloadIPCKey.current()
        XCTAssertEqual(a, b)
        XCTAssertTrue(DownloadIPCKey.isValid(a))
    }
}

private enum JSONData {
    static func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "fixtures", code: 1)
        }
        return obj
    }
}
