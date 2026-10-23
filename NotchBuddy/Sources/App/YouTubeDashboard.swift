#if !APPSTORE
import AppKit
import Charts
import SwiftUI

/// YouTube's colours for the studio: its red, and a few companions for the charts.
enum StudioPalette {
    static let red = Color(hex: "#FF3B30")
    static let series: [Color] = ["#FF3B30", "#FF9F0A", "#FFD60A", "#30D158", "#64D2FF", "#BF5AF2", "#FF6482", "#AC8E68"]
        .map { Color(hex: $0) }
    static func color(_ i: Int) -> Color { series[i % series.count] }
}

// MARK: - Page

struct HubYouTubePage: View {
    @ObservedObject private var studio = YouTubeStudio.shared
    @ObservedObject private var auth = YouTubeAuth.shared
    @State private var tab = "overview"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Group {
                if tab == "overview" {
                    YouTubeOverview()
                } else {
                    StudioChat()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            if studio.videos.isEmpty { await studio.refresh() }
            if auth.signedIn && studio.analytics == nil { await studio.refreshAPI() }
        }
        .onChange(of: auth.signedIn) { _, on in if on { Task { await studio.refreshAPI() } } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AsyncImage(url: studio.apiChannel?.thumbnail) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(StudioPalette.red.opacity(0.85))
                    .overlay(Image(systemName: "play.fill").font(.system(size: 13)).foregroundColor(.white))
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(studio.channelTitle).font(.system(size: 16, weight: .semibold))
                Text(studio.subscribers.map { "\($0) subscribers" } ?? "@\(studio.handle)")
                    .font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
            }
            Spacer()
            Picker("", selection: $tab) {
                Text("Overview").tag("overview")
                Text("Studio").tag("studio")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            if tab == "overview" && auth.signedIn {
                Picker("", selection: $studio.periodDays) {
                    Text("7 d").tag(7)
                    Text("28 d").tag(28)
                    Text("90 d").tag(90)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
            if auth.signedIn {
                HubIconButton(symbol: "person.crop.circle.badge.questionmark", help: "Switch channel") {
                    auth.signOut()
                    auth.signIn()
                }
            }
            if studio.loadingAPI || studio.refreshing {
                ProgressView().controlSize(.small).frame(width: 28)
            } else {
                HubIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    Task { await studio.refresh(); await studio.refreshAPI() }
                }
            }
        }
    }
}

// MARK: - Overview

private struct YouTubeOverview: View {
    @ObservedObject private var studio = YouTubeStudio.shared
    @ObservedObject private var auth = YouTubeAuth.shared
    /// 0 → 1 when data arrives: bars grow, lines rise, numbers count up.
    @State private var progress: Double = 0
    @State private var sort = "recent"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !auth.signedIn {
                    YouTubeConnectCard()
                    publicUploads
                } else if let other = studio.wrongChannel {
                    glass {
                        Label("Google connected “\(other)”, not \(studio.channelTitle).", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(StudioPalette.color(1))
                        Text("Your account manages several channels. Switch channel, and on Google's page choose \(studio.channelTitle).")
                            .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                        Button("Switch channel") { auth.signOut(); auth.signIn() }
                            .buttonStyle(HubButtonStyle(primary: true))
                    }
                } else if let error = studio.apiError {
                    glass { Label(error, systemImage: "exclamationmark.triangle").foregroundColor(HubTheme.red).font(.system(size: 12.5)) }
                }
                if let a = studio.analytics {
                    kpis(a)
                    viewsChart(a)
                    HStack(alignment: .top, spacing: 14) {
                        topVideos(a)
                        donut("Where views come from", a.traffic)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        bars("Top countries", a.countries, unit: "views")
                        bars("Audience", a.ageGender, unit: "%")
                    }
                } else if auth.signedIn && studio.loadingAPI {
                    glass { HStack { ProgressView().controlSize(.small); Text("Loading your channel…").foregroundColor(HubTheme.secondary) } }
                }
                if !studio.videoStats.isEmpty { uploads }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.never)
        .onAppear { animateIn() }
        .onChange(of: studio.analytics) { _, _ in animateIn() }
    }

