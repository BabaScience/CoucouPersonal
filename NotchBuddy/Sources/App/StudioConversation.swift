#if !APPSTORE
import AppKit
import AVFoundation
import SwiftUI

/// Conversation mode of the YouTube studio: the owner talks (push-to-talk, Coucou's own speech
/// recognition), Claude works with the studio's tools, and Mochi shows each step and says the
/// answer out loud (Inworld, or the Mac's voice without a key). Same session as the chat.
@MainActor
final class StudioConversation: ObservableObject {
    static let shared = StudioConversation()

    enum Phase { case ready, listening, working, done, failed }

    struct Step: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var done = false
    }

    @Published private(set) var phase: Phase = .ready
    /// What the owner said last (shown under Mochi while it works).
    @Published private(set) var said = ""
    /// Mochi's speech bubble.
    @Published private(set) var line = ""
    @Published private(set) var steps: [Step] = []
    @Published private(set) var deck: StudioDeck?
    /// Mochi's mouth moves while a line is spoken.
    @Published private(set) var talking = false
    /// Listening hands-free (a tap) rather than while the key or button is held.
    @Published private(set) var handsFree = false

    // The show: the answer's deck on the whole stage, Mochi presenting it slide by slide.
    @Published private(set) var showing = false
    @Published private(set) var slide = 0
    /// The line said on the current slide (the subtitles).
    @Published private(set) var subtitle = ""
    @Published private(set) var paused = false

    /// The live words while listening (an @Observable, read straight by the stage).
    let dictation = MacDictation()

    private var queue: [String] = []
    private var speaker: Task<Void, Never>?
    private var finalHandled = false
    private let fallback = MacVoice()
    private var show: Task<Void, Never>?

    // MARK: Listening

    func startListening(handsFree: Bool = false) {
        guard phase != .listening else { return }
        guard !YouTubeStudio.shared.running else {
            say("Je finis d’abord ce que je fais, et je t’écoute.")
            return
        }
        stopSpeaking()
        closeShow()
        self.handsFree = handsFree
        phase = .listening
        Task {
            await dictation.start(from: "")
            if !dictation.isRecording {
                phase = .failed
                line = "Je n’ai pas accès au micro. Autorise Coucou Personal dans Réglages Système → Confidentialité → Micro et Reconnaissance vocale."
            }
        }
    }

    /// Lets go: what was heard goes to Claude.
    func stopListening() {
        guard phase == .listening else { return }
        handsFree = false
        Task {
            let text = await dictation.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                phase = .ready
                return
            }
            ask(text)
        }
    }

    func cancelListening() {
        guard phase == .listening else { return }
        dictation.stop()
        handsFree = false
        phase = .ready
    }

    /// A request, spoken or picked from the suggestions.
    func ask(_ text: String) {
        guard !YouTubeStudio.shared.running else { return }
        closeShow()
        said = text
        steps = []
        deck = nil
        line = ""
        finalHandled = false
        phase = .working
        let studio = YouTubeStudio.shared
        studio.eventObserver = { [weak self] event in self?.handle(event) }
        studio.send(text, voice: true)
    }

    func stopWork() {
        YouTubeStudio.shared.stop()
        stopSpeaking()
    }

    // MARK: Claude's run

    private func handle(_ event: ClaudeCLI.Event) {
        switch event {
        case .session:
            break
        case .tool(_, let summary):
            for i in steps.indices { steps[i].done = true }
            steps.append(Step(text: Self.friendly(summary)))
            if steps.count > 6 { steps.removeFirst(steps.count - 6) }
        case .text(let t):
            guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            if t.contains("```") || t.count > 220 {
                handleFinal(t)
            } else {
                line = t
                say(t)
            }
        case .done(let result, _, let isError):
            for i in steps.indices { steps[i].done = true }
            YouTubeStudio.shared.eventObserver = nil
            if isError {
                phase = .failed
                line = String(result.prefix(220))
                return
            }
            if !finalHandled { handleFinal(result) }
            phase = .done
            if let deck, deck.slides.count > 1 { startShow() }
        }
    }

    /// The answer: the spoken line, and the deck if there is one.
    private func handleFinal(_ text: String) {
        finalHandled = true
        var spoken: String?
        for part in StudioChartSpec.split(text) {
            switch part {
            case .say(let s): spoken = s
            case .deck(let d): deck = d
            default: break
            }
        }
        if spoken == nil {
            // No say block: the deck's opening narration, or the first sentences of the text.
            if let first = deck?.slides.lazy.compactMap(\.narration).first(where: { !$0.isEmpty }) {
                spoken = first
            } else {
                let sentences = Self.plain(text).split(separator: ".", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                spoken = sentences.isEmpty ? nil : sentences.prefix(2).joined(separator: ". ") + "."
            }
        }
        if let spoken, !spoken.isEmpty {
            line = spoken
            say(spoken)
        }
    }

    // MARK: Speaking

    func say(_ text: String) {
        let clean = Self.plain(text)
        guard !clean.isEmpty else { return }
        queue.append(clean)
        guard speaker == nil else { return }
        speaker = Task {
            while !queue.isEmpty {
                let next = queue.removeFirst()
                talking = true
                if InworldVoice.shared.isConfigured {
                    await InworldVoice.shared.speak(next)
                } else {
                    await fallback.speak(next)
                }
                talking = false
                if Task.isCancelled { break }
            }
            speaker = nil
        }
    }

    func stopSpeaking() {
        queue.removeAll()
        speaker?.cancel()
        speaker = nil
        InworldVoice.shared.stop()
        fallback.stop()
        talking = false
    }

    // MARK: Show

    /// Plays the deck on the whole stage once Mochi has said its line: each slide's narration is
    /// spoken with subtitles, and the next one is prepared meanwhile.
    func startShow(from start: Int = 0) {
        guard let deck, !deck.slides.isEmpty else { return }
        show?.cancel()
        paused = false
        slide = min(max(0, start), deck.slides.count - 1)
        // While Mochi finishes its opening line, that line is the subtitle.
        subtitle = speaker != nil ? line : deck.slides[slide].spokenText
        showing = true
        show = Task {
            while speaker != nil { try? await Task.sleep(nanoseconds: 150_000_000) }
            for i in slide..<deck.slides.count {
                if Task.isCancelled { return }
                slide = i
                subtitle = deck.slides[i].spokenText
                if i + 1 < deck.slides.count, InworldVoice.shared.isConfigured {
                    let next = deck.slides[i + 1].spokenText
                    Task { _ = try? await InworldVoice.shared.audio(for: next) }
                }
                talking = true
                await voiceSay(subtitle)
                talking = false
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { closeShow() }
        }
    }

    func showGo(_ i: Int) {
        guard let deck, i >= 0, i < deck.slides.count else { return }
        show?.cancel()
        queue.removeAll()
        voiceStop()
        startShow(from: i)
    }

    func togglePause() {
        paused.toggle()
        if InworldVoice.shared.isConfigured {
            paused ? InworldVoice.shared.pause() : InworldVoice.shared.resume()
        } else {
            paused ? fallback.pause() : fallback.resume()
        }
        talking = !paused && show != nil
    }

    func closeShow() {
        guard showing || show != nil else { return }
        show?.cancel()
        show = nil
        voiceStop()
        talking = false
        paused = false
        showing = false
    }

    /// How far the current line has been said (0…1), for the subtitles.
    var speechProgress: Double {
        InworldVoice.shared.isConfigured ? InworldVoice.shared.playbackProgress : fallback.progress
    }

    private func voiceSay(_ text: String) async {
        if InworldVoice.shared.isConfigured {
            await InworldVoice.shared.speak(text)
        } else {
            await fallback.speak(text)
        }
    }

    private func voiceStop() {
        InworldVoice.shared.stop()
        fallback.stop()
    }

    // MARK: Text

    /// Markdown, code and links out: what a voice can say.
    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_#`>|]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A step as the owner reads it: "Je regarde la vidéo", not a command line.
    static func friendly(_ summary: String) -> String {
        if summary.contains("coucou-video") { return "Je regarde la vidéo" }
        if summary.contains("coucou-render") { return summary.contains("--stills") ? "Je vérifie les images" : "Je lance le rendu" }
        if summary.contains("venv-shorts") { return "Je prépare l’épisode" }
        if summary.hasPrefix("mcp__artlist") || summary.lowercased().contains("artlist") { return "Je demande à Artlist" }
        if summary.hasPrefix("Reading analytics") { return "Je lis tes statistiques" }
        if summary.hasPrefix("Searching the web: ") { return "Je cherche : " + summary.dropFirst("Searching the web: ".count) }
        if summary.hasPrefix("Reading ") { return "Je lis " + summary.dropFirst("Reading ".count) }
        if summary.hasPrefix("Writing ") || summary.hasPrefix("Editing ") { return "J’écris " + summary.split(separator: " ").dropFirst().joined(separator: " ") }
        return summary.count > 60 ? String(summary.prefix(57)) + "…" : summary
    }
}

/// The Mac's own French voice, when no Inworld key is saved.
@MainActor
private final class MacVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?
    private var length = 1
    /// The part of the line said so far (0…1).
    private(set) var progress: Double = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        length = max(1, (text as NSString).length)
        progress = 0
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        await withCheckedContinuation { c in
            finished = c
            synth.speak(u)
        }
    }

    func pause() { synth.pauseSpeaking(at: .word) }
    func resume() { synth.continueSpeaking() }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        finished?.resume()
        finished = nil
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange,
                                       utterance u: AVSpeechUtterance) {
        let end = range.location + range.length
        Task { @MainActor in self.progress = min(1, Double(end) / Double(self.length)) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }
}

