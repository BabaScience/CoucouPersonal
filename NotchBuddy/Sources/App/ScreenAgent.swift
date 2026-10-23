#if !APPSTORE
import AppKit
import ApplicationServices
import SwiftUI

/// The screen assistant: ask a question, Claude looks at the screen and either guides you
/// (a pulsing pointer on the next thing to click, one step at a time) or does it for you.
///
/// Claude runs through `ClaudeCLI` (your subscription) and sees and acts only through
/// `ScreenTool` (`coucou-screen`). ⌃⌥S opens the panel from anywhere.
@MainActor
final class ScreenAgent: ObservableObject {
    static let shared = ScreenAgent()

    enum Mode: String, CaseIterable { case guide, act }

    @Published var mode: Mode = .guide
    @Published private(set) var running = false
    @Published private(set) var log: [StudioMessage] = []
    /// What Claude last said, shown big in the panel.
    @Published private(set) var status = ""
    /// Where the pointer is, in screen points from the top-left of the main display.
    @Published private(set) var pointer: (point: CGPoint, text: String)?
    @Published private(set) var capturing = false

    private var run: ClaudeCLI.Run?
    private var sessionId: String?
    private var clickMonitor: Any?
    private var hud: NSPanel?
    private var overlay: NSWindow?

    private var workspace: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("CoucouStudio/.screen", isDirectory: true)
    }
    private var toolPath: String { workspace.appendingPathComponent("bin/coucou-screen").path }

    private init() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: ScreenTool.pointNote, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            let x = info["x"] as? Double ?? 0, y = info["y"] as? Double ?? 0
            let text = info["text"] as? String ?? ""
            MainActor.assumeIsolated { ScreenAgent.shared.showPointer(CGPoint(x: x, y: y), text) }
        }
        center.addObserver(forName: ScreenTool.sayNote, object: nil, queue: .main) { note in
            let text = note.userInfo?["text"] as? String ?? ""
            MainActor.assumeIsolated { ScreenAgent.shared.status = text }
        }
        center.addObserver(forName: ScreenTool.captureNote, object: nil, queue: .main) { note in
            let begin = note.userInfo?["state"] as? String == "begin"
            MainActor.assumeIsolated { ScreenAgent.shared.setCapturing(begin) }
        }
    }

    // MARK: Permissions

    var hasAccessibility: Bool { AXIsProcessTrusted() }
    var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    // MARK: Running

    func start(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !running else { return }
        installTool()
        FlowHubController.shared.hide()
        showHUD()
        log.append(StudioMessage(role: .user, text: q))
        status = "Looking at your screen…"
        running = true
        let model = UserDefaults.standard.string(forKey: ClaudeCLI.screenModelKey) ?? "sonnet"
        var tools = ["Bash(\(toolPath):*)", "Read"]
        if mode == .act { tools.append("Bash(open:*)") }
        run = ClaudeCLI.run(
            prompt: q,
            cwd: workspace,
            sessionId: sessionId,
            systemPrompt: systemPrompt(),
            allowedTools: tools,
            model: model,
            extraEnv: ["COUCOU_SCREEN_MODE": mode == .act ? "act" : "guide"]
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
            status = t
            log.append(StudioMessage(role: .assistant, text: t))
        case .tool(_, let summary):
            let line = describe(summary)
            log.append(StudioMessage(role: .activity, text: line))
        case .done(let result, let id, let isError):
            if let id { sessionId = id }
            if isError {
                var text = result
                if ClaudeCLI.isAuthError(result) {
                    text += "\nRun `claude setup-token` in Terminal and paste the token in Coucou → Claude."
                }
                status = text
                log.append(StudioMessage(role: .error, text: text))
            } else if !result.isEmpty {
                status = result
                if log.last?.text != result { log.append(StudioMessage(role: .assistant, text: result)) }
            }
            running = false
            run = nil
            hidePointer()
        }
    }

    /// "/…/coucou-screen click 100 200" → "Clicking at 100, 200".
    private func describe(_ command: String) -> String {
        guard command.contains("coucou-screen") else { return command }
        let parts = command.components(separatedBy: "coucou-screen ").last?.split(separator: " ").map(String.init) ?? []
        switch parts.first {
        case "screenshot": return "Looking at the screen"
        case "zoom":       return "Looking closer"
        case "point":      return "Pointing"
        case "say":        return "Message"
        case "click":      return "Clicking at \(parts.dropFirst().prefix(2).joined(separator: ", "))"
        case "type":       return "Typing"
        case "key":        return "Pressing \(parts.dropFirst().first ?? "")"
        case "scroll":     return "Scrolling"
        default:           return command
        }
    }

    func stop() {
        if pointer != nil { reply(["how": "stop"]) }
        run?.cancel()
        hidePointer()
    }

    /// Guide mode: the user did the step (or wants to move on).
    func next() { reply(["how": "next"]) }

    /// Forgets the conversation: the next question starts fresh.
    func reset() {
        stop()
        sessionId = nil
        log = []
        status = ""
    }

    private func reply(_ info: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(ScreenTool.replyNote, object: nil,
                                                                     userInfo: info, deliverImmediately: true)
        hidePointer()
    }

    // MARK: Pointer

    private func showPointer(_ p: CGPoint, _ text: String) {
        pointer = (p, text)
        if !text.isEmpty { status = text }
        showOverlay()
        // The user's own click on the screen answers the pointer.
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                let loc = NSEvent.mouseLocation
                let height = NSScreen.screens.first?.frame.height ?? 0
                MainActor.assumeIsolated {
                    ScreenAgent.shared.reply(["how": "click", "x": Double(loc.x), "y": Double(height - loc.y)])
                }
            }
        }
    }

    private func hidePointer() {
        pointer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private func setCapturing(_ on: Bool) {
        capturing = on
        hud?.alphaValue = on ? 0 : 1
        overlay?.alphaValue = on ? 0 : 1
    }

    // MARK: Windows

    func toggleHUD() {
        if let hud, hud.isVisible, !running {
            hud.orderOut(nil)
            overlay?.orderOut(nil)
        } else {
            showHUD()
        }
    }

    func showHUD() {
        guard let screen = NSScreen.screens.first else { return }
        let size = NSSize(width: 580, height: 300)
        if hud == nil {
            let panel = ScreenHUDPanel(contentRect: NSRect(origin: .zero, size: size),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.sharingType = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: ScreenHUDView(agent: self))
            hud = panel
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 12))
        }
        hud?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        showOverlay()
    }

    func closeHUD() {
        stop()
        hud?.orderOut(nil)
        overlay?.orderOut(nil)
    }

    private func showOverlay() {
        guard let screen = NSScreen.screens.first else { return }
        if overlay == nil {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = .screenSaver
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.sharingType = .none
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.contentView = NSHostingView(rootView: ScreenPointerOverlay(agent: self))
            overlay = w
        }
        overlay?.setFrame(screen.frame, display: true)
        overlay?.orderFrontRegardless()
    }

    // MARK: Setup

    /// Writes the `coucou-screen` wrapper: it runs this very app in tool mode.
    private func installTool() {
        let bin = workspace.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let exe = Bundle.main.executablePath ?? ""
        let script = "#!/bin/sh\nexec \"\(exe)\" --screen-tool \"$@\"\n"
        try? script.write(toFile: toolPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolPath)
    }

    private func systemPrompt() -> String {
        let tool = toolPath
        var s = """
        You are Coucou's screen assistant on the user's Mac. You see and use the screen only through \
        this command, run with the Bash tool (always with its full path):

          \(tool) screenshot                 → saves an image of the main screen and prints its path; Read that file to see the screen
          \(tool) zoom X Y W H              → close-up of a region of the last screenshot, to read small text
          \(tool) point X Y "instruction"    → shows a pulsing pointer at X,Y with a short instruction, then waits until the user clicks or presses Next
          \(tool) say "message"              → shows a message to the user without pointing

        Coordinates are always pixels of the latest screenshot (origin top-left); the tool converts them. \
        Always take a fresh screenshot before deciding where something is; never guess positions.

        """
        switch mode {
        case .guide:
            s += """
            MODE: GUIDE ME. Teach the user to do it themselves. Never click or type for them. \
            One step at a time: screenshot → point at exactly the element to use, with a short instruction \
            (≤ 12 words, e.g. "Click Settings") → after the user acts, screenshot again to check, then the next step. \
            If something is off-screen, tell them how to get there (scroll, open an app). \
            When the task is done (or if it can't be done), reply with a short summary.
            """
        case .act:
            s += """
              \(tool) click X Y [--double|--right]
              \(tool) type "text"
              \(tool) key cmd+t        (modifiers: cmd shift opt ctrl; keys: return tab escape space delete up down left right a-z 0-9 f1-f12)
              \(tool) scroll X Y down 5
              open -a "App Name"   /   open "https://…"

            MODE: DO IT. Do the task yourself: screenshot → act → screenshot to check, until it's done. \
            Prefer keyboard shortcuts and `open` when they are reliable. \
            Never, without first asking the user with `say` and stopping: type passwords or payment details, \
            buy anything, send messages or emails, post publicly, delete files or data, or change system settings. \
            When done, reply with a short summary of what you did.
            """
        }
        s += "\nReply in the language of the user's question. Keep messages short."
        return s
    }
}

