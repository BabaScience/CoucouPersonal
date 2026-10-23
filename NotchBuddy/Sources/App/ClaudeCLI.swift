#if !APPSTORE
import Foundation

/// Runs Claude through the Claude Code CLI (`claude -p`), so every request is billed to the
/// user's Claude subscription instead of an API key.
///
/// Sign-in: the CLI's own login, or a long-lived token made with `claude setup-token` and saved
/// in Settings (Keychain → `CLAUDE_CODE_OAUTH_TOKEN`). `ANTHROPIC_API_KEY` is always removed from
/// the environment so a key set elsewhere can never take over the billing.
@MainActor
enum ClaudeCLI {
    static let tokenKey = "claude_oauth_token"
    static let modelKey = "claudeCLI.model"
    static let screenModelKey = "claudeCLI.screenModel"

    /// What a run reports, in order.
    enum Event {
        case session(String)
        case text(String)
        case tool(name: String, summary: String)
        case done(result: String, sessionId: String?, isError: Bool)
    }

    /// A run in progress; `cancel()` stops it.
    final class Run {
        fileprivate let process = Process()
        fileprivate var cancelled = false
        var isRunning: Bool { process.isRunning }
        func cancel() {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Finding the CLI

    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var token: String? {
        let t = KeychainStore.shared.get(tokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    static func saveToken(_ value: String) {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { KeychainStore.shared.remove(tokenKey) } else { KeychainStore.shared.set(tokenKey, value: t) }
    }

    // MARK: - Running

    /// Starts `claude -p` in `cwd` with `prompt` on stdin. `sessionId` resumes a conversation.
    /// Returns nil when the CLI is not installed (an `.done` error event is sent first).
    @discardableResult
    static func run(prompt: String,
                    cwd: URL,
                    sessionId: String? = nil,
                    systemPrompt: String? = nil,
                    allowedTools: [String] = [],
                    permissionMode: String = "default",
                    model: String? = nil,
                    extraPath: [String] = [],
                    extraEnv: [String: String] = [:],
                    onEvent: @escaping @MainActor (Event) -> Void) -> Run? {
        guard let exe = executable() else {
            onEvent(.done(result: "Claude Code is not installed. Install it with:\ncurl -fsSL https://claude.ai/install.sh | bash",
                          sessionId: nil, isError: true))
            return nil
        }
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let run = Run()
        let p = run.process
        p.executableURL = exe
        p.currentDirectoryURL = cwd
        // User settings hold Coucou's own hooks: leaving them out keeps these runs out of the notch.
        var args = ["-p", "--output-format", "stream-json", "--verbose",
                    "--setting-sources", "project,local",
                    "--permission-mode", permissionMode]
        if let sessionId { args += ["--resume", sessionId] }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let systemPrompt { args += ["--append-system-prompt", systemPrompt] }
        if !allowedTools.isEmpty { args += ["--allowedTools", allowedTools.joined(separator: ",")] }
        p.arguments = args

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        env.removeValue(forKey: "CLAUDECODE")   // set when Coucou was started from a Claude Code shell
        if let token { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let basePath = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (extraPath + basePath + [env["PATH"] ?? ""]).joined(separator: ":")
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        let parser = StreamParser()
        let errBuffer = LockedData()
        stdout.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            let events = parser.feed(chunk)
            guard !events.isEmpty else { return }
            Task { @MainActor in events.forEach(onEvent) }
        }
        stderr.fileHandleForReading.readabilityHandler = { h in errBuffer.append(h.availableData) }
        p.terminationHandler = { proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let rest = stdout.fileHandleForReading.readDataToEndOfFile()
            var events = parser.feed(rest)
            let status = proc.terminationStatus
            let errText = String(data: errBuffer.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                if !parser.sawResult {
                    let message = run.cancelled ? "Stopped."
                        : (errText.isEmpty ? "Claude stopped (exit \(status))." : errText)
                    events.append(.done(result: message, sessionId: parser.sessionId, isError: !run.cancelled))
                }
                events.forEach(onEvent)
            }
        }

        do {
            try p.run()
        } catch {
            onEvent(.done(result: "Could not start Claude Code: \(error.localizedDescription)", sessionId: nil, isError: true))
            return nil
        }
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()
        return run
    }

    /// Whether the error looks like a sign-in problem, to point the user at `claude setup-token`.
    static func isAuthError(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("login") || t.contains("log in") || t.contains("oauth") || t.contains("authenticat")
            || t.contains("invalid api key") || t.contains("401")
    }
}

// MARK: - stream-json parsing

/// Splits the CLI's stream-json output into lines and turns each line into events.
private final class StreamParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var sessionId: String?
    private(set) var sawResult = false

    func feed(_ data: Data) -> [ClaudeCLI.Event] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var events: [ClaudeCLI.Event] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            events += parse(obj)
        }
        return events
    }

    private func parse(_ obj: [String: Any]) -> [ClaudeCLI.Event] {
        switch obj["type"] as? String {
        case "system":
            if let id = obj["session_id"] as? String, sessionId == nil {
                sessionId = id
                return [.session(id)]
            }
        case "assistant":
            let message = obj["message"] as? [String: Any]
            // The CLI repeats errors as a "<synthetic>" message; the result event carries them.
            if message?["model"] as? String == "<synthetic>" { return [] }
            let content = (message?["content"] as? [[String: Any]]) ?? []
            return content.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : .text(text)
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    return .tool(name: name, summary: Self.summary(name, block["input"] as? [String: Any] ?? [:]))
                default:
                    return nil
                }
            }
        case "result":
            sawResult = true
            let id = obj["session_id"] as? String ?? sessionId
            let isError = (obj["is_error"] as? Bool) ?? false
            var text = obj["result"] as? String ?? ""
            if text.isEmpty, isError { text = (obj["subtype"] as? String) ?? "Error" }
            return [.done(result: text, sessionId: id, isError: isError)]
        default:
            break
        }
        return []
    }

    /// One short line about a tool call: "Searching the web: …", "Reading channel.md".
    static func summary(_ name: String, _ input: [String: Any]) -> String {
        func s(_ k: String) -> String { (input[k] as? String) ?? "" }
        func file(_ k: String) -> String { (s(k) as NSString).lastPathComponent }
        switch name {
        case "WebSearch": return "Searching the web: \(s("query"))"
        case "WebFetch":  return "Reading \(URL(string: s("url"))?.host ?? s("url"))"
        case "Read":      return "Reading \(file("file_path"))"
        case "Write":     return "Writing \(file("file_path"))"
        case "Edit":      return "Editing \(file("file_path"))"
        case "Glob", "Grep": return "Looking through files"
        case "Skill":     return "Using skill \(s("skill"))"
        case "Bash":      return s("command")
        default:          return name
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
}
#endif
