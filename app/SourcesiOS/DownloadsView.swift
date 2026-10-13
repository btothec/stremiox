import SwiftUI

/// The Downloads page: everything queued / in flight / finished, straight from the embedded
/// server (the single source of truth), plus an empty state and honest lifecycle notices.
/// Foreground-only by design: the node runtime is suspended with the app, and this page says so
/// on running jobs rather than faking a background toggle.
struct DownloadsView: View {
    @ObservedObject private var store = DownloadStore.shared
    @EnvironmentObject private var theme: ThemeManager
    var openPlayer: (URL, String) -> Void = { _, _ in }   // handed in by the root (uses PlayerScreen)

    @State private var confirmDeleteID: String?
    @State private var confirmDeleteAll = false
    @State private var addError: String?

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            content
        }
        .confirmationDialog("Delete this download? This removes the file from the device.",
                            isPresented: deleteBinding,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = confirmDeleteID { Task { await store.remove(id: id) } }
                confirmDeleteID = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteID = nil }
        }
        .confirmationDialog("Delete ALL downloads? Files are removed from the device.",
                            isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { Task { await store.removeAllConfirmed() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Download failed", isPresented: noteBinding,
               actions: {
            Button("OK", role: .cancel) { addError = nil }
        }, message: { Text(addError ?? "") })
    }

    /// The alert/confirm bindings kept as one explicit type each so the type-checker stays quick.
    private var deleteBinding: Binding<Bool> {
        Binding(get: { confirmDeleteID != nil }, set: { if !$0 { confirmDeleteID = nil } })
    }

    private var noteBinding: Binding<Bool> {
        Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if store.items.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("No downloads")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Long-press any source on a title and tap Download to save it for offline viewing. Downloads run while the app is open.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.sm) {
                header
                if store.hasInterrupted {
                    interruptedBanner
                }
                ForEach(store.items) { item in
                    row(item)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.lg)
        }
        .refreshable { await store.syncOnce() }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text("Downloads")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                if !store.items.isEmpty {
                    Button("Clear Finished", action: clearFinished)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            HStack(spacing: Theme.Space.sm) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(store.serverStateText)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                Text(store.totalFinishedBytes > 0
                     ? "\(DownloadItem.humanBytes(store.totalFinishedBytes)) stored"
                     : "\(store.items.count) item\(store.items.count == 1 ? "" : "s")")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.top, Theme.Space.sm)
    }

    private var statusColor: Color {
        switch store.serverState {
        case .ready: return Theme.Palette.accent
        case .unknown: return Theme.Palette.textTertiary
        case .serverDown, .routerMissing: return .orange
        }
    }

    /// Cross-restart interrupted downloads: this server build restarts them from zero, so the bulk
    /// button says "Restart" not "Resume" (verified with kill -9 mid-download + restart).
    private var interruptedBanner: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Some downloads were interrupted while the app was closed. Restarting them begins from 0% again.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            Button {
                Task { await store.resumeAllInterrupted() }
            } label: {
                Label("Restart interrupted downloads", systemImage: "arrow.clockwise")
                    .font(Theme.Typography.label)
            }
            .buttonStyle(PrimaryActionStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(Theme.Palette.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    // MARK: Row

    @ViewBuilder private func row(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                poster(item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: Theme.Space.sm) {
                        statusPill(item)
                        if let t = item.humanTotal {
                            Text(t).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if item.status == .running || item.status == .paused || item.status == .pending {
                ProgressView(value: item.fraction)
                    .tint(item.status == .paused ? Theme.Palette.textTertiary : Theme.Palette.accent)
                HStack(spacing: Theme.Space.sm) {
                    if item.status == .running {
                        Text("\(Int(item.fraction * 100))% · \(item.humanSpeed)")
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                        if let eta = item.humanETA {
                            Text("· \(eta) left").font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                        }
                    } else if item.status == .paused {
                        Text("\(Int(item.fraction * 100))%")
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Spacer()
                    actions(item)
                }
                if item.status == .running {
                    Label("Keeps running only while StremioX is open", systemImage: "app.badge.clock")
                        .font(Theme.Typography.eyebrow)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            } else if item.status == .error {
                Text(item.error ?? "Download failed.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.danger)
                    .lineLimit(3)
                HStack { Spacer(); actions(item) }
            } else {
                // finished
                HStack {
                    Spacer()
                    actions(item)
                }
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    @ViewBuilder private func poster(_ item: DownloadItem) -> some View {
        Group {
            if let poster = item.poster, let url = URL(string: poster) {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(2/3, contentMode: .fill)
                } placeholder: {
                    posterPlaceholder
                }
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            } else {
                posterPlaceholder
            }
        }
    }

    private var posterPlaceholder: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
            .fill(Theme.Palette.surface3)
            .frame(width: 44, height: 66)
            .overlay(
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.Palette.textTertiary)
            )
    }

    private func statusPill(_ item: DownloadItem) -> some View {
        let (text, color): (String, Color) = {
            switch item.status {
            case .running: return ("DOWNLOADING", Theme.Palette.accent)
            case .paused: return (item.interrupted ? "INTERRUPTED" : "PAUSED", .orange)
            case .finished: return ("OFFLINE READY", .green)
            case .error: return ("FAILED", .red)
            case .pending: return ("WAITING", Theme.Palette.textTertiary)
            }
        }()
        return Text(text)
            .font(Theme.Typography.eyebrow).tracking(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder private func actions(_ item: DownloadItem) -> some View {
        HStack(spacing: Theme.Space.sm) {
            switch item.status {
            case .running:
                Button { Task { await store.pause(id: item.id) } } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
            case .paused:
                Button { Task { await store.resume(id: item.id) } } label: {
                    Label(item.interrupted ? "Restart" : "Resume",
                          systemImage: item.interrupted ? "arrow.clockwise" : "play.fill")
                }
            case .finished:
                Button { play(item) } label: {
                    Label("Play", systemImage: "play.fill")
                }
            case .error:
                Button { Task { await store.resume(id: item.id) } } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            case .pending:
                EmptyView()
            }
            Button(role: .destructive) { confirmDeleteID = item.id } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(item.status == .finished ? Theme.Palette.accent : item.status == .error ? Theme.Palette.danger : nil)
    }

    private func play(_ item: DownloadItem) {
        guard let url = store.playableURL(for: item.id) else {
            addError = "This download is not finished, so there is no file to play yet."
            return
        }
        openPlayer(url, item.displayTitle)
    }

    private func clearFinished() {
        Task {
            for i in store.items where i.status == .finished {
                await store.remove(id: i.id)
            }
        }
    }
}