// MARK: - Stage

/// The Conversation stage: Mochi in the middle, its line, the steps, the answer, a talk button.
struct ConversationStage: View {
    @ObservedObject private var talk = StudioConversation.shared
    @ObservedObject private var studio = YouTubeStudio.shared
    @State private var keyMonitor: Any?
    @State private var pressStart: Date?

    private let suggestions = ["Fais-moi le point de la semaine", "Regarde mon dernier Short", "Donne-moi 3 idées de vidéos"]

    var body: some View {
        ZStack {
            if talk.showing, let deck = talk.deck {
                StudioShow(deck: deck)
                    .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 2)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            } else {
                stage.transition(.opacity)
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.88), value: talk.showing)
        // Nothing here may push the glass window's minimum size (it follows the content's).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onAppear(perform: installKeys)
        .onDisappear(perform: removeKeys)
    }

    private var stage: some View {
        VStack(spacing: 0) {
            HStack {
                Text(statusTitle).font(.system(size: 12, weight: .heavy)).tracking(1.1).foregroundColor(statusColor)
                Spacer()
                if talk.phase == .working {
                    Button("Arrêter") { talk.stopWork() }.buttonStyle(HubButtonStyle())
                }
            }
            .padding(.horizontal, 22).padding(.top, 6)

            HStack(alignment: .center, spacing: 28) {
                VStack(spacing: 18) {
                    if !bubble.isEmpty {
                        Text(bubble)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(hex: "#15161A"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white))
                            .lineLimit(6)
                            .frame(maxWidth: 380)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    ConversationMochi(phase: talk.phase, talking: talk.talking)
                        .frame(width: 260, height: 210)
                    if talk.phase == .listening {
                        Text(talk.dictation.transcript.isEmpty ? "Je t’écoute…" : talk.dictation.transcript)
                            .font(.system(size: 22, weight: .bold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                            .foregroundColor(talk.dictation.transcript.isEmpty ? HubTheme.muted : HubTheme.text)
                    } else if !talk.said.isEmpty && talk.phase != .ready {
                        Text("« \(talk.said) »")
                            .font(.system(size: 13.5, weight: .medium)).italic()
                            .foregroundColor(HubTheme.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                            .lineLimit(3)
                    } else if talk.phase == .ready {
                        VStack(spacing: 4) {
                            Text("Je t’écoute quand tu veux.").font(.system(size: 22, weight: .heavy))
                            Text("\(studio.channelTitle) · \(studio.subscribers ?? "") abonnés")
                                .font(.system(size: 12.5)).foregroundColor(HubTheme.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                if showsSide {
                    // A fixed box: the deck's natural height would otherwise grow the window.
                    sidePanel
                        .frame(width: 410, height: 440, alignment: .top)
                        .clipped()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 22)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: showsSide)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: bubble)

            controls.padding(.bottom, 18)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    // MARK: Pieces

    private var bubble: String {
        switch talk.phase {
        case .listening: return ""
        case .working where talk.line.isEmpty: return "Je m’y mets…"
        default: return talk.line
        }
    }

    private var showsSide: Bool {
        (talk.phase == .working && !talk.steps.isEmpty) || talk.deck != nil
    }

    @ViewBuilder private var sidePanel: some View {
        if let deck = talk.deck, talk.phase != .working {
            StudioDeckView(deck: deck)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("CE QUE JE FAIS").font(.system(size: 11, weight: .heavy)).tracking(1.1).foregroundColor(HubTheme.muted)
                ForEach(Array(talk.steps.enumerated()), id: \.element.id) { i, step in
                    HStack(spacing: 10) {
                        if step.done {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(HubTheme.green)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(step.text).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(step.done ? HubTheme.green.opacity(0.10) : Color(hex: "#A78BFA").opacity(0.14)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                StudioRenderBar()
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: talk.steps)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if talk.phase == .ready || talk.phase == .done || talk.phase == .failed {
                HStack(spacing: 8) {
                    if talk.phase == .done, let deck = talk.deck, deck.slides.count > 1 {
                        Button { talk.startShow() } label: {
                            Label("Revoir la présentation", systemImage: "play.rectangle.fill")
                                .font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(HubTheme.accent))
                                .foregroundColor(HubTheme.onAccent)
                        }
                        .buttonStyle(.plain)
                    }
                    // With the replay button there, two suggestions keep the row on one line.
                    ForEach(suggestions.prefix(talk.phase == .done && talk.deck != nil ? 2 : 3), id: \.self) { s in
                        Button { talk.ask(s) } label: {
                            Text("« \(s) »").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(Color.white.opacity(0.07)))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 14) {
                talkButton
                VStack(alignment: .leading, spacing: 2) {
                    Text(hintTitle).font(.system(size: 13.5, weight: .bold))
                    Text(hintDetail).font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                }
            }
        }
    }

    /// Hold to talk; a quick tap listens hands-free until the next tap.
    private var talkButton: some View {
        let listening = talk.phase == .listening
        return ZStack {
            Circle().fill(listening ? Color(hex: "#FF453A") : HubTheme.accent)
                .shadow(color: (listening ? Color(hex: "#FF453A") : HubTheme.accent).opacity(0.45), radius: 14, y: 6)
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(listening ? .white : HubTheme.onAccent)
        }
        .frame(width: 70, height: 70)
        .opacity(talk.phase == .working ? 0.45 : 1)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressStart == nil else { return }
                    pressStart = Date()
                    if talk.phase == .listening && talk.handsFree { return }
                    talk.startListening()
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(pressStart ?? Date())
                    pressStart = nil
                    if talk.phase == .listening && talk.handsFree {
                        talk.stopListening()
                    } else if held < 0.35 {
                        talk.startListening(handsFree: true)   // a tap: keep listening until the next tap
                    } else {
                        talk.stopListening()
                    }
                }
        )
        .accessibilityLabel(listening ? "Envoyer" : "Parler")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Words

    private var statusTitle: String {
        switch talk.phase {
        case .ready: return "PRÊT"
        case .listening: return "J’ÉCOUTE"
        case .working: return "JE TRAVAILLE"
        case .done: return talk.talking ? "JE TE RÉPONDS" : "C’EST PRÊT"
        case .failed: return "OUPS"
        }
    }

    private var statusColor: Color {
        switch talk.phase {
        case .listening: return Color(hex: "#FFB4AE")
        case .working: return Color(hex: "#C4B5FD")
        case .done: return Color(hex: "#6EE7B7")
        case .failed: return Color(hex: "#FCA5A5")
        case .ready: return HubTheme.muted
        }
    }

    private var hintTitle: String {
        switch talk.phase {
        case .listening: return talk.handsFree ? "Touche pour envoyer" : "Relâche pour envoyer"
        case .working: return "Je travaille…"
        default: return "Maintiens pour parler"
        }
    }

    private var hintDetail: String {
        switch talk.phase {
        case .listening: return "Échap pour annuler"
        case .working: return "Je te réponds dès que c’est prêt"
        default: return "ou ⌥ Espace · une touche courte pour parler sans tenir"
        }
    }

    // MARK: Keys

    /// ⌥ Space held = talk; Escape cancels. Only while this window is in front.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            MainActor.assumeIsolated { Self.handleKey(event) }
        }
    }

    private static func handleKey(_ event: NSEvent) -> NSEvent? {
        let option = event.modifierFlags.contains(.option)
        if event.keyCode == 49 && option {
            if event.type == .keyDown && !event.isARepeat {
                StudioConversation.shared.startListening()
            } else if event.type == .keyUp {
                StudioConversation.shared.stopListening()
            }
            return nil
        }
        if event.keyCode == 53 && event.type == .keyDown && StudioConversation.shared.phase == .listening {
            StudioConversation.shared.cancelListening()
            return nil
        }
        return event
    }

    private func removeKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}

// MARK: - Mochi on stage

/// Mochi, drawn for the stage: breathes and blinks when ready, leans in with wide eyes and rings
/// when listening, thinks in lavender while working, talks, and smiles when done.
struct ConversationMochi: View {
    let phase: StudioConversation.Phase
    let talking: Bool
    @Environment(\.hubVisible) private var visible

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !visible)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                if phase == .listening {
                    ForEach(0..<3, id: \.self) { i in
                        let p = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(HubTheme.accent.opacity(0.75 * (1 - p)), lineWidth: 2)
                            .frame(width: 190, height: 190)
                            .scaleEffect(0.7 + 1.1 * p)
                    }
                } else if phase == .ready || phase == .done {
                    Circle()
                        .fill(RadialGradient(colors: [glow.opacity(0.28 + 0.08 * sin(t * 1.6)), .clear],
                                             center: .center, startRadius: 0, endRadius: 150))
                        .frame(width: 300, height: 300)
                }
                figure(t)
                    .offset(y: bob(t))
                    .rotationEffect(.degrees(phase == .listening ? 3 * sin(t * 2.8) : 0))
            }
        }
    }

    private var glow: Color { phase == .done ? HubTheme.green : HubTheme.accent }

    private var bodyColors: [Color] {
        switch phase {
        case .working: return [Color(hex: "#ECE6FF"), Color(hex: "#B9A9F5")]
        case .done: return [Color(hex: "#ECFFF6"), Color(hex: "#A7F3D0")]
        case .failed: return [Color(hex: "#FFE9E7"), Color(hex: "#FCA5A5")]
        default: return [.white, Color(hex: "#D4D6DC")]
        }
    }

    private func bob(_ t: Double) -> CGFloat {
        switch phase {
        case .working: return CGFloat(-7 * abs(sin(t * 2.4)))
        case .listening: return CGFloat(-3 * sin(t * 3))
        default: return CGFloat(-5 * sin(t * 1.6))
        }
    }

    private func figure(_ t: Double) -> some View {
        let blink = phase == .ready && (t.truncatingRemainder(dividingBy: 5) > 4.82)
        return ZStack {
            RoundedRectangle(cornerRadius: 58, style: .continuous)
                .fill(LinearGradient(colors: bodyColors, startPoint: .top, endPoint: .bottom))
                .frame(width: 176, height: 128)
                .shadow(color: .black.opacity(0.5), radius: 26, y: 18)
            VStack(spacing: 10) {
                HStack(spacing: 36) { eye(blink: blink, t: t); eye(blink: blink, t: t) }
                if talking {
                    Capsule().fill(Color(hex: "#1A1412"))
                        .frame(width: 22, height: CGFloat(6 + 8 * abs(sin(t * 11))))
                } else if phase == .done {
                    Arc().stroke(Color(hex: "#1A1412"), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 24, height: 10)
                }
            }
            .offset(y: talking || phase == .done ? 4 : 0)
        }
    }

    @ViewBuilder private func eye(blink: Bool, t: Double) -> some View {
        switch phase {
        case .done:
            Arc().stroke(Color(hex: "#1A1412"), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 18, height: 9).rotationEffect(.degrees(180))
        case .listening:
            ZStack(alignment: .topTrailing) {
                Capsule().fill(Color(hex: "#1A1412")).frame(width: 26, height: 40)
                Circle().fill(.white).frame(width: 8, height: 8).offset(x: -5, y: 6)
            }
        case .working:
            ZStack(alignment: .top) {
                Capsule().fill(Color(hex: "#1A1412")).frame(width: 22, height: 30)
                Circle().fill(.white).frame(width: 7, height: 7)
                    .offset(x: CGFloat(4 * sin(t * 1.3)), y: 4)
            }
        default:
            Capsule().fill(Color(hex: "#1A1412"))
                .frame(width: 18, height: blink ? 4 : 36)
        }
    }
}

/// The lower half of a circle: Mochi's smile (and happy closed eyes, flipped).
private struct Arc: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: r.midX, y: r.minY), radius: r.width / 2,
                 startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        return p
    }
}
#endif
