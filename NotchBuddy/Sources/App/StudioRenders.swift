#if !APPSTORE
import AVKit
import SwiftUI

/// A render started by `coucou-render` (its record in the studio's .coucou/renders/).
struct RenderJob: Codable, Identifiable, Equatable {
    let id: String
    let episode: String
    let out: String
    let log: String
    let start: Double
    let end: Double
    let state: String
    let pid: String
}

/// Watches the renders: their progress while they run, then the video posted in the Studio chat.
@MainActor
final class StudioRenders: ObservableObject {
    static let shared = StudioRenders()

    @Published private(set) var running: [RenderJob] = []
    /// Seconds of video rendered so far, by job.
    @Published private(set) var done: [String: Double] = [:]
    private var timer: Timer?

    private var dir: URL { YouTubeStudio.shared.workspace.appendingPathComponent(".coucou/renders", isDirectory: true) }

    func start() {
        guard timer == nil else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { StudioRenders.shared.scan() }
        }
    }

    private func scan() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var now: [RenderJob] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let job = try? JSONDecoder().decode(RenderJob.self, from: data) else { continue }
            if job.state == "running" {
                now.append(job)
                done[job.id] = progress(job)
            } else {
                announce(job)
            }
        }
        if now != running { running = now.sorted { $0.id < $1.id } }
    }

    /// The last "  12.3s" line of the engine's log.
    private func progress(_ job: RenderJob) -> Double {
        guard let h = FileHandle(forReadingAtPath: job.log) else { return 0 }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 4096 ? size - 4096 : 0)
        let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        let last = tail.split(whereSeparator: \.isNewline).reversed().first { $0.trimmingCharacters(in: .whitespaces).hasSuffix("s") }
        return last.flatMap { Double($0.trimmingCharacters(in: .whitespaces).dropLast()) } ?? 0
    }

    /// Once per finished render: the video (or what went wrong) in the chat.
    private func announce(_ job: RenderJob) {
        let key = "render.announced.\(job.id)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if job.state == "done" {
            YouTubeStudio.shared.post("""
            Le rendu de **\(job.episode)** est prêt ✅

            ```video
            {"path":"\(job.out)","title":"\((job.out as NSString).lastPathComponent)"}
            ```
            """)
        } else {
            let log = (try? String(contentsOfFile: job.log, encoding: .utf8))?.split(separator: "\n").suffix(6).joined(separator: "\n") ?? ""
            YouTubeStudio.shared.post("Le rendu de **\(job.episode)** a échoué.\n\n```\n\(log)\n```", error: true)
        }
    }

    func stop(_ job: RenderJob) {
        let p = Process()
        p.executableURL = YouTubeStudio.shared.workspace.appendingPathComponent(".coucou/bin/coucou-render")
        p.arguments = ["stop", job.episode]
        p.currentDirectoryURL = YouTubeStudio.shared.workspace
        try? p.run()
    }
}

/// A studio file (only inside the studio folder: a path can't reach the rest of the Mac).
@MainActor
enum StudioFiles {
    static func url(_ path: String) -> URL? {
        let studio = YouTubeStudio.shared.workspace.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : studio.appendingPathComponent(path)
        let u = candidate.standardizedFileURL.resolvingSymlinksInPath()
        return u.path.hasPrefix(studio.path + "/") && FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}

/// "Rendering ep02 — 23 s / 57 s" with a bar and Stop.
struct StudioRenderBar: View {
    @ObservedObject private var renders = StudioRenders.shared

    var body: some View {
        ForEach(renders.running) { job in
            let t = renders.done[job.id] ?? 0
            let total = job.end > job.start ? job.end - job.start : 0
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rendering \(job.episode)" + (total > 0 ? " — \(Int(t)) s / \(Int(total)) s" : " — \(Int(t)) s done"))
                        .font(.system(size: 12, weight: .medium))
                    if total > 0 {
                        ProgressView(value: min(1, max(0, (t - job.start) / total))).tint(StudioPalette.red)
                    }
                }
                Spacer()
                Button("Stop") { renders.stop(job) }.buttonStyle(HubButtonStyle())
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
        }
    }
}

/// AppKit's player view. SwiftUI's `VideoPlayer`, built with Xcode 16.1's SDK, aborts on macOS 26
/// when its metadata loads (it crashed Coucou at launch with a video in the chat).
struct StudioPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// A video of the studio, playable in the chat.
struct StudioVideoView: View {
    let path: String
    let title: String?
    @State private var player: AVPlayer?

    var body: some View {
        if let url = StudioFiles.url(path) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(title ?? url.lastPathComponent, systemImage: "film").font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    HubIconButton(symbol: "arrow.up.forward.square", help: "Open") { NSWorkspace.shared.open(url) }
                    HubIconButton(symbol: "folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                StudioPlayerView(player: player)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
        } else {
            Label("Video not found: \(path)", systemImage: "film").font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
        }
    }
}
#endif
