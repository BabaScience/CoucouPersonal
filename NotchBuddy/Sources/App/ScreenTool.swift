#if !APPSTORE
import AppKit
import ApplicationServices
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// `Coucou --screen-tool <command>`: the hands and eyes of the screen assistant.
///
/// Claude (run by `ScreenAgent`) calls it through the `coucou-screen` wrapper with Bash. That
/// process is only a messenger: macOS credits its permission checks to Claude Code, not to Coucou,
/// so it hands each command to the running Coucou app (`perform`, which has Screen Recording and
/// Accessibility) and prints the answer. The two talk with distributed notifications.
///
/// Coordinates are pixels of the last screenshot (origin top-left); they are converted to screen
/// points with the scale saved when it was taken.
enum ScreenTool {
    static let pointNote    = Notification.Name("fr.coucou.screen.point")
    static let replyNote    = Notification.Name("fr.coucou.screen.reply")
    static let requestNote  = Notification.Name("fr.coucou.screen.request")
    static let responseNote = Notification.Name("fr.coucou.screen.response")

    static let usage = """
    coucou-screen screenshot                      capture the main screen, prints the image path
    coucou-screen zoom X Y W H                    close-up of a region of the last screenshot
    coucou-screen point X Y "instruction"         show the user where to click, wait for them
    coucou-screen say "message"                   show a message to the user
    coucou-screen click X Y [--double|--right]    (Do it mode only)
    coucou-screen move X Y                        (Do it mode only)
    coucou-screen type "text"                     (Do it mode only)
    coucou-screen key cmd+shift+t                 (Do it mode only)
    coucou-screen scroll X Y up|down [N]          (Do it mode only)
    """

    private static let commands: Set<String> = ["screenshot", "zoom", "point", "say", "click", "move", "type", "key", "scroll"]

    // MARK: Messenger (the process Claude runs)

    static func main(_ args: [String]) -> Never {
        let cmd = args.first ?? "help"
        guard commands.contains(cmd) else {
            print(usage)
            exit(cmd == "help" ? 0 : 2)
        }
        let id = UUID().uuidString
        let cwd = FileManager.default.currentDirectoryPath
        final class Box: @unchecked Sendable { var response: [AnyHashable: Any]?; var reply: [AnyHashable: Any]? }
        let box = Box()
        let center = DistributedNotificationCenter.default()
        let t1 = center.addObserver(forName: responseNote, object: nil, queue: nil) { note in
            if note.userInfo?["id"] as? String == id { box.response = note.userInfo }
        }
        // `point` is answered by the user (a click, Next or Stop), not by the app.
        let t2 = center.addObserver(forName: replyNote, object: nil, queue: nil) { note in
            if cmd == "point" { box.reply = note.userInfo ?? [:] }
        }
        center.postNotificationName(requestNote, object: nil,
                                    userInfo: ["id": id, "args": args, "cwd": cwd], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(cmd == "point" ? 180 : 30)
        while box.response == nil && box.reply == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        center.removeObserver(t1)
        center.removeObserver(t2)
        if let r = box.response {
            print(r["output"] as? String ?? "")
            exit(Int32(r["code"] as? Int ?? 1))
        }
        if let reply = box.reply {
            switch reply["how"] as? String {
            case "stop":
                print("The user stopped the session. Stop now and don't take any further action.")
                exit(1)
            case "click":
                let k = Session(cwd: URL(fileURLWithPath: cwd), act: false).pointsPerPixel
                let x = Int((reply["x"] as? Double ?? 0) / k), y = Int((reply["y"] as? Double ?? 0) / k)
                print("The user clicked at \(x),\(y). Take a new screenshot to check the result before the next step.")
            default:
                print("The user pressed Next. Take a new screenshot to check the result before the next step.")
            }
            exit(0)
        }
        print(cmd == "point"
              ? "The user didn't act within 3 minutes. Take a screenshot to see where they are."
              : "Error: Coucou didn't answer. Ask the user to open Coucou Personal and start again from it.")
        exit(1)
    }

    // MARK: Worker (inside the Coucou app)

    /// Runs a command in the app. nil for `point`: the user's answer goes straight to the messenger.
    /// Called off the main thread.
    static func perform(_ args: [String], cwd: URL, act: Bool) -> (output: String, code: Int)? {
        let cmd = args.first ?? ""
        let rest = Array(args.dropFirst())
        let session = Session(cwd: cwd, act: act)
        do {
            let actions: Set<String> = ["click", "move", "type", "key", "scroll"]
            if actions.contains(cmd) && !act {
                try fail("'\(cmd)' is not allowed in Guide mode: use `point` to show the user where to act.")
            }
            if actions.contains(cmd) && !AXIsProcessTrusted() {
                try fail("Coucou has no Accessibility permission, so it can't click or type. Ask the user to allow Coucou Personal in System Settings → Privacy & Security → Accessibility.")
            }
            switch cmd {
            case "screenshot": try session.screenshot()
            case "zoom":       try session.zoom(rest)
            case "point":
                let p = try session.xy(rest)
                let text = rest.dropFirst(2).joined(separator: " ")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { ScreenAgent.shared.showPointer(p, text) }
                }
                return nil
            case "say":
                let text = rest.joined(separator: " ")
                DispatchQueue.main.async { MainActor.assumeIsolated { ScreenAgent.shared.say(text) } }
                try done("Shown.")
            case "click":      try session.click(rest)
            case "move":
                let p = try session.xy(rest)
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                try done("Moved.")
            case "type":       try session.type(rest.joined(separator: " "))
            case "key":        try session.key(rest.first ?? "")
            case "scroll":     try session.scroll(rest)
            default:           try fail("Unknown command.\n\(usage)")
            }
            return ("", 0)
        } catch let e as Exit {
            return (e.message, e.code)
        } catch {
            return ("Error: \(error.localizedDescription)", 1)
        }
    }

