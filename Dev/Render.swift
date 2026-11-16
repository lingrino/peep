import AppKit

// peep-dev: rendering through the real view stack (PNG output) and the app icon.

@MainActor
func render(_ args: [String]) {
    guard args.count >= 2 else { print("usage: render <file> <out.png> ..."); exit(2) }
    let path = args[0], out = args[1]
    var size = NSSize(width: 900, height: 700)
    var dark = false
    var scrollY: CGFloat = 0
    var select: (Int, Int)?
    var find: String?
    var wait = 0.0
    var early = false   // don't finish background layout first: draw what scrolling alone produces
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--dark": dark = true
        case "--size":
            i += 1
            let p = args[i].split(separator: "x").compactMap { Double($0) }
            size = NSSize(width: p[0], height: p[1])
        case "--scroll": i += 1; scrollY = CGFloat(Double(args[i]) ?? 0)
        case "--select":
            i += 1
            let p = args[i].split(separator: ":").compactMap { Int($0) }
            select = (p[0], p[1])
        case "--find": i += 1; find = args[i]
        case "--wait": i += 1; wait = Double(args[i]) ?? 0
        case "--early": early = true
        case "--remote": ImageStore.remoteFetch = nil   // fetch remote images directly (see main.swift)
        default: print("unknown option \(args[i])"); exit(2)
        }
        i += 1
    }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let view = PreviewView(frame: NSRect(origin: .zero, size: size))
    window.contentView = view
    let t0 = nanotime()
    let doc = Document.open(path: path)
    view.show(doc)
    if !early { (doc.content as? MarkdownContent)?.finishLayout() }
    view.layoutSubtreeIfNeeded()
    if wait > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: wait)); view.layoutSubtreeIfNeeded() }
    if scrollY > 0 { view.documentView.scrollToTop(y: scrollY) }
    if let s = select { view.documentView.select(s.0, s.1) }
    if let f = find { view.find(f) }
    view.layoutSubtreeIfNeeded()
    if ProcessInfo.processInfo.environment["PEEP_DEBUG"] != nil {
        let dv = view.documentView
        print("doc frame", dv.frame, "clip", view.scrollView.contentView.bounds, "subviews", dv.subviews.count, dv.subviews.map { $0.frame })
    }
    let t1 = nanotime()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: rep)
    let t2 = nanotime()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print(doc.timingSummary)
    print(String(format: "open+show %.2fms, first draw %.2fms", Double(t1 - t0) / 1e6, Double(t2 - t1) / 1e6))
}

/// Renders the app icon at every iconset size into `dir` (then: iconutil -c icns dir).
@MainActor
func icon(_ args: [String]) {
    let dir = args[0]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let cs = CGColorSpace(name: CGColorSpace.displayP3)!
            let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            drawIcon(ctx, CGFloat(px))
            let img = ctx.makeImage()!
            let rep = NSBitmapImageRep(cgImage: img)
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/" + name))
        }
    }
}

/// The icon: a warm yellow macOS squircle with a plain dark eye ("peep"), drawn with paths
/// (SF Symbols may not be used in app icons). Regenerate the .icns with:
///   peep-dev icon /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o Bundle/AppIcon.icns
func drawIcon(_ ctx: CGContext, _ s: CGFloat) {
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    // Apple's grid: the shape is inset ~10% with a continuous-corner radius of ~22.4%.
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.2237
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
    // Drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(colorSpace: p3, components: [0.98, 0.76, 0.12, 1])!)
    ctx.fillPath()
    ctx.restoreGState()
    // Background: yellow, a touch lighter at the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: p3, colors: [
        CGColor(colorSpace: p3, components: [1.00, 0.87, 0.33, 1])!,
        CGColor(colorSpace: p3, components: [0.98, 0.74, 0.10, 1])!] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: s / 2, y: rect.maxY), end: CGPoint(x: s / 2, y: rect.minY), options: [])
    ctx.restoreGState()
    // Eye: an almond outline and a solid pupil in warm near-black. Lines get a minimum width so
    // the 16 pt icon still reads.
    let ink = CGColor(colorSpace: p3, components: [0.14, 0.11, 0.06, 1])!
    let c = CGPoint(x: s / 2, y: s / 2)
    let w = rect.width * 0.66, h = rect.width * 0.46   // h: quad control offset (peak ≈ h / 2)
    let eye = CGMutablePath()
    eye.move(to: CGPoint(x: c.x - w / 2, y: c.y))
    eye.addQuadCurve(to: CGPoint(x: c.x + w / 2, y: c.y), control: CGPoint(x: c.x, y: c.y + h))
    eye.addQuadCurve(to: CGPoint(x: c.x - w / 2, y: c.y), control: CGPoint(x: c.x, y: c.y - h))
    eye.closeSubpath()
    ctx.addPath(eye)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(max(1.3, rect.width * 0.058))
    ctx.setLineJoin(.round)
    ctx.strokePath()
    let r = rect.width * 0.115
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}
