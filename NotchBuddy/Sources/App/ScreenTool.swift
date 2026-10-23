#if !APPSTORE
import AppKit
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers

/// `Coucou --screen-tool <command>`: the hands and eyes of the screen assistant.
///
/// Claude (run by `ScreenAgent`) calls it through the `coucou-screen` wrapper with Bash. It runs as
/// a child of Coucou, so it uses Coucou's Screen Recording and Accessibility permissions. The
/// running app draws the pointer and the messages: the two talk with distributed notifications.
///
/// Coordinates are screen points of the main display, origin top-left — the same as the pixels of
/// the screenshots this tool makes.
enum ScreenTool {
    static let pointNote   = Notification.Name("fr.coucou.screen.point")
    static let sayNote     = Notification.Name("fr.coucou.screen.say")
    static let captureNote = Notification.Name("fr.coucou.screen.capture")
    static let replyNote   = Notification.Name("fr.coucou.screen.reply")

    static let usage = """
    coucou-screen screenshot                      capture the main screen, prints the PNG path
    coucou-screen point X Y "instruction"         show the user where to click, wait for them
    coucou-screen say "message"                   show a message to the user
    coucou-screen click X Y [--double|--right]    (Do it mode only)
    coucou-screen move X Y                        (Do it mode only)
    coucou-screen type "text"                     (Do it mode only)
    coucou-screen key cmd+shift+t                 (Do it mode only)
    coucou-screen scroll X Y up|down [N]          (Do it mode only)
    """

    static func main(_ args: [String]) -> Never {
        let cmd = args.first ?? "help"
        let rest = Array(args.dropFirst())
        let actMode = ProcessInfo.processInfo.environment["COUCOU_SCREEN_MODE"] == "act"
        let actions: Set<String> = ["click", "move", "type", "key", "scroll"]
        if actions.contains(cmd) && !actMode {
            fail("'\(cmd)' is not allowed in Guide mode: use `point` to show the user where to act.")
        }
        if actions.contains(cmd) && !AXIsProcessTrusted() {
            fail("Coucou has no Accessibility permission, so it can't click or type. Ask the user to allow Coucou in System Settings → Privacy & Security → Accessibility.")
        }
        switch cmd {
        case "screenshot": screenshot()
        case "point":      point(rest)
        case "say":
            post(sayNote, ["text": rest.joined(separator: " ")])
            done("Shown.")
        case "click":      click(rest)
        case "move":
            let p = xy(rest)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            done("Moved to \(Int(p.x)),\(Int(p.y)).")
        case "type":       type(rest.joined(separator: " "))
        case "key":        key(rest.first ?? "")
        case "scroll":     scroll(rest)
        default:
            print(usage)
            exit(cmd == "help" ? 0 : 2)
        }
        exit(0)
    }

    // MARK: Eyes

    private static func screenshot() {
        guard CGPreflightScreenCaptureAccess() else {
            fail("Coucou has no Screen Recording permission. Ask the user to allow Coucou in System Settings → Privacy & Security → Screen Recording, then restart Coucou.")
        }
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        prune(dir, keep: 12)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let raw = dir.appendingPathComponent("raw-\(stamp).png")
        let out = dir.appendingPathComponent("screen-\(stamp).png")

        // The pointer and the HUD step aside while the picture is taken.
        post(captureNote, ["state": "begin"])
        Thread.sleep(forTimeInterval: 0.25)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-C", "-m", "-t", "png", raw.path]
        try? p.run()
        p.waitUntilExit()
        post(captureNote, ["state": "end"])

        let bounds = CGDisplayBounds(CGMainDisplayID())
        let size = CGSize(width: bounds.width, height: bounds.height)
        guard let src = CGImageSourceCreateWithURL(raw as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            fail("The screenshot failed.")
        }
        // Scaled to points: one image pixel = one screen point, so coordinates can be used as is.
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(origin: .zero, size: size))
        guard let scaled = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fail("The screenshot failed.")
        }
        CGImageDestinationAddImage(dest, scaled, nil)
        CGImageDestinationFinalize(dest)
        try? FileManager.default.removeItem(at: raw)
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let mouse = CGEvent(source: nil)?.location ?? .zero
        done("""
        \(out.path)
        Size \(Int(size.width))x\(Int(size.height)) (= screen points; use these coordinates). \
        Front app: \(front). Mouse at \(Int(mouse.x)),\(Int(mouse.y)). Read the file to see the screen.
        """)
    }

    private static func prune(_ dir: URL, keep: Int) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for f in files.dropFirst(keep) { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: Guiding

    /// Shows the pointer and waits for the user: a click, Next, or Stop (3 minutes at most).
    private static func point(_ args: [String]) {
        let p = xy(args)
        let text = args.dropFirst(2).joined(separator: " ")
        let center = DistributedNotificationCenter.default()
        final class Box: @unchecked Sendable { var reply: [AnyHashable: Any]? }
        let box = Box()
        let token = center.addObserver(forName: replyNote, object: nil, queue: nil) { note in
            box.reply = note.userInfo ?? [:]
        }
        post(pointNote, ["x": Double(p.x), "y": Double(p.y), "text": text])
        let deadline = Date().addingTimeInterval(180)
        while box.reply == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        center.removeObserver(token)
        guard let reply = box.reply else {
            done("The user didn't act within 3 minutes. Take a screenshot to see where they are.")
        }
        switch reply["how"] as? String {
        case "stop":
            print("The user stopped the session. Stop now and don't take any further action.")
            exit(1)
        case "click":
            let x = (reply["x"] as? Double).map { Int($0) } ?? -1
            let y = (reply["y"] as? Double).map { Int($0) } ?? -1
            done("The user clicked at \(x),\(y). Take a new screenshot to check the result before the next step.")
        default:
            done("The user pressed Next. Take a new screenshot to check the result before the next step.")
        }
    }

    // MARK: Hands

    private static func click(_ args: [String]) {
        let p = xy(args)
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
        done("Clicked at \(Int(p.x)),\(Int(p.y)). Take a screenshot to check the result.")
    }

    private static func type(_ text: String) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.post(tap: .cghidEventTap)
            }
            usleep(15_000)
            i += 16
        }
        done("Typed \(text.count) characters.")
    }

    private static func key(_ combo: String) {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for part in parts {
            switch part {
            case "cmd", "command":       flags.insert(.maskCommand)
            case "shift":                flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control":      flags.insert(.maskControl)
            default:                     code = keyCodes[part]
            }
        }
        guard let code else { fail("Unknown key in '\(combo)'. Use names like return, tab, escape, space, delete, up, a, 1, f5.") }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        done("Pressed \(combo).")
    }

    private static func scroll(_ args: [String]) {
        let p = xy(args)
        let up = args.count > 2 && args[2].lowercased() == "up"
        let n = Int32(args.count > 3 ? Int(args[3]) ?? 5 : 5)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(50_000)
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: up ? n : -n, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
        done("Scrolled \(up ? "up" : "down") \(n) lines at \(Int(p.x)),\(Int(p.y)).")
    }

    // MARK: Helpers

    private static func xy(_ args: [String]) -> CGPoint {
        guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else {
            fail("Expected X Y coordinates (screen points, from the last screenshot).")
        }
        return CGPoint(x: x, y: y)
    }

    private static func post(_ name: Notification.Name, _ info: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
    }

    private static func done(_ message: String) -> Never {
        print(message)
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        print("Error: \(message)")
        exit(1)
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