/// A panel that can take the keyboard (its text field) without stealing activation from the app below.
private final class ScreenHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Views

private struct ScreenHUDView: View {
    @ObservedObject var agent: ScreenAgent
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.rays").foregroundColor(HubTheme.accent)
                Text("Screen assistant").font(.system(size: 13, weight: .bold))
                Picker("", selection: $agent.mode) {
                    Text("Guide me").tag(ScreenAgent.Mode.guide)
                    Text("Do it").tag(ScreenAgent.Mode.act)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                .disabled(agent.running)
                Spacer()
                Button { agent.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).help("New question")
                Button { agent.closeHUD() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close")
            }
            .foregroundColor(HubTheme.text)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if agent.status.isEmpty {
                        Text(agent.mode == .guide
                             ? "Ask how to do something: I'll point at each step on your screen."
                             : "Tell me what to do: I'll do it on your screen. You can stop me anytime.")
                            .foregroundColor(HubTheme.secondary)
                    } else {
                        ChatMarkdownView(markdown: agent.status)
                    }
                    if agent.running, let last = agent.log.last(where: { $0.role == .activity }) {
                        Label(last.text, systemImage: "gearshape.2")
                            .font(.system(size: 11)).foregroundColor(HubTheme.muted).lineLimit(1)
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if agent.running {
                HStack {
                    ProgressView().controlSize(.small)
                    Spacer()
                    if agent.pointer != nil {
                        Button("Next", action: agent.next).buttonStyle(HubButtonStyle(primary: true))
                    }
                    Button("Stop", action: agent.stop).buttonStyle(HubButtonStyle())
                }
            } else {
                HStack(spacing: 8) {
                    TextField(agent.log.isEmpty ? "What do you need help with?" : "Ask a follow-up…", text: $question)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(HubTheme.field))
                        .onSubmit(go)
                    Button(agent.mode == .guide ? "Guide me" : "Do it", action: go)
                        .buttonStyle(HubButtonStyle(primary: true))
                }
            }
        }
        .padding(14)
        .frame(width: 580, height: 300)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: "#111214").opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .preferredColorScheme(.dark)
        .tint(HubTheme.accent)
        .onAppear { focused = true }
    }

    private func go() {
        let q = question
        question = ""
        agent.start(q)
    }
}

