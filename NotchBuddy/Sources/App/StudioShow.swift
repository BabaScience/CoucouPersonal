#if !APPSTORE
import SwiftUI

/// The show: Conversation's answer deck on the whole stage. Big slides glide in, Mochi presents
/// from the corner while it talks, and subtitles light up word by word as the voice goes.
struct StudioShow: View {
    @ObservedObject private var talk = StudioConversation.shared
    let deck: StudioDeck
    @State private var forward = true

    private var count: Int { deck.slides.count }
    private var index: Int { min(talk.slide, count - 1) }

    var body: some View {
        ZStack {
            stageBackground
            VStack(spacing: 0) {
                topBar
                slideArea
                bottomBar
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onChange(of: talk.slide) { old, new in forward = new >= old }
    }

    // MARK: Pieces

    private var stageBackground: some View {
        ZStack {
            Color(hex: "#0B0C10").opacity(0.94)
            RadialGradient(colors: [StudioPalette.red.opacity(0.30), .clear], center: .topTrailing,
                           startRadius: 0, endRadius: 520)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text((deck.title ?? "Présentation").uppercased())
                .font(.system(size: 12, weight: .heavy)).tracking(1.4)
                .foregroundColor(HubTheme.secondary)
                .lineLimit(1)
            Spacer()
            Text("\(index + 1) / \(count)")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundColor(HubTheme.secondary)
                .contentTransition(.numericText(value: Double(index)))
            ShowButton(symbol: "xmark", help: "Fermer la présentation") { talk.closeShow() }
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
    }

    private var slideArea: some View {
        ZStack(alignment: .topLeading) {
            StudioSlideView(slide: deck.slides[index])
                .environment(\.deckLarge, true)
                .id(index)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
        }
        .padding(.top, 14)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .animation(.spring(response: 0.6, dampingFraction: 0.86), value: index)
        .contentShape(Rectangle())
        .onTapGesture { talk.showGo(index + 1) }
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 14) {
            ShowPresenter(talking: talk.talking)
                .frame(width: 150, height: 104)
            ShowSubtitles(text: talk.subtitle, paused: talk.paused)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(i == index ? StudioPalette.red : Color.white.opacity(0.28))
                            .frame(width: i == index ? 18 : 6, height: 6)
                            .onTapGesture { talk.showGo(i) }
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: index)
                HStack(spacing: 8) {
                    ShowButton(symbol: "chevron.left", help: "Diapo précédente") { talk.showGo(index - 1) }
                        .disabled(index == 0)
                    ShowButton(symbol: talk.paused ? "play.fill" : "pause.fill",
                               help: talk.paused ? "Reprendre" : "Pause", big: true) { talk.togglePause() }
                    ShowButton(symbol: "chevron.right", help: "Diapo suivante") { talk.showGo(index + 1) }
                        .disabled(index == count - 1)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }
}

/// Mochi in the corner of the stage, pointing at the slide while it talks.
private struct ShowPresenter: View {
    let talking: Bool
    @Environment(\.hubVisible) private var visible

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !visible)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: -4) {
                ConversationMochi(phase: .ready, talking: talking)
                    .scaleEffect(0.52)
                    .frame(width: 110, height: 100)
                Capsule()
                    .fill(LinearGradient(colors: [.white, Color(hex: "#D4D6DC")], startPoint: .top, endPoint: .bottom))
                    .frame(width: 34, height: 8)
                    .rotationEffect(.degrees(talking ? -14 + 9 * sin(t * 3.2) : -4), anchor: .leading)
                    .offset(y: -6)
            }
        }
    }
}

/// The line being said, lit word by word as the voice moves along it.
private struct ShowSubtitles: View {
    let text: String
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: paused)) { _ in
            lit(StudioConversation.shared.speechProgress)
                .font(.system(size: 16.5, weight: .medium))
                .lineSpacing(3)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        }
    }

    /// The words said so far in white, the rest dimmed — a short chunk at a time, so a long line
    /// never runs out of the box.
    private func lit(_ progress: Double) -> Text {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return Text("") }
        let said = Int((Double(words.count) * progress).rounded(.up))
        let chunks = Self.chunks(words)
        let current = chunks.first { said <= $0.upperBound } ?? chunks[chunks.count - 1]
        let lit = max(0, min(current.count, said - current.lowerBound))
        let shown = Array(words[current])
        var a = AttributedString(shown.prefix(lit).joined(separator: " "))
        a.foregroundColor = .white
        var rest = AttributedString((lit > 0 && lit < shown.count ? " " : "") + shown.dropFirst(lit).joined(separator: " "))
        rest.foregroundColor = .white.opacity(0.42)
        return Text(a + rest)
    }

    /// Pieces of about two lines: cut after a sentence or a comma when one comes near the end.
    private static func chunks(_ words: [String]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        while start < words.count {
            var end = min(words.count, start + 18)
            if end < words.count {
                if let cut = (start + 8..<end).last(where: { words[$0].last.map { ".!?;:,".contains($0) } ?? false }) {
                    end = cut + 1
                }
            }
            out.append(start..<end)
            start = end
        }
        return out
    }
}

private struct ShowButton: View {
    let symbol: String
    let help: String
    var big = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 13 : 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: big ? 38 : 30, height: big ? 38 : 30)
                .background(Circle().fill(Color.white.opacity(big ? 0.16 : 0.09)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
#endif
