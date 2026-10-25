#if !APPSTORE
import AppKit
import AVFoundation
import SwiftUI

// MARK: - Approval

/// What Claude asks before spending Artlist credits, in an ```approval block. The app only shows
/// it: a click (or a spoken answer) goes back to Claude as the owner's answer.
struct StudioApproval: Decodable, Equatable {
    struct Item: Decodable, Equatable {
        let label: String
        let kind: String?
        let credits: Double?
        let image: String?

        enum CodingKeys: String, CodingKey { case label, kind, credits, image }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = (try? c.decode(String.self, forKey: .label)) ?? ""
            kind = try? c.decode(String.self, forKey: .kind)
            credits = try? c.decode(Double.self, forKey: .credits)
            image = try? c.decode(String.self, forKey: .image)
        }
    }

    let title: String?
    let items: [Item]
    let total: Double?
    let balance: Double?
    let renews: String?
    let options: [String]?

    var cost: Double { total ?? items.compactMap(\.credits).reduce(0, +) }
    var tooLow: Bool { balance.map { cost > $0 } ?? false }
}

/// The approval as a card: what would be made, what it costs, what is left, and the answers.
struct StudioApprovalCard: View {
    let ask: StudioApproval
    var large = false
    /// Where an answer goes: the chat by default, Conversation passes its own.
    var answer: (String) -> Void = { YouTubeStudio.shared.send($0) }
    @State private var answered: String?
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 16 : 12) {
            if !large, let title = ask.title {
                Label(title, systemImage: "creditcard").font(.system(size: 13, weight: .bold))
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(ask.items.prefix(4).enumerated()), id: \.offset) { i, item in
                    itemTile(item)
                        .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 14)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(i) * 0.1), value: shown)
                }
            }
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
            HStack {
                Text("Total").font(.system(size: large ? 15 : 13, weight: .bold))
                Spacer()
                Text("\(Self.credits(ask.cost)) crédits")
                    .font(.system(size: large ? 22 : 17, weight: .heavy, design: .rounded))
                    .foregroundColor(Color(hex: "#FCD34D"))
            }
            if let balance = ask.balance { balanceBar(balance) }
            answers
        }
        .padding(large ? 22 : 16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .onAppear { shown = true }
    }

    private func itemTile(_ item: StudioApproval.Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                if let path = item.image, let url = StudioFiles.url(path), let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    Text(item.label)
                        .font(.system(size: 12))
                        .foregroundColor(HubTheme.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: large ? 116 : 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            Text([item.kind, item.credits.map { "\(Self.credits($0)) crédits" }].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(HubTheme.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func balanceBar(_ balance: Double) -> some View {
        let after = balance - ask.cost
        let color = ask.tooLow ? Color(hex: "#FF453A") : HubTheme.green
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(color)
                        .frame(width: shown ? g.size.width * min(1, ask.cost / max(balance, 1)) : 0)
                        .animation(.spring(response: 1.2, dampingFraction: 0.9).delay(0.3), value: shown)
                }
            }
            .frame(height: 8)
            Text(ask.tooLow
                 ? "Il te reste \(Self.credits(balance)) crédits — pas assez." + (ask.renews.map { " Renouvellement : \($0)." } ?? "")
                 : "Il te restera \(Self.credits(after)) crédits sur \(Self.credits(balance)).")
                .font(.system(size: 12.5))
                .foregroundColor(ask.tooLow ? Color(hex: "#FCA5A5") : HubTheme.secondary)
        }
    }

    private var answers: some View {
        HStack(spacing: 8) {
            if !ask.tooLow {
                answerButton("Oui, vas-y", send: "Oui, vas-y : tu peux dépenser les \(Self.credits(ask.cost)) crédits.", primary: true)
            }
            ForEach(Array((ask.options ?? []).prefix(3).enumerated()), id: \.offset) { i, option in
                answerButton(option, send: option, primary: ask.tooLow && i == 0)
            }
            answerButton("Non", send: "Non, ne dépense rien.", primary: false)
        }
        .disabled(answered != nil)
    }

    private func answerButton(_ label: String, send: String, primary: Bool) -> some View {
        Button {
            answered = send
            answer(send)
        } label: {
            HStack(spacing: 5) {
                if answered == send { Image(systemName: "checkmark") }
                Text(label).lineLimit(1)
            }
            .font(.system(size: large ? 13.5 : 12.5, weight: primary ? .bold : .semibold))
            .padding(.horizontal, large ? 16 : 12).padding(.vertical, large ? 11 : 8)
            .foregroundColor(primary ? HubTheme.onAccent : HubTheme.text)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(primary ? HubTheme.accent : Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(primary ? 0 : 0.14)))
            .opacity(answered == nil || answered == send ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }

    static func credits(_ v: Double) -> String { Int(v.rounded()).formatted() }
}

// MARK: - Mochi's bubble

/// What Mochi says, in a white speech bubble.
struct MochiBubble: View {
    let text: String
    var size: CGFloat = 16

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold))
            .foregroundColor(Color(hex: "#15161A"))
            .lineLimit(5)
            .padding(.horizontal, 18).padding(.vertical, 13)
            .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 4,
                                               bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous)
                .fill(Color.white))
    }
}

