#if !APPSTORE
import AppKit
import Charts
import SwiftUI


// MARK: - Model

/// A short presentation Claude answers with in a ```deck block: one idea per slide, few words.
struct StudioDeck: Decodable, Equatable {
    let title: String?
    let slides: [Slide]

    struct Slide: Decodable, Equatable {
        let kind: String
        let title: String?
        let subtitle: String?
        let stats: [Stat]?
        let points: [String]?
        let chart: StudioChartSpec?
        let text: String?
        let caption: String?
        let icon: String?
        /// What the voice says on this slide (Claude writes it; built from the slide otherwise).
        let narration: String?
        /// A picture from the studio folder (path relative to it): a video frame, an episode image…
        let image: String?
        /// "compare": two pictures side by side, with `labels` under them.
        let images: [String]?
        let labels: [String]?

        var spokenText: String {
            if let n = narration?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            var parts = [title, subtitle, text].compactMap { $0 }
            parts += (stats ?? []).map { s in "\(s.label) : \(s.number.map { Int($0.rounded()).formatted() } ?? s.display)" }
            parts += points ?? []
            if let caption { parts.append(caption) }
            return parts.joined(separator: ". ")
        }
    }

    /// A big number. `value` may be a number (it counts up) or text ("3×", "Top 5 %").
    struct Stat: Decodable, Equatable {
        let label: String
        let number: Double?
        let display: String
        let delta: String?

        enum CodingKeys: String, CodingKey { case label, value, delta, unit }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = (try? c.decode(String.self, forKey: .label)) ?? ""
            delta = try? c.decode(String.self, forKey: .delta)
            let unit = (try? c.decode(String.self, forKey: .unit)) ?? ""
            if let d = try? c.decode(Double.self, forKey: .value) {
                number = d
                display = unit
            } else {
                number = nil
                display = ((try? c.decode(String.self, forKey: .value)) ?? "") + (unit.isEmpty ? "" : " \(unit)")
            }
        }
    }
}

// MARK: - Player

/// Plays a deck in the chat: slides glide in, numbers count up, charts grow, points appear one by
/// one. Arrows, the dots or a click move between slides; ▶ plays it on its own.
struct StudioDeckView: View {
    let deck: StudioDeck
    @ObservedObject private var voice = InworldVoice.shared
    @AppStorage("deck.voiceOn") private var voiceOn = true
    @State private var index = 0
    @State private var forward = true
    @State private var playing = false
    @State private var timer: Timer?
    /// The narrated run (▶ with the voice on), or the reading of one slide.
    @State private var narration: Task<Void, Never>?

    private var narrated: Bool { voiceOn && voice.isConfigured }

