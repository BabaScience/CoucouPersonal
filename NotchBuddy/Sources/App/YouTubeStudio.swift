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
            systemPrompt: "You are working inside the YouTube studio folder described in CLAUDE.md. Read channel.md for the latest numbers when the question is about the channel.",
            allowedTools: ["WebSearch", "WebFetch", "Read", "Write", "Edit", "Glob", "Grep", "Skill"],
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

// MARK: - Page

/// One-click starting points. `send: false` puts the text in the field to finish it first.
private struct StudioAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let prompt: String
    var send = true
}

private let studioActions: [StudioAction] = [
    StudioAction(title: "Understand my channel", symbol: "sparkle.magnifyingglass", prompt: """
        Analyse my channel. Read channel.md, look at my channel page and a few of my recent videos on the web. \
        Tell me: who my audience is, my content pillars, which videos perform best and why (hooks, topics, length, format), \
        and the 5 most impactful things I should change. Then update the "Channel profile" and "What performs" sections of CLAUDE.md.
        """),
    StudioAction(title: "Market research", symbol: "chart.line.uptrend.xyaxis", prompt: """
        Do market research for my niche (French inspirational / motivational Shorts). Use web search. \
        Find the leading channels in this niche, the formats and hooks that work right now, current trends and topics, \
        and gaps I could fill. Save the report to research/ with today's date and give me the key takeaways.
        """),
    StudioAction(title: "Video ideas", symbol: "lightbulb", prompt: """
        Give me 10 video ideas for my channel, based on what performs on my channel and in the niche. \
        For each: a working title in French, the hook (first 2 seconds), and why it should work. Save them in ideas/.
        """),
    StudioAction(title: "Write a script", symbol: "doc.text", prompt: "Write a Short script (45–60 s, in French) about: ", send: false),
    StudioAction(title: "Title, description, tags", symbol: "textformat", prompt: "Write 5 title options, a description and hashtags for this video: ", send: false),
]

struct HubYouTubePage: View {
    @ObservedObject private var studio = YouTubeStudio.shared
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubHero(page: .youtube, title: "YouTube",
                    subtitle: "Scripts, research and ideas for \(studio.channelTitle), with your Claude plan.",
                    compact: true)
                .padding(.horizontal, 28)
                .padding(.top, 24)
            HStack(alignment: .top, spacing: 16) {
                channelColumn.frame(width: 300)
                chatColumn
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .task { if studio.videos.isEmpty { await studio.refresh() } }
    }

    // MARK: Channel

    private var channelColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HubCard(padding: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(studio.channelTitle).font(.system(size: 15, weight: .bold))
                            Text(studio.subscribers.map { "\($0) subscribers" } ?? "@\(studio.handle)")
                                .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                        }
                        Spacer()
                        if studio.refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            HubIconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await studio.refresh() } }
                        }
                    }
                    if let err = studio.refreshError {
                        Text(err).font(.system(size: 11.5)).foregroundColor(HubTheme.red)
                    }
                    HStack(spacing: 8) {
                        Button("Open channel") { NSWorkspace.shared.open(studio.channelURL) }
                            .buttonStyle(HubButtonStyle())
                        Button("Studio folder") { studio.openWorkspace() }
                            .buttonStyle(HubButtonStyle())
                    }
                }
                HubLabel("Latest uploads")
                ForEach(studio.videos) { v in
                    Button { if let u = URL(string: v.url) { NSWorkspace.shared.open(u) } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(v.title).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text("\(v.views.formatted()) views · \(v.published.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 11)).foregroundColor(HubTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(HubTheme.card))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.never)
    }

    // MARK: Chat

    private var chatColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if studio.messages.isEmpty { emptyState }
                        ForEach(studio.messages) { m in
                            StudioMessageRow(message: m).id(m.id)
                        }
                        if studio.running {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Claude is working…").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                            }
                            .id("working")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubTheme.card))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
                .onChange(of: studio.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(studio.running ? AnyHashable("working") : AnyHashable(studio.messages.last?.id), anchor: .bottom) }
                }
            }
            HubWrap(spacing: 6) {
                ForEach(studioActions) { a in
                    Button {
                        if a.send { studio.send(a.prompt) } else { draft = a.prompt; fieldFocused = true }
                    } label: {
                        Label(a.title, systemImage: a.symbol).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .disabled(studio.running)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask anything about your channel, a script, the market…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($fieldFocused)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HubTheme.field))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                    .onSubmit(send)
                if studio.running {
                    Button("Stop") { studio.stop() }.buttonStyle(HubButtonStyle())
                } else {
                    Button("Send", action: send).buttonStyle(HubButtonStyle(primary: true))
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HubIconButton(symbol: "square.and.pencil", help: "New conversation") { studio.newConversation() }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start with “Understand my channel”").font(.system(size: 14, weight: .semibold))
            Text("Claude reads your latest uploads, studies the channel and remembers what it learns in the studio folder. Then ask for research, ideas or scripts — everything it writes is saved there too.")
                .font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        studio.send(text)
    }
}

/// A message: the user's on the right, Claude's in Markdown, tool steps as small grey lines.
struct StudioMessageRow: View {
    let message: StudioMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(HubTheme.accent.opacity(0.22)))
            }
        case .assistant:
            HStack(alignment: .top) {
                ChatMarkdownView(markdown: message.text)
                Spacer(minLength: 0)
                HubIconButton(symbol: "doc.on.doc", help: "Copy") { NSPasteboard.copyText(message.text) }
            }
        case .activity:
            Label(message.text, systemImage: "gearshape.2")
                .font(.system(size: 11.5))
                .foregroundColor(HubTheme.muted)
                .lineLimit(1)
        case .error:
            Text(message.text)
                .font(.system(size: 12.5))
                .foregroundColor(HubTheme.red)
                .textSelection(.enabled)
        }
    }
}
#endif