// MARK: - Result stage

/// The video Mochi made: a phone playing it, Mochi happy beside it, and what to do next.
struct ConversationResult: View {
    let clip: StudioConversation.Clip
    @ObservedObject private var talk = StudioConversation.shared
    @State private var player: AVPlayer?
    @State private var details = ""

    private let follow = ["Baisse la musique", "Encore plus court"]

    var body: some View {
        HStack(alignment: .center, spacing: 36) {
            phone
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 12) {
                    ConversationMochi(phase: .done, talking: talk.talking)
                        .scaleEffect(0.55)
                        .frame(width: 110, height: 96)
                    if !talk.line.isEmpty { MochiBubble(text: talk.line) }
                }
                info
                VStack(alignment: .leading, spacing: 10) {
                    Text("Dis-moi la suite, ou :").font(.system(size: 13)).foregroundColor(HubTheme.secondary)
                    HStack(spacing: 8) {
                        chip("Garder cette version", primary: true) { talk.ask("Je garde cette version.") }
                        chip("Ouvrir dans le Finder") {
                            if let url = StudioFiles.url(clip.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(follow, id: \.self) { f in chip("« \(f) »") { talk.ask(f) } }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 34)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .task(id: clip.path) { await load() }
        .onDisappear { player?.pause() }
    }

    private var phone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.black)
            if player != nil {
                StudioPlayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(6)
            } else {
                Label("Vidéo introuvable", systemImage: "film").font(.system(size: 12)).foregroundColor(HubTheme.muted)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color(hex: "#2A2C33"), lineWidth: 5))
        .frame(width: 228, height: 406)
        .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(clip.title ?? (clip.path as NSString).lastPathComponent, systemImage: "film")
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
            if !details.isEmpty {
                Text(details).font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
    }

    private func chip(_ label: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).lineLimit(1)
                .font(.system(size: 12.5, weight: primary ? .bold : .semibold))
                .padding(.horizontal, 13).padding(.vertical, 9)
                .foregroundColor(primary ? HubTheme.onAccent : HubTheme.text)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(primary ? HubTheme.accent : Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(primary ? 0 : 0.14)))
        }
        .buttonStyle(.plain)
    }

    /// The player, and "52 s · 154 Mo" under the title.
    private func load() async {
        guard let url = StudioFiles.url(clip.path), FileManager.default.fileExists(atPath: url.path) else {
            player = nil
            return
        }
        player = AVPlayer(url: url)
        var bits: [String] = []
        if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite {
            bits.append("\(Int(seconds.rounded())) s")
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
            bits.append(ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file))
        }
        details = bits.joined(separator: " · ")
    }
}

// MARK: - Approval stage

/// Mochi asks before spending: the card in the middle, an answer by voice or with a click.
struct ConversationApproval: View {
    let ask: StudioApproval
    @ObservedObject private var talk = StudioConversation.shared

    var body: some View {
        VStack(spacing: 24) {
            HStack(alignment: .center, spacing: 18) {
                ConversationMochi(phase: .asking, talking: talk.talking)
                    .scaleEffect(0.62)
                    .frame(width: 128, height: 104)
                MochiBubble(text: talk.line.isEmpty ? (ask.title ?? "J’ai besoin de ton accord.") : talk.line, size: 17)
                    .frame(maxWidth: 440, alignment: .leading)
            }
            StudioApprovalCard(ask: ask, large: true) { talk.ask($0) }
                .frame(maxWidth: 640)
            Text("Réponds à voix haute — « oui », « non », « seulement les images » — je ne dépense rien sans ton accord.")
                .font(.system(size: 12.5))
                .foregroundColor(HubTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}
#endif
