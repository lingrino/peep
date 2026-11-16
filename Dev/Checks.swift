import AppKit

// peep-dev: checks that must pass (Scripts/check.sh). Each problem found counts in
// `checkFailures`; the tool exits 1 when any were found.

/// Opens, renders (top, middle, bottom) and searches every file under the given paths.
/// Run with CONFIG=debug to turn memory-safety bugs into traps.
@MainActor
func smoke(_ args: [String]) {
    var files: [String] = []
    let fm = FileManager.default
    for a in args {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: a, isDirectory: &isDir), isDir.boolValue {
            let e = fm.enumerator(atPath: a)
            while let f = e?.nextObject() as? String {
                var d: ObjCBool = false
                let full = a + "/" + f
                if fm.fileExists(atPath: full, isDirectory: &d), !d.boolValue { files.append(full) }
            }
        } else { files.append(a) }
    }
    let size = NSSize(width: 900, height: 700)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    let view = PreviewView(frame: NSRect(origin: .zero, size: size))
    window.contentView = view
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    var worst: [(Double, String)] = []
    var total = 0.0
    for (i, f) in files.enumerated() {
        let t0 = nanotime()
        let doc = Document.open(path: f)
        view.show(doc)
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        let first = Double(nanotime() - t0) / 1e6
        let h = view.documentView.bounds.height
        for y in [h / 2, h] {
            view.documentView.scrollToTop(y: y)
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        if let md = doc.content as? MarkdownContent {
            md.finishLayout()
            let bad = mdGeometryErrors(md)
            if !bad.isEmpty { print("GEOMETRY \(f): \(bad.prefix(3).joined(separator: "; "))"); checkFailures += 1 }
        }
        _ = view.find("e")
        view.documentView.selectAll()
        view.cacheDisplay(in: view.bounds, to: rep)
        view.clearFind()
        total += first
        worst.append((first, (f as NSString).lastPathComponent))
        if (i + 1) % 200 == 0 { print("\(i + 1)/\(files.count)") }
    }
    worst.sort { $0.0 > $1.0 }
    print("\(files.count) files, mean first paint \(String(format: "%.2f", total / Double(max(1, files.count))))ms")
    for (t, f) in worst.prefix(8) { print(String(format: "  %7.2fms  %@", t, f)) }
}

/// Link hit testing: for every link run, a point in the middle of its first character must
/// resolve to that link.
@MainActor
func linkCheck(_ args: [String]) {
    for f in args {
        let doc = Document.open(path: f)
        guard let md = doc.content as? MarkdownContent else { continue }
        _ = md.layout(width: 900)
        md.finishLayout()
        var ok = 0, bad = 0
        for r in md.doc.runs where r.style.contains(.link) && !r.style.contains(.image) && r.ref >= 0 && r.end > r.start {
            var e = Int(r.start) + 1
            let t = md.doc.text.base
            while e < Int(r.end) && t[e] & 0xC0 == 0x80 { e += 1 }   // whole first character
            // ... with a following variation selector (U+FE0E/FE0F: EF B8 8E/8F), same glyph.
            if e + 2 < Int(r.end) + 1 && t[e] == 0xEF && t[e + 1] == 0xB8 && (t[e + 2] == 0x8E || t[e + 2] == 0x8F) { e += 3 }
            let a = md.rect(for: Int(r.start), Int(r.start)), b = md.rect(for: e, e)
            // A link starting at a line wrap: its start's caret reads as the previous line's end.
            let p = a.minY == b.minY ? CGPoint(x: (a.minX + b.minX) / 2, y: a.midY) : CGPoint(x: b.minX - 2, y: b.midY)
            if md.link(at: p) == md.doc.links[Int(r.ref)] { ok += 1 } else {
                bad += 1
                if bad <= 4 {
                    let txt = md.doc.text.string(Int(r.start), min(Int(r.end), Int(r.start) + 30))
                    let before = md.doc.text.string(max(0, Int(r.start) - 12), Int(r.start))
                    print("  miss: [\(before)|\(txt)] a=\(a) b=\(b) -> \(md.link(at: p) ?? "nil")")
                }
            }
        }
        print("\((f as NSString).lastPathComponent): \(ok) links found, \(bad) missed")
        if bad > 0 { checkFailures += 1 }
    }
}