    /// How a command ends: its message, and 0 for success.
    private struct Exit: Error { let message: String; let code: Int }
    private static func done(_ message: String) throws -> Never { throw Exit(message: message, code: 0) }
    private static func fail(_ message: String) throws -> Never { throw Exit(message: "Error: \(message)", code: 1) }

    /// One command's context: the session folder (screenshots and their scale) and the mode.
    private struct Session {
        let cwd: URL
        let act: Bool

        // MARK: Eyes

        /// The longest side Claude sees in full detail: bigger images get shrunk by Claude Code
        /// (an ultrawide came out 600 px wide), so screenshots are made at this size.
        static let maxSide: CGFloat = 1568

        var shotsDir: URL { cwd.appendingPathComponent("shots") }
        var scaleFile: URL { shotsDir.appendingPathComponent(".scale") }

        /// Screen points per screenshot pixel, from the last screenshot (1 before any).
        var pointsPerPixel: CGFloat {
            guard let s = try? String(contentsOf: scaleFile, encoding: .utf8), let v = Double(s) else { return 1 }
            return CGFloat(v)
        }

        /// Captures the main display (or `rect` of it, in points) at full resolution.
        /// Captures the main display (or `rect` of it, in points) with ScreenCaptureKit, inside the
        /// app so its own Screen Recording permission applies. Coucou's windows (the panel, the
        /// pointer) are left out of the picture. `pixels` is the longest side wanted.
        func capture(_ rect: CGRect? = nil, pixels: CGFloat) throws -> CGImage {
            guard CGPreflightScreenCaptureAccess() else {
                try ScreenTool.fail("Coucou has no Screen Recording permission. Ask the user to allow Coucou Personal in System Settings → Privacy & Security → Screen Recording, then restart it.")
            }
            final class Box: @unchecked Sendable { var image: CGImage?; var error: Error? }
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                            ?? content.displays.first else { throw CocoaError(.fileNoSuchFile) }
                    let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
                    let area = rect ?? CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
                    // Output pixels per point: shrunk to fit `pixels`, at most the display's own density.
                    let fit = min(CGFloat(filter.pointPixelScale), pixels / max(area.width, area.height))
                    let config = SCStreamConfiguration()
                    if let rect { config.sourceRect = rect }
                    config.width = max(1, Int((area.width * fit).rounded()))
                    config.height = max(1, Int((area.height * fit).rounded()))
                    config.showsCursor = true
                    box.image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                } catch {
                    box.error = error
                }
                done.signal()
            }
            if done.wait(timeout: .now() + 10) == .timedOut { try ScreenTool.fail("The screenshot timed out.") }
            guard let img = box.image else {
                try ScreenTool.fail("The screenshot failed: \(box.error?.localizedDescription ?? "unknown error").")
            }
            return img
        }

        /// Writes `img` as a JPEG of `size` pixels; returns its path.
        func save(_ img: CGImage, size: CGSize, prefix: String) throws -> URL {
            prune(shotsDir, keep: 12)
            let out = shotsDir.appendingPathComponent("\(prefix)-\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
            guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { try ScreenTool.fail("The screenshot failed.") }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(origin: .zero, size: size))
            guard let scaled = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                try ScreenTool.fail("The screenshot failed.")
            }
            CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(dest)
            return out
        }

        func screenshot() throws {
            let bounds = CGDisplayBounds(CGMainDisplayID())
            let img = try capture(pixels: Self.maxSide)
            let k = min(1, Self.maxSide / max(bounds.width, bounds.height))
            let size = CGSize(width: (bounds.width * k).rounded(), height: (bounds.height * k).rounded())
            let out = try save(img, size: size, prefix: "screen")
            // Every command takes coordinates in this image's pixels and converts them back.
            try? String(Double(bounds.width / size.width)).write(to: scaleFile, atomically: true, encoding: .utf8)
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            let mouse = toPixels(CGEvent(source: nil)?.location ?? .zero)
            try ScreenTool.done("""
            \(out.path)
            Size \(Int(size.width))x\(Int(size.height)) pixels. All coordinates you pass to coucou-screen are pixels of \
            this image. Front app: \(front). Mouse at \(Int(mouse.x)),\(Int(mouse.y)). Read the file to see the screen; \
            use `zoom` to read small text.
            """)
        }

        /// A close-up of part of the last screenshot, to read small text.
        func zoom(_ args: [String]) throws {
            guard args.count >= 4, let x = Double(args[0]), let y = Double(args[1]),
                  let w = Double(args[2]), let h = Double(args[3]), w > 0, h > 0 else {
                try ScreenTool.fail("Usage: zoom X Y W H (a region of the last screenshot, in its pixels).")
            }
            let k = pointsPerPixel
            let region = CGRect(x: x * k, y: y * k, width: w * k, height: h * k)
            let img = try capture(region, pixels: Self.maxSide)
            let fit = min(1, Self.maxSide / max(CGFloat(img.width), CGFloat(img.height)))
            let size = CGSize(width: (CGFloat(img.width) * fit).rounded(), height: (CGFloat(img.height) * fit).rounded())
            let out = try save(img, size: size, prefix: "zoom")
            let f = w / Double(size.width)
            try ScreenTool.done("""
            \(out.path)
            Close-up of \(Int(x)),\(Int(y)) \(Int(w))x\(Int(h)), shown at \(Int(size.width))x\(Int(size.height)). \
            To act on something in it, convert back: screenshot x = \(Int(x)) + zx * \(String(format: "%.3f", f)), \
            y = \(Int(y)) + zy * \(String(format: "%.3f", f)).
            """)
        }

        func toPixels(_ p: CGPoint) -> CGPoint {
            let k = pointsPerPixel
            return CGPoint(x: p.x / k, y: p.y / k)
        }

        func prune(_ dir: URL, keep: Int) {
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["png", "jpg"].contains($0.pathExtension) }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for f in files.dropFirst(keep) { try? FileManager.default.removeItem(at: f) }
        }

        // MARK: Hands

        func click(_ args: [String]) throws {
            let p = try xy(args)
            let right = args.contains("--right")
            let count = args.contains("--double") ? 2 : 1
            let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right
                ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button)?.post(tap: .cghidEventTap)
            usleep(60_000)
            for i in 1...count {
                for type in [down, up] {
                    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                    e?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                    e?.post(tap: .cghidEventTap)
                    usleep(30_000)
                }
            }
            try ScreenTool.done("Clicked at \(Int(p.x)),\(Int(p.y)). Take a screenshot to check the result.")
        }

        func type(_ text: String) throws {
            // One character per key event: many apps (Calculator, games, terminals) only read the
            // first character of a multi-character event.
            for ch in text {
                let units = Array(String(ch).utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e?.post(tap: .cghidEventTap)
                }
                usleep(12_000)
            }
            try ScreenTool.done("Typed \(text.count) characters.")
        }

        func key(_ combo: String) throws {
            let parts = combo.lowercased().split(separator: "+").map(String.init)
            var flags: CGEventFlags = []
            var code: CGKeyCode?
            for part in parts {
                switch part {
                case "cmd", "command":       flags.insert(.maskCommand)
                case "shift":                flags.insert(.maskShift)
                case "opt", "option", "alt": flags.insert(.maskAlternate)
                case "ctrl", "control":      flags.insert(.maskControl)
                default:                     code = ScreenTool.keyCodes[part]
                }
            }
            guard let code else { try ScreenTool.fail("Unknown key in '\(combo)'. Use names like return, tab, escape, space, delete, up, a, 1, f5.") }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                e?.flags = flags
                e?.post(tap: .cghidEventTap)
                usleep(20_000)
            }
            try ScreenTool.done("Pressed \(combo).")
        }

        func scroll(_ args: [String]) throws {
            let p = try xy(args)
            let up = args.count > 2 && args[2].lowercased() == "up"
            let n = Int32(args.count > 3 ? Int(args[3]) ?? 5 : 5)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(50_000)
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: up ? n : -n, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
            try ScreenTool.done("Scrolled \(up ? "up" : "down") \(n) lines at \(Int(p.x)),\(Int(p.y)).")
        }

        // MARK: Helpers

        func xy(_ args: [String]) throws -> CGPoint {
            guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else {
                try ScreenTool.fail("Expected X Y coordinates (pixels of the last screenshot).")
            }
            let k = pointsPerPixel
            return CGPoint(x: x * k, y: y * k)
        }
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
        ]
        let letters: [(String, CGKeyCode)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31),
            ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29)]
        for (k, v) in letters { m[k] = v }
        let fkeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, c) in fkeys.enumerated() { m["f\(i + 1)"] = c }
        return m
    }()
}
#endif
