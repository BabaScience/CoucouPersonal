#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Model

struct YTVideo: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let url: String
    let published: Date
    let views: Int
}

/// One line of a Claude conversation, as the pages show it.
struct StudioMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, activity, error }
    var id = UUID()
    let role: Role
    let text: String
}

/// The YouTube studio: the channel's public numbers and a Claude workspace for it.
///
/// Everything lives in `~/CoucouStudio/<handle>/`: Claude reads `CLAUDE.md` (its memory of the
/// channel) and `channel.md` (the latest numbers, rewritten on every refresh), and saves scripts,
/// research and ideas next to them. Skills dropped in `.claude/skills/` are picked up by Claude.
@MainActor
final class YouTubeStudio: ObservableObject {
    static let shared = YouTubeStudio()

    let handle = "inspiration_illimitee"

    @Published private(set) var channelTitle = "Inspiration Illimitée"
    @Published private(set) var subscribers: String?
    @Published private(set) var videos: [YTVideo] = []
    @Published private(set) var refreshing = false
    @Published private(set) var refreshError: String?

    // From the YouTube APIs once signed in (YouTubeAuth).
    @Published private(set) var apiChannel: YTChannel?
    @Published private(set) var videoStats: [YTVideoStat] = []
    /// Videos in the period's top list that aren't among the latest uploads.
    @Published private(set) var olderVideos: [YTVideoStat] = []
    /// Every known video's title, by ID.
    var videoTitles: [String: String] {
        Dictionary((videoStats + olderVideos).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    }
    @Published private(set) var analytics: YTAnalytics?
    @Published private(set) var loadingAPI = false
    @Published private(set) var apiError: String?
    /// The channel Google signed in to when it isn't this studio's (a Brand Account picked by mistake).
    @Published private(set) var wrongChannel: String?
    @Published var periodDays = 28 {
        didSet { if oldValue != periodDays { Task { await refreshAPI() } } }
    }

    @Published private(set) var messages: [StudioMessage] = []
    @Published private(set) var running = false
    private var sessionId: String?
    private var run: ClaudeCLI.Run?

    private var channelIdKey: String { "youtube.\(handle).channelId" }

    var channelURL: URL { URL(string: "https://www.youtube.com/@\(handle)")! }

    var workspace: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("CoucouStudio", isDirectory: true)
            .appendingPathComponent(handle, isDirectory: true)
    }
    private var stateFile: URL { workspace.appendingPathComponent(".coucou/conversation.json") }

    private init() {
        loadConversation()
    }

