#if !APPSTORE
import AVFoundation
import CryptoKit
import Foundation

/// Spoken narration with Inworld's text-to-speech (https://docs.inworld.ai): the deck reads its
/// slides aloud. The API key comes from the Inworld Portal (already Base64: it goes in the
/// `Authorization: Basic` header as is) and is entered in Coucou → Claude, kept in the Keychain.
@MainActor
final class InworldVoice: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = InworldVoice()

    static let keyName = "inworld_api_key"
    static let voiceKey = "inworld.voiceId"
    static let modelKey = "inworld.modelId"
    static let languageKey = "inworld.language"
    static let rateKey = "inworld.speakingRate"
    static let models: [(id: String, label: String)] = [("inworld-tts-2", "TTS-2 (best)"), ("inworld-tts-2-flash", "TTS-2 Flash (fast, cheaper)")]

    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let gender: String
        let language: String
        let description: String
    }

    @Published private(set) var voices: [Voice] = []
    @Published private(set) var loadingVoices = false
    @Published private(set) var speaking = false
    @Published var error: String?

    private var player: AVAudioPlayer?
    private var finished: CheckedContinuation<Void, Never>?

    var apiKey: String? {
        let k = KeychainStore.shared.get(Self.keyName)?.components(separatedBy: .whitespacesAndNewlines).joined()
        return (k?.isEmpty ?? true) ? nil : k
    }
    var isConfigured: Bool { apiKey != nil }

    var voiceId: String { UserDefaults.standard.string(forKey: Self.voiceKey) ?? "" }
    var modelId: String { UserDefaults.standard.string(forKey: Self.modelKey) ?? Self.models[0].id }
    /// BCP-47 ("fr-FR"), or empty to let Inworld detect it.
    var language: String { UserDefaults.standard.string(forKey: Self.languageKey) ?? "fr-FR" }
    var speakingRate: Double {
        let r = UserDefaults.standard.double(forKey: Self.rateKey)
        return r == 0 ? 1.0 : r
    }

    func saveKey(_ value: String) {
        let k = value.components(separatedBy: .whitespacesAndNewlines).joined()
        if k.isEmpty { KeychainStore.shared.remove(Self.keyName) } else { KeychainStore.shared.set(Self.keyName, value: k) }
        voices = []
        objectWillChange.send()
    }

    // MARK: Voices

    /// The workspace's voices for the chosen language (all languages when none is set).
    func loadVoices() async {
        guard let key = apiKey, !loadingVoices else { return }
        loadingVoices = true
        defer { loadingVoices = false }
        var c = URLComponents(string: "https://api.inworld.ai/voices/v1/voices")!
        var items = [URLQueryItem(name: "pageSize", value: "500")]
        if let lang = language.split(separator: "-").first, !language.isEmpty {
            items.append(URLQueryItem(name: "filter", value: "lang_code=\"\(lang)\""))
        }
        c.queryItems = items
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.setValue("Basic \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Self.apiError(json, response) }
            voices = (json["voices"] as? [[String: Any]] ?? []).compactMap { v in
                guard let id = v["voiceId"] as? String else { return nil }
                return Voice(id: id, name: v["displayName"] as? String ?? id, gender: v["gender"] as? String ?? "",
                             language: v["languageCode"] as? String ?? "", description: v["description"] as? String ?? "")
            }
            error = nil
            if voiceId.isEmpty || !voices.contains(where: { $0.id == voiceId }), let first = voices.first {
                UserDefaults.standard.set(first.id, forKey: Self.voiceKey)
                objectWillChange.send()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Speech

    /// The audio file for `text`, from the cache or synthesized once (replays cost nothing).
    func audio(for text: String) async throws -> URL {
        guard let key = apiKey else { throw YouTubeAPIError.message("Add your Inworld API key in Coucou → Claude.") }
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1900))
        let id = "\(modelId)|\(voiceId)|\(language)|\(speakingRate)|\(clean)"
        let name = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        let file = Self.cacheDir.appendingPathComponent("\(name).mp3")
        if FileManager.default.fileExists(atPath: file.path) { return file }

        var body: [String: Any] = [
            "text": clean,
            "modelId": modelId,
            "audioConfig": ["audioEncoding": "MP3", "speakingRate": speakingRate],
        ]
        if !voiceId.isEmpty { body["voiceId"] = voiceId }
        if !language.isEmpty { body["language"] = language }
        var req = URLRequest(url: URL(string: "https://api.inworld.ai/tts/v1/voice")!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Basic \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let b64 = json["audioContent"] as? String, let audio = Data(base64Encoded: b64) else {
            throw Self.apiError(json, response)
        }
        try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        try audio.write(to: file)
        return file
    }

    /// Speaks `text` and returns when it has finished (or was stopped).
    func speak(_ text: String) async {
        stop()
        do {
            let url = try await audio(for: text)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            player = p
            speaking = true
            error = nil
            p.play()
            await withCheckedContinuation { finished = $0 }
        } catch {
            self.error = error.localizedDescription
        }
        speaking = false
    }

    /// How far the current line has been played (0…1), for subtitles that follow the voice.
    var playbackProgress: Double {
        guard let p = player, p.duration > 0 else { return 0 }
        return min(1, p.currentTime / p.duration)
    }

    func pause() { player?.pause() }
    func resume() { player?.play() }

    func stop() {
        player?.stop()
        player = nil
        speaking = false
        finished?.resume()
        finished = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.speaking = false
            self.finished?.resume()
            self.finished = nil
        }
    }

    private static var cacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CoucouStudio/.voice-cache", isDirectory: true)
    }

    private static func apiError(_ json: [String: Any], _ response: URLResponse) -> Error {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let msg = (json["message"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
        if code == 401 || code == 403 {
            return YouTubeAPIError.message("Inworld refused the key (\(msg)). Copy the Base64 key from the Inworld Portal → API Keys.")
        }
        return YouTubeAPIError.message("Inworld: \(msg)")
    }
}
#endif

#if !APPSTORE
import SwiftUI

/// Coucou → Claude → Voice: the Inworld key (Keychain), the model, the voice, the language, a test.
struct InworldVoiceCard: View {
    @ObservedObject private var voice = InworldVoice.shared
    @State private var keyDraft = ""
    @AppStorage(InworldVoice.voiceKey) private var voiceId = ""
    @AppStorage(InworldVoice.modelKey) private var modelId = InworldVoice.models[0].id
    @AppStorage(InworldVoice.languageKey) private var language = "fr-FR"
    @AppStorage(InworldVoice.rateKey) private var rate = 1.0

    private let languages: [(String, String)] = [("fr-FR", "French"), ("en-US", "English"), ("", "Auto-detect")]

    var body: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Inworld API key").font(.system(size: 13.5, weight: .medium))
                Text(voice.isConfigured
                     ? "A key is saved in your Keychain. Paste a new one to replace it."
                     : "Narrates the slide decks in the YouTube studio. In the Inworld Portal, open API Keys, create a key and copy its Base64 value here.")
                    .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    SecureField("Base64 API key", text: $keyDraft)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(HubTheme.field))
                    Button("Save") {
                        voice.saveKey(keyDraft)
                        keyDraft = ""
                        Task { await voice.loadVoices() }
                    }
                    .buttonStyle(HubButtonStyle(primary: true))
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if voice.isConfigured {
                        Button("Remove") { voice.saveKey("") }.buttonStyle(HubButtonStyle())
                    }
                    Button("Open Inworld Portal") { NSWorkspace.shared.open(URL(string: "https://platform.inworld.ai")!) }
                        .buttonStyle(HubButtonStyle())
                }
            }
            if voice.isConfigured {
                HubDivider()
                HubRow(title: "Model") {
                    Picker("", selection: $modelId) {
                        ForEach(InworldVoice.models, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 220)
                }
                HubDivider()
                HubRow(title: "Language", detail: "The voices offered follow it.") {
                    Picker("", selection: $language) {
                        ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().frame(width: 160)
                    .onChange(of: language) { _, _ in Task { await voice.loadVoices() } }
                }
                HubDivider()
                HubRow(title: "Voice") {
                    HStack(spacing: 8) {
                        if voice.loadingVoices { ProgressView().controlSize(.small) }
                        Picker("", selection: $voiceId) {
                            if voice.voices.isEmpty { Text(voiceId.isEmpty ? "—" : voiceId).tag(voiceId) }
                            ForEach(voice.voices) { v in
                                Text("\(v.name)\(v.gender.isEmpty ? "" : " · \(v.gender)")").tag(v.id)
                            }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                }
                HubDivider()
                HubRow(title: "Speed") {
                    HStack(spacing: 8) {
                        Slider(value: $rate, in: 0.8...1.3, step: 0.05).frame(width: 160)
                        Text(String(format: "%.2f×", rate)).font(.system(size: 12, design: .monospaced))
                            .foregroundColor(HubTheme.secondary)
                    }
                }
                HubDivider()
                HStack(spacing: 10) {
                    Button(voice.speaking ? "Stop" : "Test voice") {
                        if voice.speaking { voice.stop() } else {
                            Task { await voice.speak(language.hasPrefix("fr")
                                ? "Bonjour ! Je suis la voix de tes présentations. On regarde ta chaîne ensemble ?"
                                : "Hi! I'm the voice of your presentations. Shall we look at your channel together?") }
                        }
                    }
                    .buttonStyle(HubButtonStyle())
                }
            }
            if let e = voice.error {
                Text(e).font(.system(size: 12)).foregroundColor(HubTheme.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { if voice.isConfigured && voice.voices.isEmpty { await voice.loadVoices() } }
    }
}
#endif