    private var count: Int { deck.slides.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((deck.title ?? "Presentation").uppercased())
                    .font(.system(size: 10.5, weight: .bold)).tracking(1.2)
                    .foregroundColor(HubTheme.muted)
                Spacer()
                Text("\(index + 1) / \(count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(HubTheme.muted)
                    .contentTransition(.numericText(value: Double(index)))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ZStack {
                StudioSlideView(slide: deck.slides[index])
                    .id(index)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, minHeight: 250, maxHeight: 250, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { go(index + 1) }

            HStack(spacing: 10) {
                controlButton("chevron.left") { go(index - 1) }.disabled(index == 0)
                HStack(spacing: 6) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(i == index ? StudioPalette.red : Color.white.opacity(0.22))
                            .frame(width: i == index ? 18 : 6, height: 6)
                            .onTapGesture { go(i) }
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: index)
                controlButton("chevron.right") { go(index + 1) }.disabled(index == count - 1)
                Spacer()
                if voice.isConfigured {
                    controlButton(voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                        voiceOn.toggle()
                        if !voiceOn { voice.stop() }
                    }
                    .help(voiceOn ? "Voice on (Inworld)" : "Voice off")
                }
                controlButton(playing ? "pause.fill" : "play.fill") { togglePlay() }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
                // A soft red glow in a corner, like a stage light.
                RadialGradient(colors: [StudioPalette.red.opacity(0.28), .clear], center: .topTrailing,
                               startRadius: 10, endRadius: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .onDisappear { stopPlay() }
    }

    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    /// `user`: a click (reads the slide when the voice is on), not the narrated run moving on.
    private func go(_ i: Int, user: Bool = true) {
        guard i >= 0, i < count, i != index else {
            if i >= count { stopPlay() }
            return
        }
        forward = i > index
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { index = i }
        if user && narrated {
            if playing { stopPlay() }
            readCurrent()
        }
    }

    private func togglePlay() {
        if playing { stopPlay(); return }
        playing = true
        if index == count - 1 { go(0, user: false) }
        if narrated {
            narration?.cancel()
            narration = Task { await narrate(from: index) }
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if index >= count - 1 { stopPlay() } else { go(index + 1, user: false) }
                }
            }
        }
    }

    /// Reads each slide, moving on when the voice finishes; the next one is prepared meanwhile.
    private func narrate(from start: Int) async {
        for i in start..<count {
            if Task.isCancelled { return }
            if i != index { go(i, user: false) }
            if i + 1 < count {
                let next = deck.slides[i + 1].spokenText
                Task { _ = try? await voice.audio(for: next) }
            }
            await voice.speak(deck.slides[i].spokenText)
            if Task.isCancelled || voice.error != nil { break }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        playing = false
    }

    private func readCurrent() {
        narration?.cancel()
        let text = deck.slides[index].spokenText
        narration = Task { await voice.speak(text) }
    }

    private func stopPlay() {
        playing = false
        timer?.invalidate()
        timer = nil
        narration?.cancel()
        narration = nil
        voice.stop()
    }
}

// MARK: - Big slides

private struct DeckLargeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Slides drawn for the full stage (Conversation's show): bigger type, poster headlines.
    var deckLarge: Bool {
        get { self[DeckLargeKey.self] }
        set { self[DeckLargeKey.self] = newValue }
    }
}

/// One slide.
struct StudioSlideView: View {
    let slide: StudioDeck.Slide
    @Environment(\.deckLarge) private var large
    @State private var shown = false

    /// The stage's poster headline (condensed, upper case), or the chat's rounded one.
    private func headline(_ text: String, chat: CGFloat, stage: CGFloat) -> Text {
        large
            ? Text(text.uppercased()).font(.system(size: stage, weight: .heavy).width(.condensed))
            : Text(text).font(.system(size: chat, weight: .bold, design: .rounded))
    }

    private func sized(_ chat: CGFloat, _ stage: CGFloat) -> CGFloat { large ? stage : chat }

    var body: some View {
        VStack(alignment: .leading, spacing: sized(14, 22)) {
            switch slide.kind {
            case "title", "cover": titleSlide
            case "stats", "stat", "numbers": statsSlide
            case "chart": chartSlide
            case "image", "picture", "screenshot": imageSlide
            case "compare", "before_after": compareSlide
            case "quote", "takeaway": quoteSlide
            default: pointsSlide
            }
        }
        .padding(.horizontal, sized(22, 36))
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { shown = true } }
    }

    // One view per kind of slide (one big switch was too much for the compiler).
    @ViewBuilder private var titleSlide: some View {
        Spacer(minLength: 0)
        if let icon = slide.icon {
            Image(systemName: icon).font(.system(size: 30, weight: .semibold)).foregroundColor(StudioPalette.red)
                .scaleEffect(shown ? 1 : 0.4).opacity(shown ? 1 : 0)
        }
        headline(slide.title ?? "", chat: 30, stage: 64)
            .fixedSize(horizontal: false, vertical: true)
            .offset(y: shown ? 0 : 18).opacity(shown ? 1 : 0)
        if let sub = slide.subtitle {
            Text(sub).font(.system(size: sized(15, 20))).foregroundColor(HubTheme.secondary)
                .offset(y: shown ? 0 : 18).opacity(shown ? 1 : 0)
                .animation(.spring(response: 0.6).delay(0.15), value: shown)
        }
        Spacer(minLength: 0)
    }

    // One view per kind of slide (one big switch was too much for the compiler).
    @ViewBuilder private var statsSlide: some View {
        heading
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array((slide.stats ?? []).prefix(4).enumerated()), id: \.offset) { i, s in
                DeckStat(stat: s, color: StudioPalette.color(i), delay: Double(i) * 0.12)
            }
        }
        if let cap = slide.caption { caption(cap) }
    }

    // One view per kind of slide (one big switch was too much for the compiler).
    @ViewBuilder private var chartSlide: some View {
        heading
        if let spec = slide.chart {
            StudioChartView(spec: StudioChartSpec(type: spec.type, title: nil, unit: spec.unit, data: spec.data), bare: true)
        }
        if let cap = slide.caption { caption(cap) }
    }

    // One view per kind of slide (one big switch was too much for the compiler).
    @ViewBuilder private var imageSlide: some View {
        heading
        if let img = slide.image ?? slide.images?.first {
            DeckImage(path: img, height: sized(170, 300))
                .frame(maxWidth: .infinity, alignment: .center)
                .scaleEffect(shown ? 1 : 0.92).opacity(shown ? 1 : 0)
        }
        if let cap = slide.caption { caption(cap) }
    }

    // One view per kind of slide (one big switch was too much for the compiler).
    @ViewBuilder private var compareSlide: some View {
        heading
        HStack(alignment: .top, spacing: 18) {
            ForEach(Array((slide.images ?? [slide.image].compactMap { $0 }).prefix(3).enumerated()), id: \.offset) { i, img in
                VStack(spacing: 6) {
                    DeckImage(path: img, height: sized(150, 270))
                    if let labels = slide.labels, i < labels.count { let label = labels[i]
                        Text(label).font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(StudioPalette.color(i).opacity(0.85)))
                            .foregroundColor(.black.opacity(0.85))
                    }
                }
                .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 16)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(i) * 0.15), value: shown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        if let cap = slide.caption { caption(cap) }
    }

    // One view per kind of slide (one big switch was too much for the compiler).
    @ViewBuilder private var quoteSlide: some View {
        Spacer(minLength: 0)
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 2).fill(StudioPalette.red)
                .frame(width: 4).frame(maxHeight: shown ? 110 : 0)
            VStack(alignment: .leading, spacing: 8) {
                Text(slide.text ?? slide.title ?? "")
                    .font(.system(size: sized(22, 36), weight: .semibold, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                if let cap = slide.caption {
                    Text(cap).font(.system(size: sized(12.5, 16))).foregroundColor(HubTheme.secondary)
                }
            }
            .opacity(shown ? 1 : 0).offset(x: shown ? 0 : 20)
        }
        Spacer(minLength: 0)
    }

    // One view per kind of slide (one big switch was too much for the compiler).
    @ViewBuilder private var pointsSlide: some View {
        heading
        HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array((slide.points ?? []).prefix(5).enumerated()), id: \.offset) { i, p in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(i + 1)")
                        .font(.system(size: sized(12, 16), weight: .bold, design: .rounded))
                        .frame(width: sized(24, 32), height: sized(24, 32))
                        .background(Circle().fill(StudioPalette.color(i).opacity(0.9)))
                        .foregroundColor(.black.opacity(0.8))
                    Text(p).font(.system(size: sized(15, 22), weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(shown ? 1 : 0)
                .offset(x: shown ? 0 : 24)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1 + Double(i) * 0.13), value: shown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let img = slide.image {
            DeckImage(path: img, height: sized(175, 300))
                .opacity(shown ? 1 : 0).offset(x: shown ? 0 : 20)
        }
        }
        if let cap = slide.caption { caption(cap) }
    }

    @ViewBuilder private var heading: some View {
        if let t = slide.title {
            headline(t, chat: 19, stage: 46)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: shown || !large ? 0 : 24).opacity(shown || !large ? 1 : 0)
        }
        if let sub = slide.subtitle {
            Text(sub).font(.system(size: sized(12.5, 17))).foregroundColor(HubTheme.secondary)
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: sized(12, 15))).foregroundColor(HubTheme.muted)
    }
}