    // MARK: Channel data

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        refreshError = nil
        defer { refreshing = false }
        do {
            var channelId = UserDefaults.standard.string(forKey: channelIdKey)
            let page = try await fetchText(channelURL, english: true)
            if let id = firstMatch(#""externalId":"(UC[\w-]+)""#, in: page) {
                channelId = id
                UserDefaults.standard.set(id, forKey: channelIdKey)
            }
            if let subs = firstMatch(#"([\d.,]+[KMB]?) subscribers"#, in: page) { subscribers = subs }
            guard let channelId,
                  let feedURL = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)") else {
                refreshError = "Couldn't find the channel."
                return
            }
            let (data, _) = try await URLSession.shared.data(from: feedURL)
            let parsed = YTFeedParser.parse(data)
            if let title = parsed.title { channelTitle = title }
            videos = parsed.videos
            ensureWorkspace()
            writeChannelFile()
        } catch {
            refreshError = error.localizedDescription
        }
    }

    /// Everything from the APIs: channel, the latest 100 uploads, analytics for `periodDays`.
    func refreshAPI() async {
        guard YouTubeAuth.shared.signedIn, !loadingAPI else { return }
        loadingAPI = true
        apiError = nil
        defer { loadingAPI = false }
        do {
            let channel = try await YouTubeAPI.channel()
            // The account may manage several channels: only this studio's channel is used.
            if let expected = UserDefaults.standard.string(forKey: channelIdKey), channel.id != expected {
                apiChannel = nil
                videoStats = []
                analytics = nil
                wrongChannel = channel.title
                return
            }
            wrongChannel = nil
            apiChannel = channel
            channelTitle = channel.title
            subscribers = channel.subscribers.formatted(.number.notation(.compactName))
            async let vids = YouTubeAPI.videos(playlist: channel.uploadsPlaylist)
            async let stats = YouTubeAPI.analytics(days: periodDays)
            videoStats = try await vids
            let a = try await stats
            // Top videos of the period can be older than the uploads fetched: get their titles too.
            let known = Set(videoStats.map(\.id))
            let missing = a.topVideos.map(\.id).filter { !known.contains($0) }
            if !missing.isEmpty, let extra = try? await YouTubeAPI.stats(ids: missing) {
                olderVideos = extra
            }
            analytics = a
            ensureWorkspace()
            writeAnalyticsFile()
        } catch {
            apiError = error.localizedDescription
        }
    }

    /// The API numbers as Markdown, for Claude (`analytics.md` in the studio folder).
    private func writeAnalyticsFile() {
        guard let c = apiChannel else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var l = ["# \(c.title) — YouTube Analytics", "",
                 "Fetched by Coucou on \(df.string(from: Date())) from the YouTube Data and Analytics APIs.", "",
                 "- Subscribers: \(c.subscribers)", "- Lifetime views: \(c.views)", "- Videos: \(c.videos)"]
        if let a = analytics {
            l += ["", "## Last \(a.days) days", "",
                  "- Views: \(a.views)", "- Watch time: \(a.minutes / 60) hours",
                  "- Net subscribers: \(a.netSubscribers)",
                  "- Average view duration: \(Int(a.averageViewDuration)) s",
                  "- Average percentage viewed: \(String(format: "%.1f", a.averageViewPercentage)) %"]
            if let r = a.revenue { l.append("- Estimated revenue: \(String(format: "%.2f", r))") }
            l += ["", "### Daily", "", "| Day | Views | Watch min | Subs + | Subs − |", "|---|---:|---:|---:|---:|"]
            l += a.daily.map { "| \(df.string(from: $0.date)) | \($0.views) | \($0.minutes) | \($0.subscribersGained) | \($0.subscribersLost) |" }
            func slices(_ title: String, _ s: [YTSlice], _ unit: String) {
                guard !s.isEmpty else { return }
                l += ["", "### \(title)", ""] + s.map { "- \($0.label): \(String(format: "%.1f", $0.value))\(unit)" }
            }
            slices("Traffic sources (views)", a.traffic, "")
            slices("Top countries (views)", a.countries, "")
            slices("Audience (age, gender — % of viewers)", a.ageGender, " %")
            if !a.topVideos.isEmpty {
                let titles = videoTitles
                l += ["", "### Top videos in the period", "", "| Video | Views | Watch min | Avg % viewed | Subs + |", "|---|---:|---:|---:|---:|"]
                l += a.topVideos.map { "| \((titles[$0.id] ?? $0.id).replacingOccurrences(of: "|", with: "/")) | \($0.views) | \($0.minutes) | \(String(format: "%.0f", $0.averageViewPercentage)) | \($0.subscribersGained) |" }
            }
        }
        if !videoStats.isEmpty {
            l += ["", "## Latest \(videoStats.count) uploads (lifetime)", "",
                  "| Published | Length | Views | Likes | Comments | Engagement % | Title |", "|---|---:|---:|---:|---:|---:|---|"]
            l += videoStats.map { "| \(df.string(from: $0.published)) | \($0.seconds)s | \($0.views) | \($0.likes) | \($0.comments) | \(String(format: "%.1f", $0.engagement)) | \($0.title.replacingOccurrences(of: "|", with: "/")) |" }
        }
        try? l.joined(separator: "\n").write(to: workspace.appendingPathComponent("analytics.md"), atomically: true, encoding: .utf8)
    }

    private func fetchText(_ url: URL, english: Bool) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        if english { req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language") }
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(decoding: data, as: UTF8.self)
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: Workspace

    func ensureWorkspace() {
        let fm = FileManager.default
        for sub in ["scripts", "research", "ideas", ".claude/skills", ".coucou"] {
            try? fm.createDirectory(at: workspace.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let memory = workspace.appendingPathComponent("CLAUDE.md")
        if !fm.fileExists(atPath: memory.path) {
            try? Self.initialMemory(handle: handle, title: channelTitle).write(to: memory, atomically: true, encoding: .utf8)
        }
    }

    private func writeChannelFile() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var lines = ["# \(channelTitle) — latest numbers",
                     "",
                     "Updated by Coucou on \(df.string(from: Date())). Public data only (no YouTube Studio access).",
                     "",
                     "- Channel: \(channelURL.absoluteString)",
                     "- Subscribers: \(subscribers ?? "unknown")",
                     "",
                     "## Latest \(videos.count) uploads (newest first)",
                     "",
                     "| Published | Views | Title | Link |",
                     "|---|---:|---|---|"]
        for v in videos {
            let title = v.title.replacingOccurrences(of: "|", with: "/")
            lines.append("| \(df.string(from: v.published)) | \(v.views) | \(title) | \(v.url) |")
        }
        try? lines.joined(separator: "\n").write(to: workspace.appendingPathComponent("channel.md"),
                                                 atomically: true, encoding: .utf8)
    }

    func openWorkspace() {
        ensureWorkspace()
        NSWorkspace.shared.open(workspace)
    }

    private static func initialMemory(handle: String, title: String) -> String {
        """
        # \(title) — studio memory

        This folder is the studio for the YouTube channel **\(title)** (https://www.youtube.com/@\(handle)),
        used from the Coucou app on the owner's Mac. You are the channel's assistant: script writer,
        researcher and strategist.

        ## Files
        - `channel.md` — the latest public numbers (subscribers, recent uploads with views). Rewritten by
          Coucou on every refresh: read it, don't edit it.
        - `scripts/` — video scripts, one Markdown file per video (`YYYY-MM-DD-short-title.md`).
        - `research/` — market and competitor research reports.
        - `ideas/` — idea lists and the backlog.
        - `.claude/skills/` — skills the owner adds later.

        ## How to work
        - The channel publishes in French: write scripts, titles, descriptions and hashtags in French
          unless asked otherwise. Talk to the owner in the language they write to you in.
        - Save anything worth keeping (scripts, reports, idea lists) as a file in the right folder and
          say where you saved it.
        - Use web search for market research and say where facts come from.
        - Keep this file up to date: when you learn something lasting about the channel (audience,
          content pillars, what performs, the owner's preferences), add it under the sections below.

        ## Channel profile
        _Not analysed yet. Run "Understand my channel" in Coucou._

        ## What performs

        ## Owner's preferences
        """
    }

    // MARK: Conversation

    func send(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        ensureWorkspace()
        if !videos.isEmpty { writeChannelFile() }
        messages.append(StudioMessage(role: .user, text: text))
        running = true
        let model = UserDefaults.standard.string(forKey: ClaudeCLI.modelKey)
        run = ClaudeCLI.run(
            prompt: text,
            cwd: workspace,
            sessionId: sessionId,
            systemPrompt: Self.chatSystemPrompt,
            allowedTools: ["WebSearch", "WebFetch", "Read", "Write", "Edit", "Glob", "Grep", "Skill",
                           "Bash(\(VideoTool.install(in: workspace).path):*)", "Bash(.coucou/bin/coucou-video:*)"],
            permissionMode: "acceptEdits",
            model: model
        ) { [weak self] event in
            self?.handle(event)
        }
        if run == nil { running = false }
    }

    private func handle(_ event: ClaudeCLI.Event) {
        switch event {
        case .session(let id):
            sessionId = id
        case .text(let t):
            messages.append(StudioMessage(role: .assistant, text: t))
        case .tool(_, let summary):
            messages.append(StudioMessage(role: .activity, text: summary))
        case .done(let result, let id, let isError):
            if let id { sessionId = id }
            if isError {
                var text = result
                if ClaudeCLI.isAuthError(result) {
                    text += "\n\nSign in again: run `claude setup-token` in Terminal and paste the token in Coucou → Claude."
                }
                messages.append(StudioMessage(role: .error, text: text))
            } else if !result.isEmpty, !messages.contains(where: { $0.role == .assistant && $0.text == result }) {
                messages.append(StudioMessage(role: .assistant, text: result))
            }
            running = false
            run = nil
            saveConversation()
        }
    }

    private static let chatSystemPrompt = """
    You are working inside the YouTube studio folder described in CLAUDE.md. For numbers, read \
    analytics.md first (YouTube Analytics from the API: daily views, watch time, subscribers, traffic \
    sources, countries, audience, every upload's stats) and channel.md otherwise.

    SEE THE VIDEOS, NOT ONLY THEIR NUMBERS. Titles can be misleading: before judging a video's \
    content, hook, message, visuals or whether its title fits, run \
    `.coucou/bin/coucou-video <video ID or link>` (with the Bash tool, from this folder; IDs are in \
    analytics.md). It saves videos/<id>/ with transcript.txt (what is said, timestamped), sheet.jpg \
    (12 screenshots in one image) and meta.txt. Read sheet.jpg and transcript.txt, then base your \
    analysis on what is actually said and shown — quote the first seconds for the hook.

    ANSWER AS A SHORT PRESENTATION, NOT AS PROSE. The owner doesn't like reading: the app plays a \
    fenced code block whose language is `deck` as animated slides (numbers count up, charts grow, \
    points appear one by one). Format:

    ```deck
    {"title":"Channel check-up","slides":[
      {"kind":"title","title":"Your channel is asleep","subtitle":"Great topic, no rhythm","icon":"moon.zzz","narration":"Good news and bad news: your topic works, but the channel has gone quiet."},
      {"kind":"stats","title":"Last 28 days","stats":[{"label":"Views","value":4500,"delta":"-8%"},{"label":"Watch hours","value":729},{"label":"Subscribers","value":-5}]},
      {"kind":"chart","title":"Top videos","chart":{"type":"bar","unit":"views","data":[{"label":"Lâcher prise","value":3356},{"label":"Philosophes","value":391}]},"caption":"One video makes 75 % of views"},
      {"kind":"points","title":"Do this week","points":["Post 3 Shorts","Reuse the 'lâcher prise' hook","No hashtags in titles"],"narration":"This week, three Shorts. Start with the hook that already worked, and keep the hashtags out of the titles."},
      {"kind":"quote","text":"Consistency beats perfection.","caption":"Your next 30 days"}
    ]}
    ```

    Rules: 4 to 8 slides, one idea per slide. At most 4 points per slide, each at most 10 words. \
    Put numbers in "stats" as JSON numbers (they count up). Use a chart slide whenever numbers \
    compare (chart type "bar", "line" or "donut"; at most 8 data points; labels under 25 characters). \
    End with a "points" slide of concrete actions or a "quote" takeaway. "icon" is an SF Symbol name. \
    Give every slide a "narration": what a presenter says while it shows — one or two natural spoken \
    sentences (at most 35 words), in the owner's language, telling the story behind the slide rather \
    than reading it (round the numbers, no symbols or emojis). A voice reads it aloud. \
    The JSON must be valid: double quotes, no comments, no trailing commas. Outside the deck write at \
    most one short sentence. Use the language the owner writes in.
    Exception: when the owner asks for text to use (a script, titles, a description, hashtags), give \
    that text plainly so it can be copied, with at most a 2-slide deck if it helps. Long reports go \
    into a file in research/ — say where — while the chat shows the deck.
    """

    func stop() { run?.cancel() }

    func newConversation() {
        stop()
        messages = []
        sessionId = nil
        saveConversation()
    }

    private struct Saved: Codable { var sessionId: String?; var messages: [StudioMessage] }

    private func saveConversation() {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Saved(sessionId: sessionId, messages: messages)) {
            try? data.write(to: stateFile)
        }
    }

    private func loadConversation() {
        guard let data = try? Data(contentsOf: stateFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        sessionId = saved.sessionId
        messages = saved.messages
    }
}

// MARK: - Feed parsing

/// Reads a channel's public Atom feed: its title and the latest 15 uploads with their views.
private final class YTFeedParser: NSObject, XMLParserDelegate {
    private(set) var title: String?
    private(set) var videos: [YTVideo] = []
    private var inEntry = false
    private var text = ""
    private var id = "", vTitle = "", link = "", published = Date(), views = 0

    static func parse(_ data: Data) -> (title: String?, videos: [YTVideo]) {
        let p = YTFeedParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return (p.title, p.videos)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "entry":
            inEntry = true
            id = ""; vTitle = ""; link = ""; views = 0; published = Date()
        case "link" where inEntry:
            if attributes["rel"] == "alternate" { link = attributes["href"] ?? "" }
        case "media:statistics":
            views = Int(attributes["views"] ?? "") ?? 0
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title":
            if inEntry { vTitle = value } else if title == nil { title = value }
        case "yt:videoId":
            id = value
        case "published" where inEntry:
            published = ISO8601DateFormatter().date(from: value) ?? Date()
        case "entry":
            inEntry = false
            if !id.isEmpty {
                videos.append(YTVideo(id: id, title: vTitle,
                                      url: link.isEmpty ? "https://www.youtube.com/watch?v=\(id)" : link,
                                      published: published, views: views))
            }
        default:
            break
        }
        text = ""
    }
}

#endif
