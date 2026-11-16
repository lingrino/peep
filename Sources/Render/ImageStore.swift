import AppKit
import ImageIO

/// Loads a markdown document's images (local, remote, data: URIs, SVG) off the main thread.
/// Identical URLs within a document load once. Each load finishing triggers one coalesced
/// relayout (image sizes feed text layout).
@MainActor
final class ImageStore {
    enum State { case idle, loading, loaded, failed }
    struct Slot {
        var state = State.idle
        var image: CGImage?
        var size = CGSize.zero      // natural size in points
    }

    private var slots: [Slot]
    private let specs: [MDImage]
    private let baseDir: URL?
    var dark = false
    var onLoad: (() -> Void)?
    private var started = false
    private var notifyScheduled = false

    /// How remote (http/https) images are fetched. Defaults to URLSession; the Quick Look
    /// extension routes through the keyboard agent because its sandbox has no network.
    nonisolated(unsafe) static var remoteFetch: (@MainActor (URL, @escaping @MainActor (Data?) -> Void) -> Void)?

    /// Bound decode cost/memory: nothing is drawn wider than a screen.
    nonisolated static let maxPixels = 2600
    nonisolated static let maxBytes = 25 << 20

    init(_ specs: [MDImage], baseDir: URL?) {
        self.specs = specs
        self.baseDir = baseDir
        slots = [Slot](repeating: Slot(), count: specs.count)
    }

    func start() {
        if started { return }
        started = true
        var byURL: [String: [Int]] = [:]
        for (i, s) in specs.enumerated() {
            let u = (dark ? s.darkURL : nil) ?? s.url
            byURL[u, default: []].append(i)
        }
        for (url, indices) in byURL {
            for i in indices { slots[i].state = .loading }
            load(url) { [weak self] img, size in
                guard let self else { return }
                for i in indices {
                    self.slots[i].state = img == nil ? .failed : .loaded
                    self.slots[i].image = img
                    self.slots[i].size = size
                }
                self.scheduleNotify()
            }
        }
    }

    private func scheduleNotify() {
        if notifyScheduled { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            self.onLoad?()
        }
    }

    func image(_ i: Int) -> CGImage? { i < slots.count ? slots[i].image : nil }
    func failed(_ i: Int) -> Bool { i < slots.count && slots[i].state == .failed }
    func alt(_ i: Int) -> String { i < specs.count ? specs[i].alt : "" }

    /// Display sizes of all images (snapshot for a parallel layout pass).
    func sizes(maxWidth: CGFloat) -> [CGSize] {
        (0..<slots.count).map { let (w, h) = size($0, maxWidth: maxWidth); return CGSize(width: w, height: h) }
    }

    /// Display size in points: HTML width/height attributes win, else natural size, scaled
    /// down to fit `maxWidth`. Unloaded images reserve a small square.
    func size(_ i: Int, maxWidth: CGFloat) -> (CGFloat, CGFloat) {
        guard i < slots.count else { return (1, 1) }
        let spec = specs[i]
        let slot = slots[i]
        var w = CGFloat(spec.width), h = CGFloat(spec.height)
        let nat = slot.size
        switch slot.state {
        case .failed: return w > 0 && h > 0 ? (w, h) : (0.01, 0.01)
        case .idle, .loading:
            if w > 0 && h > 0 { break }
            if w > 0 { return (min(w, maxWidth), 16) }
            return (16, 16)
        case .loaded:
            if w > 0 && h == 0 && nat.width > 0 { h = w * nat.height / nat.width }
            else if h > 0 && w == 0 && nat.height > 0 { w = h * nat.width / nat.height }
            else if w == 0 && h == 0 { w = nat.width; h = nat.height }
        }
        if w > maxWidth { h = h * maxWidth / w; w = maxWidth }
        return (max(1, w.rounded()), max(1, h.rounded()))
    }

    // MARK: - Loading

    private func resolve(_ s: String) -> URL? {
        if s.hasPrefix("data:") { return URL(string: s) }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) { return u }
        // Relative (or absolute) path; drop query/fragment.
        var path = s
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return baseDir?.appendingPathComponent(path).standardizedFileURL
    }

    private func load(_ s: String, done: @escaping @MainActor (CGImage?, CGSize) -> Void) {
        guard let url = resolve(s) else { done(nil, .zero); return }
        let finish: @Sendable (Data?) -> Void = { data in
            let (img, size) = ImageStore.decode(data)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(img, size) } }
        }
        if url.scheme == "data" {
            DispatchQueue.global(qos: .userInitiated).async { finish(ImageStore.dataURI(s)) }
        } else if url.isFileURL {
            DispatchQueue.global(qos: .userInitiated).async {
                finish(try? Data(contentsOf: url, options: .mappedIfSafe))
            }
        } else if let fetch = ImageStore.remoteFetch {
            fetch(url) { data in
                DispatchQueue.global(qos: .userInitiated).async { finish(data) }
            }
        } else {
            var req = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
            req.setValue("Peep (Quick Look)", forHTTPHeaderField: "User-Agent")
            ImageStore.session.dataTask(with: req) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                finish(ok ? data : nil)
            }.resume()
        }
    }

    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    nonisolated static func dataURI(_ s: String) -> Data? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let meta = s[..<comma]
        let payload = String(s[s.index(after: comma)...])
        if meta.hasSuffix(";base64") { return Data(base64Encoded: payload, options: .ignoreUnknownCharacters) }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }

    /// Decodes bitmap formats with ImageIO (downsampled), SVG/PDF via NSImage.
    nonisolated static func decode(_ data: Data?) -> (CGImage?, CGSize) {
        guard let data, !data.isEmpty, data.count <= maxBytes else { return (nil, .zero) }
        if let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let pw = (props[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
            let ph = (props[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
            let dpi = (props[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
            let scale = dpi >= 144 ? 2 : 1   // @2x assets (144 dpi) display at half their pixel size
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if pw > 0, let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return (img, CGSize(width: pw / CGFloat(scale), height: ph / CGFloat(scale)))
            }
        }
        // SVG (common for badges) and PDF: let AppKit rasterize at 2x.
        guard let ns = NSImage(data: data), ns.size.width > 0 else { return (nil, .zero) }
        var rect = CGRect(origin: .zero, size: CGSize(width: ns.size.width * 2, height: ns.size.height * 2))
        let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        return (cg, ns.size)
    }
}