    private func animateIn() {
        progress = 0
        withAnimation(.spring(response: 1.1, dampingFraction: 0.85).delay(0.1)) { progress = 1 }
    }

    // KPI tiles

    private func kpis(_ a: YTAnalytics) -> some View {
        let spark = a.daily.map { Double($0.views) }
        return HStack(spacing: 12) {
            KPITile(title: "Views", value: Double(a.views), format: .compact, spark: spark, color: StudioPalette.red)
            KPITile(title: "Watch time", value: Double(a.minutes) / 60, format: .hours,
                    spark: a.daily.map { Double($0.minutes) }, color: StudioPalette.color(1))
            KPITile(title: "Subscribers", value: Double(a.netSubscribers), format: .signed,
                    spark: a.daily.map { Double($0.subscribersGained - $0.subscribersLost) }, color: StudioPalette.color(3))
            KPITile(title: "Avg. view", value: a.averageViewDuration, format: .seconds,
                    spark: [], color: StudioPalette.color(4),
                    footnote: "\(Int(a.averageViewPercentage.rounded())) % watched")
            if let r = a.revenue {
                KPITile(title: "Revenue", value: r, format: .money, spark: [], color: StudioPalette.color(2))
            }
        }
    }

    // Daily views

    private func viewsChart(_ a: YTAnalytics) -> some View {
        glass {
            HStack {
                Text("Views per day").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("last \(a.days) days").font(.system(size: 11)).foregroundColor(HubTheme.muted)
            }
            Chart(a.daily) { d in
                AreaMark(x: .value("Day", d.date), y: .value("Views", Double(d.views) * progress))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [StudioPalette.red.opacity(0.45), StudioPalette.red.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Day", d.date), y: .value("Views", Double(d.views) * progress))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(StudioPalette.red)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
            .chartYScale(domain: 0...Double(max(1, a.daily.map(\.views).max() ?? 1)) * 1.1)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Color.white.opacity(0.06)); AxisValueLabel() } }
            .frame(height: 190)
        }
    }

    // Top videos

    private func topVideos(_ a: YTAnalytics) -> some View {
        let titles = studio.videoTitles
        let rows = a.topVideos.prefix(6).map { (title: short(titles[$0.id] ?? $0.id), views: $0.views, pct: $0.averageViewPercentage) }
        return glass {
            Text("Top videos").font(.system(size: 13, weight: .semibold))
            if rows.isEmpty { empty } else {
                Chart(Array(rows.enumerated()), id: \.offset) { i, r in
                    BarMark(x: .value("Views", Double(r.views) * progress), y: .value("Video", r.title), height: .fixed(12))
                        .foregroundStyle(StudioPalette.color(i).gradient)
                        .cornerRadius(5)
                        .annotation(position: .trailing) {
                            Text(r.views.formatted(.number.notation(.compactName)))
                                .font(.system(size: 10.5, weight: .medium)).foregroundColor(HubTheme.secondary)
                                .opacity(progress)
                        }
                }
                .chartXAxis(.hidden)
                .chartXScale(domain: 0...Double(max(1, rows.map(\.views).max() ?? 1)) * 1.25)
                .frame(height: CGFloat(rows.count) * 38 + 10)
            }
        }
    }

    // Donut and bars

    private func donut(_ title: String, _ slices: [YTSlice]) -> some View {
        let top = Array(slices.prefix(6))
        let total = max(1, top.reduce(0) { $0 + $1.value })
        return glass {
            Text(title).font(.system(size: 13, weight: .semibold))
            if top.isEmpty { empty } else {
                HStack(spacing: 14) {
                    Chart(Array(top.enumerated()), id: \.offset) { i, s in
                        SectorMark(angle: .value("Views", s.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(StudioPalette.color(i))
                            .cornerRadius(4)
                    }
                    .frame(width: 130, height: 130)
                    .rotationEffect(.degrees(-90 * (1 - progress)))
                    .scaleEffect(0.7 + 0.3 * progress)
                    .opacity(progress)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(top.enumerated()), id: \.offset) { i, s in
                            HStack(spacing: 6) {
                                Circle().fill(StudioPalette.color(i)).frame(width: 7, height: 7)
                                Text(s.label).font(.system(size: 11.5)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(Int((s.value / total * 100).rounded())) %")
                                    .font(.system(size: 11, weight: .medium)).foregroundColor(HubTheme.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func bars(_ title: String, _ slices: [YTSlice], unit: String) -> some View {
        let top = Array(slices.sorted { $0.value > $1.value }.prefix(8))
        return glass {
            Text(title).font(.system(size: 13, weight: .semibold))
            if top.isEmpty { empty } else {
                Chart(Array(top.enumerated()), id: \.offset) { i, s in
                    BarMark(x: .value(unit, s.value * progress), y: .value("Label", s.label), height: .fixed(11))
                        .foregroundStyle(StudioPalette.color(i + 3).gradient)
                        .cornerRadius(4)
                        .annotation(position: .trailing) {
                            Text(unit == "%" ? String(format: "%.0f %%", s.value) : s.value.formatted(.number.notation(.compactName)))
                                .font(.system(size: 10.5)).foregroundColor(HubTheme.secondary).opacity(progress)
                        }
                }
                .chartXAxis(.hidden)
                .chartXScale(domain: 0...(top.map(\.value).max() ?? 1) * 1.3)
                .frame(height: CGFloat(top.count) * 34 + 10)
            }
        }
    }

    // Uploads

    private var uploads: some View {
        let list: [YTVideoStat] = {
            switch sort {
            case "views": return studio.videoStats.sorted { $0.views > $1.views }
            case "engagement": return studio.videoStats.sorted { $0.engagement > $1.engagement }
            default: return studio.videoStats
            }
        }()
        let maxViews = Double(max(1, studio.videoStats.map(\.views).max() ?? 1))
        return glass {
            HStack {
                Text("Uploads").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $sort) {
                    Text("Newest").tag("recent")
                    Text("Most viewed").tag("views")
                    Text("Engagement").tag("engagement")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            LazyVStack(spacing: 6) {
                ForEach(list.prefix(40)) { v in
                    Button { NSWorkspace.shared.open(v.url) } label: {
                        HStack(spacing: 10) {
                            AsyncImage(url: v.thumbnail) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.05) }
                                .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                GeometryReader { g in
                                    Capsule().fill(StudioPalette.red.opacity(0.75))
                                        .frame(width: max(3, g.size.width * Double(v.views) / maxViews * progress), height: 4)
                                }
                                .frame(height: 4)
                                Text("\(v.published.formatted(date: .abbreviated, time: .omitted)) · \(v.isShort ? "Short" : "\(v.seconds / 60) min")")
                                    .font(.system(size: 10.5)).foregroundColor(HubTheme.muted)
                            }
                            Spacer(minLength: 8)
                            stat(v.views.formatted(.number.notation(.compactName)), "eye")
                            stat(v.likes.formatted(.number.notation(.compactName)), "hand.thumbsup")
                            stat(v.comments.formatted(), "bubble.left")
                            stat(String(format: "%.1f%%", v.engagement), "sparkles")
                        }
                        .padding(6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var publicUploads: some View {
        glass {
            Text("Latest uploads (public feed)").font(.system(size: 13, weight: .semibold))
            ForEach(studio.videos.prefix(8)) { v in
                Button { if let u = URL(string: v.url) { NSWorkspace.shared.open(u) } } label: {
                    HStack {
                        Text(v.title).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Text("\(v.views.formatted()) views").font(.system(size: 11)).foregroundColor(HubTheme.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func stat(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(HubTheme.secondary)
            .frame(width: 66, alignment: .trailing)
    }

    private var empty: some View {
        Text("No data for this period yet.").font(.system(size: 11.5)).foregroundColor(HubTheme.muted)
    }

    private func short(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "#shortsfrancais", with: "").replacingOccurrences(of: "#shorts", with: "")
            .trimmingCharacters(in: .whitespaces)
        return t.count > 32 ? String(t.prefix(31)) + "…" : t
    }

    private func glass<C: View>(@ViewBuilder _ content: @escaping () -> C) -> some View {
        StudioGlassCard(content: content)
    }
}

/// A frosted card: the panel's glass, a little lighter.
struct StudioGlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

/// A number that counts up when it appears, with a small sparkline under it.
private struct KPITile: View {
    enum Format { case compact, hours, signed, seconds, money }
    let title: String
    let value: Double
    let format: Format
    let spark: [Double]
    let color: Color
    var footnote: String? = nil
    @State private var shown: Double = 0

    var body: some View {
        StudioGlassCard {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1).foregroundColor(HubTheme.muted)
            Text(text(shown))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .contentTransition(.numericText(value: shown))
                .foregroundColor(HubTheme.text)
            if spark.count > 1 {
                Chart(Array(spark.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("i", i), y: .value("v", v))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(color)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 26)
            } else if let footnote {
                Text(footnote).font(.system(size: 11)).foregroundColor(HubTheme.secondary).frame(height: 26, alignment: .top)
            } else {
                Spacer().frame(height: 26)
            }
        }
        .onAppear { animate() }
        .onChange(of: value) { _, _ in animate() }
    }

    private func animate() {
        shown = 0
        withAnimation(.easeOut(duration: 1.2)) { shown = value }
    }

    private func text(_ v: Double) -> String {
        switch format {
        case .compact: return v.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        case .hours: return "\(Int(v.rounded())) h"
        case .signed: return (v >= 0 ? "+" : "") + Int(v.rounded()).formatted()
        case .seconds: return "\(Int(v) / 60):" + String(format: "%02d", Int(v) % 60)
        case .money: return v.formatted(.number.precision(.fractionLength(2)))
        }
    }
}

// MARK: - Connect

/// Setting up the Google sign-in: a Desktop OAuth client of the user's own Cloud project.
struct YouTubeConnectCard: View {
    @ObservedObject private var auth = YouTubeAuth.shared
    @State private var clientId = ""
    @State private var clientSecret = ""

    var body: some View {
        StudioGlassCard {
            HStack(spacing: 10) {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 18)).foregroundColor(StudioPalette.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect YouTube Analytics").font(.system(size: 14, weight: .semibold))
                    Text("Watch time, retention, traffic sources, audience and every video's numbers — read-only.")
                        .font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                }
            }
            if auth.hasClient {
                HStack(spacing: 8) {
                    Button(auth.signingIn ? "Waiting for Google…" : "Sign in with Google") { auth.signIn() }
                        .buttonStyle(HubButtonStyle(primary: true))
                        .disabled(auth.signingIn)
                    if auth.signingIn {
                        Button("Cancel") { auth.cancelSignIn() }.buttonStyle(HubButtonStyle())
                    }
                    Button("Change client") { auth.resetClient() }
                        .buttonStyle(HubButtonStyle())
                }
                if auth.signingIn {
                    HStack(spacing: 8) {
                        Text("Finish in the private Chrome window that opened: sign in with the channel's account and allow access.")
                            .font(.system(size: 11)).foregroundColor(HubTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = auth.consentURL {
                            Button("Copy sign-in link") { NSPasteboard.copyText(url.absoluteString) }
                                .buttonStyle(HubButtonStyle())
                        }
                    }
                }
            } else {
                Text("One-time setup in Google Cloud (free): create a project, enable “YouTube Data API v3” and “YouTube Analytics API”, set up the OAuth consent screen (External, add yourself as a test user), then create an OAuth client ID of type “Desktop app” and paste it here.")
                    .font(.system(size: 11.5)).foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    HubField(placeholder: "Client ID (….apps.googleusercontent.com)", text: $clientId)
                    SecureField("Client secret", text: $clientSecret)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(HubTheme.field))
                        .frame(width: 220)
                    Button("Save") {
                        if auth.saveClient(id: clientId, secret: clientSecret) { clientId = ""; clientSecret = "" }
                    }
                        .buttonStyle(HubButtonStyle(primary: true))
                        .disabled(clientId.isEmpty || clientSecret.isEmpty)
                }
                Button("Open Google Cloud Console") {
                    NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
                }
                .buttonStyle(HubButtonStyle())
            }
            if let e = auth.error {
                Text(e).font(.system(size: 11.5)).foregroundColor(HubTheme.red)
            }
        }
    }
}

// MARK: - Studio chat

private struct StudioAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let prompt: String
    var send = true
}

private let studioActions: [StudioAction] = [
    StudioAction(title: "Understand my channel", symbol: "sparkle.magnifyingglass", prompt: """
        Analyse my channel. Read analytics.md (and channel.md), look at my channel page and a few of my recent videos \
        on the web. Tell me: who my audience is, my content pillars, which videos perform best and why (hooks, topics, \
        length, format, retention), and the 5 most impactful things I should change. Use charts. Then update the \
        "Channel profile" and "What performs" sections of CLAUDE.md.
        """),
    StudioAction(title: "Weekly report", symbol: "chart.bar.xaxis", prompt: """
        Give me my report for the period in analytics.md: what went up or down and why, best and worst videos, \
        where views came from, and 3 actions for next week. Use charts.
        """),
    StudioAction(title: "Market research", symbol: "chart.line.uptrend.xyaxis", prompt: """
        Do market research for my niche (French inspirational / motivational Shorts). Use web search. Find the leading \
        channels in this niche, the formats and hooks that work right now, current trends and topics, and gaps I could \
        fill. Compare them to my numbers in analytics.md with a chart. Save the report to research/ with today's date.
        """),
    StudioAction(title: "Video ideas", symbol: "lightbulb", prompt: """
        Give me 10 video ideas for my channel, based on what performs in analytics.md and in the niche. For each: a \
        working title in French, the hook (first 2 seconds), and why it should work. Save them in ideas/.
        """),
    StudioAction(title: "Write a script", symbol: "doc.text", prompt: "Write a Short script (45–60 s, in French) about: ", send: false),
    StudioAction(title: "Title, description, tags", symbol: "textformat", prompt: "Write 5 title options, a description and hashtags for this video: ", send: false),
]

private struct StudioChat: View {
    @ObservedObject private var studio = YouTubeStudio.shared
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if studio.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Your studio").font(.system(size: 15, weight: .semibold))
                                Text("Claude reads your analytics, studies the channel, writes scripts and research, and answers with charts. Everything it writes is saved in the studio folder.")
                                    .font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        ForEach(studio.messages) { m in StudioMessageRow(message: m).id(m.id) }
                        if studio.running {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Claude is working…").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                            }
                            .id("working")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
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
                            .background(Capsule().fill(Color.white.opacity(0.08)))
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
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HubTheme.field))
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
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        studio.send(text)
    }
}

// MARK: - Messages with charts

/// A message: the user's on the right, Claude's in Markdown with its chart blocks drawn, tool steps
/// as small grey lines.
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
                    .background(RoundedRectangle(cornerRadius: 14).fill(StudioPalette.red.opacity(0.28)))
            }
        case .assistant:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(StudioChartSpec.split(message.text).enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .text(let t): ChatMarkdownView(markdown: t)
                        case .chart(let spec): StudioChartView(spec: spec)
                        }
                    }
                }
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

/// A chart Claude asks for in a ```chart block.
struct StudioChartSpec: Decodable, Equatable {
    struct Point: Decodable, Equatable { let label: String; let value: Double }
    let type: String
    let title: String?
    let unit: String?
    let data: [Point]

    enum Part { case text(String), chart(StudioChartSpec) }

    /// Splits a message into Markdown and chart blocks (a broken block stays as text).
    static func split(_ text: String) -> [Part] {
        var parts: [Part] = []
        var rest = Substring(text)
        while let open = rest.range(of: "```chart") {
            let before = String(rest[..<open.lowerBound])
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "```") else { break }
            let json = String(afterOpen[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(before)) }
            if let spec = try? JSONDecoder().decode(StudioChartSpec.self, from: Data(json.utf8)), !spec.data.isEmpty {
                parts.append(.chart(spec))
            } else {
                parts.append(.text("```\n\(json)\n```"))
            }
            rest = afterOpen[close.upperBound...]
        }
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(String(rest))) }
        return parts
    }
}

struct StudioChartView: View {
    let spec: StudioChartSpec
    @State private var progress: Double = 0

    var body: some View {
        let points = Array(spec.data.prefix(12).enumerated())
        let maxV = max(1, spec.data.map(\.value).max() ?? 1)
        StudioGlassCard {
            if let title = spec.title { Text(title).font(.system(size: 12.5, weight: .semibold)) }
            switch spec.type {
            case "line":
                Chart(points, id: \.offset) { i, p in
                    AreaMark(x: .value("x", p.label), y: .value(spec.unit ?? "", p.value * progress))
                        .foregroundStyle(LinearGradient(colors: [StudioPalette.red.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("x", p.label), y: .value(spec.unit ?? "", p.value * progress))
                        .foregroundStyle(StudioPalette.red)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    PointMark(x: .value("x", p.label), y: .value(spec.unit ?? "", p.value * progress))
                        .foregroundStyle(StudioPalette.red).symbolSize(18)
                }
                .chartYScale(domain: 0...maxV * 1.1)
                .frame(height: 170)
            case "donut", "pie":
                HStack(spacing: 14) {
                    Chart(points, id: \.offset) { i, p in
                        SectorMark(angle: .value("v", p.value), innerRadius: .ratio(0.6), angularInset: 1.5)
                            .foregroundStyle(StudioPalette.color(i)).cornerRadius(4)
                    }
                    .frame(width: 120, height: 120)
                    .scaleEffect(0.7 + 0.3 * progress).opacity(progress)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(points, id: \.offset) { i, p in
                            HStack(spacing: 6) {
                                Circle().fill(StudioPalette.color(i)).frame(width: 7, height: 7)
                                Text(p.label).font(.system(size: 11.5)).lineLimit(1)
                                Text(p.value.formatted()).font(.system(size: 11)).foregroundColor(HubTheme.secondary)
                            }
                        }
                    }
                }
            default:
                Chart(points, id: \.offset) { i, p in
                    BarMark(x: .value(spec.unit ?? "", p.value * progress), y: .value("label", p.label), height: .fixed(12))
                        .foregroundStyle(StudioPalette.color(i).gradient)
                        .cornerRadius(4)
                        .annotation(position: .trailing) {
                            Text(p.value.formatted(.number.notation(.compactName)))
                                .font(.system(size: 10.5)).foregroundColor(HubTheme.secondary).opacity(progress)
                        }
                }
                .chartXAxis(.hidden)
                .chartXScale(domain: 0...maxV * 1.3)
                .frame(height: CGFloat(points.count) * 38 + 10)
            }
        }
        .onAppear { withAnimation(.spring(response: 1, dampingFraction: 0.85)) { progress = 1 } }
    }
}
#endif