/// A picture of the studio folder (only there: a path can't reach the rest of the Mac).
private struct DeckImage: View {
    let path: String
    let height: CGFloat

    var body: some View {
        if let image = Self.load(path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .onTapGesture { NSWorkspace.shared.open(Self.url(path)!) }
                .help("Open")
        } else {
            Label("Picture not found", systemImage: "photo")
                .font(.system(size: 11)).foregroundColor(HubTheme.muted)
                .frame(height: 40)
        }
    }

    static func url(_ path: String) -> URL? { StudioFiles.url(path) }

    static func load(_ path: String) -> NSImage? {
        guard let u = url(path) else { return nil }
        return NSImage(contentsOf: u)
    }
}

/// A number that counts up, its label, and a change shown green or red.
private struct DeckStat: View {
    let stat: StudioDeck.Stat
    let color: Color
    let delay: Double
    @Environment(\.deckLarge) private var large
    @State private var value: Double = 0
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let n = stat.number {
                    Text(format(value, like: n) + (stat.display.isEmpty ? "" : " " + stat.display))
                        .contentTransition(.numericText(value: value))
                } else {
                    Text(stat.display)
                }
            }
            .font(.system(size: large ? 58 : 32, weight: .bold, design: .rounded))
            .foregroundColor(color)
            .lineLimit(1).minimumScaleFactor(0.5)
            Text(stat.label).font(.system(size: large ? 16 : 12.5, weight: .medium)).foregroundColor(HubTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let d = stat.delta {
                Text(d)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(d.hasPrefix("-") || d.hasPrefix("−") ? HubTheme.red : HubTheme.green)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(large ? 18 : 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
        .scaleEffect(shown ? 1 : 0.85).opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75).delay(delay)) { shown = true }
            if let n = stat.number {
                withAnimation(.easeOut(duration: 1.3).delay(delay)) { value = n }
            }
        }
    }

    private func format(_ v: Double, like target: Double) -> String {
        if abs(target) >= 10_000 { return v.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
        if target.rounded() == target { return Int(v.rounded()).formatted() }
        return v.formatted(.number.precision(.fractionLength(1)))
    }
}
#endif
