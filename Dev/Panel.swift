import AppKit

// peep-dev panelwatch: end-to-end timing in Finder, from outside every process involved.
// Polls the keyboard state and the window list every 2 ms and prints, relative to the last
// key press: when a floating window (the Quick Look panel) appears, when it stops changing
// size, and when it goes away. Run it, then press Space / arrow keys in Finder. Pair it with
// the extension's logs (`prepare ...`; `DIAG=1 Scripts/build.sh install` adds when Quick Look
// shows each preview and main-thread stalls).

@MainActor
func panelWatch(_ args: [String]) {
    let seconds = Double(args.first ?? "30") ?? 30
    let keys: [(CGKeyCode, String)] = [(49, "space"), (125, "down"), (126, "up"), (123, "left"), (124, "right"), (53, "escape")]
    let floating = Int(CGWindowLevelForKey(.floatingWindow))
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss.SSS"
    let start = Date()
    var down = Set<CGKeyCode>()
    var lastKey = Date()
    struct Win { var rect: CGRect; var changed: Date; var settled: Bool }
    var wins: [Int: Win] = [:]
    func ms(_ d: Date) -> String { String(format: "%+6.0f ms", d.timeIntervalSince(lastKey) * 1000) }
    print("watching for \(Int(seconds)) s: press Space or arrow keys in Finder")
    while Date().timeIntervalSince(start) < seconds {
        let now = Date()
        for (code, name) in keys {
            let pressed = CGEventSource.keyState(.combinedSessionState, key: code)
            if pressed && !down.contains(code) {
                lastKey = now
                print("\(fmt.string(from: now))  key \(name)")
            }
            if pressed { down.insert(code) } else { down.remove(code) }
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var seen = Set<Int>()
        for w in list {
            guard let id = w[kCGWindowNumber as String] as? Int, (w[kCGWindowLayer as String] as? Int) == floating,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width < 200 || r.height < 150 { continue }
            seen.insert(id)
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            if var old = wins[id] {
                if old.rect != r { old.rect = r; old.changed = now; old.settled = false }
                if !old.settled && now.timeIntervalSince(old.changed) > 0.15 {
                    old.settled = true
                    print("\(fmt.string(from: old.changed))  \(ms(old.changed))  panel \(id) settled at \(Int(r.width))x\(Int(r.height))")
                }
                wins[id] = old
            } else {
                wins[id] = Win(rect: r, changed: now, settled: false)
                print("\(fmt.string(from: now))  \(ms(now))  panel \(id) (\(owner)) appears at \(Int(r.width))x\(Int(r.height))")
            }
        }
        for id in wins.keys where !seen.contains(id) {
            print("\(fmt.string(from: now))  \(ms(now))  panel \(id) gone")
            wins[id] = nil
        }
        fflush(stdout)
        usleep(2000)
    }
}
