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
        DispatchQueue.main.async { StudioRenders.shared.start() }
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
        connectArtlist()
        let memory = workspace.appendingPathComponent("CLAUDE.md")
        if !fm.fileExists(atPath: memory.path) {
            try? Self.initialMemory(handle: handle, title: channelTitle).write(to: memory, atomically: true, encoding: .utf8)
        }
    }

    /// Artlist's MCP server for the studio (images, animations, music and sound effects on the owner's
    /// Artlist account): declared in .mcp.json and enabled in .claude/settings.local.json. Signing in
    /// to Artlist happens once in Claude Code (`claude` in this folder, then /mcp).
    private func connectArtlist() {
        let fm = FileManager.default
        let mcp = workspace.appendingPathComponent(".mcp.json")
        var config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: mcp))) as? [String: Any] ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        if servers["artlist"] == nil {
            servers["artlist"] = ["type": "http", "url": "https://mcp.artlist.io/mcp"]
            config["mcpServers"] = servers
            if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: mcp)
            }
        }
        let settings = workspace.appendingPathComponent(".claude/settings.local.json")
        try? fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        var local = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
        var enabled = local["enabledMcpjsonServers"] as? [String] ?? []
        if !enabled.contains("artlist") {
            enabled.append("artlist")
            local["enabledMcpjsonServers"] = enabled
            if let data = try? JSONSerialization.data(withJSONObject: local, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: settings)
            }
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

    /// Conversation mode listens to the run as it goes (steps, Mochi's lines, the answer).
    var eventObserver: ((ClaudeCLI.Event) -> Void)?

    /// `voice`: the owner spoke (Conversation mode) — Claude answers with a spoken line first.
    func send(_ prompt: String, voice: Bool = false) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        ensureWorkspace()
        if !videos.isEmpty { writeChannelFile() }
        messages.append(StudioMessage(role: .user, text: text))
        running = true
        let model = UserDefaults.standard.string(forKey: ClaudeCLI.modelKey)
        run = ClaudeCLI.run(
            // Spoken requests carry a reminder: in a long session Claude keeps its deck-only habit.
            prompt: voice ? text + "\n\n(Voice mode: begin your answer with the ```say block. If you ask to spend credits, end it with the ```approval block.)" : text,
            cwd: workspace,
            sessionId: sessionId,
            systemPrompt: voice ? Self.chatSystemPrompt + Self.voicePrompt : Self.chatSystemPrompt,
            allowedTools: studioTools,
            permissionMode: "acceptEdits",
            model: model,
            // The skill's voice script reads it (Hélène, through the key saved in Coucou → Claude).
            extraEnv: InworldVoice.shared.apiKey.map { ["INWORLD_API_KEY": $0] } ?? [:]
        ) { [weak self] event in
            self?.handle(event)
        }
        if run == nil { running = false }
    }

    private func handle(_ event: ClaudeCLI.Event) {
        eventObserver?(event)
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

    /// What Claude may use in the studio: the files, the web, the skills, the video and render
    /// tools, the Shorts engine's Python and ffmpeg (editing and re-rendering episodes).
    private var studioTools: [String] {
        let bin = VideoTool.install(in: workspace).path
        return ["WebSearch", "WebFetch", "Read", "Write", "Edit", "Glob", "Grep", "Skill",
                "Bash(\(bin)/coucou-video:*)", "Bash(.coucou/bin/coucou-video:*)",
                "Bash(\(bin)/coucou-render:*)", "Bash(.coucou/bin/coucou-render:*)",
                "Bash(\(VideoTool.python):*)", "Bash(ffmpeg:*)", "Bash(ffprobe:*)",
                // Artlist (generation always waits for the owner's OK on the price) and its downloads.
                "mcp__artlist", "Bash(curl:*)"]
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

    MAKING AND EDITING VIDEOS. Episodes live in episodes/<name>/ (episodes/ep02 is « Qu'est-ce qui fait \
    ta valeur ? », the published Short). Follow the inspiration-shorts skill (its SKILL.md and \
    references/) for the pipeline, the style and how the owner likes to work. On this Mac: \
    - Python is ~/CoucouStudio/.venv-shorts/bin/python (use it wherever the skill says `python`); ffmpeg \
      and ffprobe are installed. INWORLD_API_KEY is set for the voice script. \
    - Check a layout fast: `.coucou/bin/coucou-render episodes/<name> --stills 2 15 35` (seconds; it \
      writes build/stills.jpg — Read it). \
    - Render: `.coucou/bin/coucou-render episodes/<name>` (or --start/--end for a preview, --audio-only \
      for a re-mix). It runs in the background; Coucou shows progress and then the video in the chat. \
      Don't wait or poll: say it's rendering and stop. \
    - When the owner says « do it again », « adjust it » or « apply your suggestions »: edit the episode \
      files (render_v2.py SEGMENTS/SFX, mg/overlay.html, voiceover.txt…), keep a copy of what you change \
      (e.g. render_v2.py.bak-<date>), check with --stills, then render to a new file in renders/ — never \
      overwrite the published video. \
    - Spending Artlist credits or regenerating the voice changes cost: state it and wait for a clear yes. \
      To ask, check the balance (get_balance) and each cost (get_generation_cost) first, then end your \
      answer with a fenced `approval` block — the app shows it as a card with buttons, and spends \
      nothing itself: {"title":"Nouvelle ouverture","items":[{"label":"Le héros face à la mer, de nuit", \
      "kind":"Image","credits":90}],"total":420,"balance":282,"renews":"27 octobre (7 500)", \
      "options":["Seulement les 2 images (180)","Réutiliser les images de l’épisode 2"]}. "options" are \
      cheaper alternatives (at most 3, each at most 28 characters: they are buttons); the card always adds "Oui, vas-y" (unless the balance is too \
      low) and "Non". An item may show a picture from this folder with "image". Wait for the answer.

    PICTURES IN SLIDES. A slide may show pictures from this folder (paths relative to it): \
    "image": "videos/<id>/frames/f03.jpg" on a points/quote/image slide, or \
    {"kind":"compare","title":"…","images":["a.jpg","b.jpg"],"labels":["Avant","Après"]}. Use real \
    frames when you talk about a moment of a video, and episode assets or build/stills.jpg for edits. \
    A video can be shown in a reply with a fenced `video` block: {"path":"episodes/ep02/renders/x.mp4","title":"…"}.

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

    /// Conversation mode: the owner talks and listens; Mochi, the app's character, says the answer.
    private static let voicePrompt = """

    VOICE MODE — the owner is TALKING to you and LISTENING: Coucou's character (Mochi) says your words \
    out loud with a voice. ALWAYS start your final answer with a fenced code block whose language is \
    `say` — also when the answer is a deck: what you say out loud, 1 to 3 short natural sentences in \
    the owner's language that give the gist, no markdown, no lists, round numbers. Then, only if \
    useful, the deck (with narration) or other blocks. Before work \
    that takes more than a few seconds, first write one short line (at most 12 words) saying what you \
    are about to do — it is spoken too. Never read file paths or code aloud. When you need the \
    owner's OK to spend credits, the ```approval block is required (not a table): Mochi shows it as \
    a card with buttons, so the say block only states the gist and asks the question.
    """

    func stop() { run?.cancel() }

    /// A message from Coucou itself in the chat (a finished render).
    func post(_ text: String, error: Bool = false) {
        messages.append(StudioMessage(role: error ? .error : .assistant, text: text))
        saveConversation()
        if !error { StudioConversation.shared.posted(text) }
    }

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