/// Tile coverage under outline jumps, overscroll past either end (what elastic scrolling
/// does) and resizes: after every step the visible rect must be covered by placed tiles.
@MainActor
func tileCheck(_ args: [String]) {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 990, height: 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let view = PreviewView(frame: NSRect(x: 0, y: 0, width: 990, height: 800))
    window.contentView = view
    window.orderFrontRegardless()
    var rng = SystemRandomNumberGenerator()
    for f in args {
        let doc = Document.open(path: f)
        view.show(doc)
        view.layoutSubtreeIfNeeded()
        let n = doc.content.outlineEntries.count
        let clip = view.scrollView.contentView
        var gaps = 0, steps = 0
        func check(_ what: String) {
            steps += 1
            if let g = view.documentView.tileCoverageGap() {
                gaps += 1
                if gaps <= 5 { print("  gap at tile row \(g.row) col \(g.col) after \(what) (visible y \(Int(clip.bounds.minY)))") }
            }
        }
        for _ in 0..<400 {
            let maxY = max(0, view.documentView.bounds.height - clip.bounds.height)
            switch Int.random(in: 0..<5, using: &rng) {
            case 0 where n > 0:
                let i = Int.random(in: 0..<n, using: &rng)
                view.jumpToOutline(i); check("jump to entry \(i)")
            case 1:   // overscroll past the end, then settle (the rubber band)
                clip.setBoundsOrigin(NSPoint(x: 0, y: maxY + CGFloat.random(in: 20...300, using: &rng))); check("overscroll at end")
                clip.setBoundsOrigin(NSPoint(x: 0, y: maxY)); check("settle at end")
            case 2:   // overscroll before the top
                clip.setBoundsOrigin(NSPoint(x: 0, y: -CGFloat.random(in: 20...300, using: &rng))); check("overscroll at top")
                clip.setBoundsOrigin(NSPoint(x: 0, y: 0)); check("settle at top")
            case 3:
                clip.setBoundsOrigin(NSPoint(x: 0, y: CGFloat.random(in: 0...max(1, maxY), using: &rng))); check("scroll")
            default:
                let h = CGFloat.random(in: 400...1100, using: &rng)
                window.setContentSize(NSSize(width: 990, height: h))
                view.frame = NSRect(x: 0, y: 0, width: 990, height: h)
                view.layoutSubtreeIfNeeded(); check("resize to \(Int(h))")
            }
        }
        print("\((f as NSString).lastPathComponent): \(steps) steps, \(gaps) with uncovered tiles")
        if gaps > 0 { checkFailures += 1 }
    }
}

/// Boxes whose line baselines fall outside their rect, or that overlap the next block.
@MainActor
func mdGeometryErrors(_ md: MarkdownContent) -> [String] {
    var out: [String] = []
    for i in md.blocks.indices {
        for (k, b) in md.boxes(ofBlock: i).enumerated() {
            for y in b.baselines where y < b.rect.minY - 1 || y > b.rect.maxY + 1 {
                out.append(String(format: "block %d box %d baseline %.0f outside %.0f..%.0f", i, k, y, b.rect.minY, b.rect.maxY))
                break
            }
            if b.rect.minY < md.blocks[i].y - 0.5 || b.rect.maxY > md.blocks[i].y + md.blocks[i].h + 1 {
                out.append(String(format: "block %d box %d outside its block", i, k))
            }
        }
    }
    for i in md.blocks.indices.dropLast() where md.blocks[i].y + md.blocks[i].h > md.blocks[i + 1].y + 0.5 {
        out.append("block \(i) overlaps next")
    }
    return out
}

/// Pixel comparison of two PNGs (as rendered: same size expected). Prints the number of
/// differing pixels and their bounding box; a difference counts as a failure.
func imgDiff(_ args: [String]) {
    guard args.count == 2 else { print("usage: imgdiff <a.png> <b.png>"); exit(2) }
    func pixels(_ path: String) -> (w: Int, h: Int, p: [UInt32])? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var p = [UInt32](repeating: 0, count: w * h)
        let ok = p.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, p) : nil
    }
    guard let a = pixels(args[0]), let b = pixels(args[1]) else { print("can't read images"); exit(2) }
    if a.w != b.w || a.h != b.h {
        print("sizes differ: \(a.w)x\(a.h) vs \(b.w)x\(b.h)")
        checkFailures += 1
        return
    }
    var n = 0, x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
    for y in 0..<a.h {
        for x in 0..<a.w where a.p[y * a.w + x] != b.p[y * a.w + x] {
            n += 1
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
    }
    if n == 0 { print("identical (\(a.w)x\(a.h))"); return }
    print("\(n) pixels differ; x \(x0)-\(x1), y \(y0)-\(y1) (top-left origin) of \(a.w)x\(a.h)")
    checkFailures += 1
}