/// The pulsing ring and its instruction, drawn over the whole screen (click-through).
private struct ScreenPointerOverlay: View {
    @ObservedObject var agent: ScreenAgent
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            if let p = agent.pointer, !agent.capturing {
                ZStack(alignment: .topLeading) {
                    Circle()
                        .stroke(HubTheme.accent, lineWidth: 4)
                        .frame(width: 44, height: 44)
                        .scaleEffect(pulse ? 1.35 : 0.85)
                        .opacity(pulse ? 0.35 : 1)
                        .position(p.point)
                    Circle().fill(HubTheme.accent).frame(width: 10, height: 10).position(p.point)
                    if !p.text.isEmpty {
                        Text(p.text)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(HubTheme.onAccent)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(HubTheme.accent))
                            .shadow(radius: 6)
                            .fixedSize()
                            .position(labelPosition(p.point, in: geo.size))
                    }
                }
                .onAppear {
                    pulse = false
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
                }
            }
        }
        .ignoresSafeArea()
    }

    /// Below-right of the point, kept on screen.
    private func labelPosition(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let x = min(max(p.x + 120, 140), size.width - 140)
        let y = p.y + 50 > size.height - 30 ? p.y - 50 : p.y + 50
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Hub pages

struct HubScreenPage: View {
    @ObservedObject private var agent = ScreenAgent.shared
    @State private var question = ""
    @State private var tick = 0

    var body: some View {
        HubPageScaffold(title: "Screen",
                        subtitle: "Ask a question: Claude looks at your screen and guides you step by step, or does it for you.") {
            HubCard {
                HubRow(title: "Open from anywhere", detail: "Opens the screen assistant over any app.") {
                    Text("⌃⌥S").font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
                HubDivider()
                HubRow(title: "Mode", detail: "Guide me points at each step and waits for you. Do it clicks and types itself.") {
                    Picker("", selection: $agent.mode) {
                        Text("Guide me").tag(ScreenAgent.Mode.guide)
                        Text("Do it").tag(ScreenAgent.Mode.act)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                HubDivider()
                HStack(spacing: 8) {
                    HubField(placeholder: "e.g. How do I add an end screen to my YouTube video?", text: $question) { go() }
                    Button(agent.mode == .guide ? "Guide me" : "Do it", action: go)
                        .buttonStyle(HubButtonStyle(primary: true))
                }
            }
            HubLabel("Permissions")
            HubCard {
                permissionRow("Screen Recording", "So Claude can see your screen.",
                              granted: agent.hasScreenRecording, action: agent.requestScreenRecording)
                HubDivider()
                permissionRow("Accessibility", "So the pointer can follow your clicks, and Do it can click and type.",
                              granted: agent.hasAccessibility, action: agent.requestAccessibility)
            }
            .id(tick)
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in tick += 1 }

            if !agent.log.isEmpty {
                HubLabel("Last session")
                HubCard {
                    ForEach(agent.log) { StudioMessageRow(message: $0) }
                }
            }
        }
    }

    private func permissionRow(_ title: String, _ detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HubRow(title: title, detail: detail) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundColor(HubTheme.green)
                    .font(.system(size: 12.5, weight: .semibold))
            } else {
                Button("Allow…", action: action).buttonStyle(HubButtonStyle())
            }
        }
    }

    private func go() {
        let q = question
        question = ""
        agent.start(q)
    }
}

/// The Claude account: the subscription token and the models.
struct HubClaudePage: View {
    @State private var token = ""
    @State private var hasToken = ClaudeCLI.token != nil
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @AppStorage(ClaudeCLI.modelKey) private var studioModel = ""
    @AppStorage(ClaudeCLI.screenModelKey) private var screenModel = "sonnet"

    private let models: [(String, String)] = [("", "Plan default"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")]

    var body: some View {
        HubPageScaffold(title: "Claude",
                        subtitle: "Coucou uses your Claude subscription through Claude Code — never an API key.") {
            HubCard {
                HubRow(title: "Claude Code", detail: ClaudeCLI.executable()?.path
                       ?? "Not found. Install it in Terminal: curl -fsSL https://claude.ai/install.sh | bash") {
                    Image(systemName: ClaudeCLI.executable() == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundColor(ClaudeCLI.executable() == nil ? HubTheme.red : HubTheme.green)
                }
                HubDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Subscription token").font(.system(size: 13.5, weight: .medium))
                    Text(hasToken
                         ? "A token is saved in your Keychain. Paste a new one to replace it."
                         : "Optional if `claude` is already signed in. For a sign-in that lasts a year, run `claude setup-token` in Terminal and paste the token here.")
                        .font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SecureField("sk-ant-oat01-…", text: $token)
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .padding(.horizontal, 12).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 9).fill(HubTheme.field))
                        Button("Save") {
                            ClaudeCLI.saveToken(token)
                            token = ""
                            hasToken = ClaudeCLI.token != nil
                        }
                        .buttonStyle(HubButtonStyle(primary: true))
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                        if hasToken {
                            Button("Remove") { ClaudeCLI.saveToken(""); hasToken = false }
                                .buttonStyle(HubButtonStyle())
                        }
                    }
                }
                HubDivider()
                HStack(spacing: 10) {
                    Button(testing ? "Testing…" : "Test connection", action: test)
                        .buttonStyle(HubButtonStyle()).disabled(testing)
                    if let r = testResult {
                        Text(r.text).font(.system(size: 12))
                            .foregroundColor(r.ok ? HubTheme.green : HubTheme.red)
                            .lineLimit(3).textSelection(.enabled)
                    }
                }
            }
            HubLabel("Models")
            HubCard {
                HubRow(title: "YouTube studio", detail: "Scripts, research and ideas.") { modelPicker($studioModel) }
                HubDivider()
                HubRow(title: "Screen assistant", detail: "Sonnet is the best balance of speed and accuracy.") { modelPicker($screenModel) }
            }
        }
    }

    private func modelPicker(_ binding: Binding<String>) -> some View {
        Picker("", selection: binding) {
            ForEach(models, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden().frame(width: 150)
    }

    private func test() {
        testing = true
        testResult = nil
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CoucouStudio/.test")
        ClaudeCLI.run(prompt: "Reply with exactly: Connected", cwd: dir, model: "haiku") { event in
            guard case .done(let result, _, let isError) = event else { return }
            testing = false
            testResult = isError
                ? (false, ClaudeCLI.isAuthError(result) ? "Not signed in. Run `claude setup-token` and paste the token above." : result)
                : (true, "✓ \(result) — using your Claude plan")
        }
    }
}
#endif
