import Foundation

/// Fetches remote images for previews: in the keyboard agent for the Quick Look extension
/// (whose sandbox has no network), directly in the app's viewer and `peep-dev render --remote`.
///
/// Documents choose these URLs, and previews load them without a click (selecting a file in
/// Finder's column view is enough), so requests are limited to what an image needs:
/// - https only, and never to this machine or the local network: no loopback, private,
///   link-local or unique-local addresses, `localhost`, `.local`, or single-label intranet
///   names, checked again on every redirect (a README must not be able to send requests to
///   a router's admin page or a local dev server);
/// - no cookies (sent or stored), a 15 s request and 30 s total timeout;
/// - responses are streamed and cancelled past `maxBytes` (declared or received).
final class RemoteFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = RemoteFetch()
    static let maxBytes = 25 << 20

    private struct Pending {
        var data = Data()
        let done: @Sendable (Data?) -> Void
    }
    /// Only touched on the session's serial delegate queue.
    private var pending: [Int: Pending] = [:]
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "RemoteFetch"
        return q
    }()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral   // in-memory cache only: repeat badges are free
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c, delegate: self, delegateQueue: queue)
    }()

    /// Calls `done` once, on a background queue: the body, or nil (refused, failed, not 2xx,
    /// too large).
    func fetch(_ url: URL, done: @escaping @Sendable (Data?) -> Void) {
        guard RemoteFetch.allowed(url) else { done(nil); return }
        var r = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
        r.setValue("Peep (Quick Look)", forHTTPHeaderField: "User-Agent")
        let req = r
        queue.addOperation { [self] in
            let task = session.dataTask(with: req)
            pending[task.taskIdentifier] = Pending(done: done)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        completionHandler(ok && response.expectedContentLength <= Int64(RemoteFetch.maxBytes) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var p = pending[dataTask.taskIdentifier] else { return }
        if p.data.count + data.count > RemoteFetch.maxBytes {
            p.data = Data()
            pending[dataTask.taskIdentifier] = p
            dataTask.cancel()
            return
        }
        p.data.append(data)
        pending[dataTask.taskIdentifier] = p
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(RemoteFetch.allowed) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = pending.removeValue(forKey: task.taskIdentifier) else { return }
        let ok = error == nil && (task.response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
        p.done(ok && !p.data.isEmpty ? p.data : nil)
    }

    // MARK: - Policy

    static func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", var host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if let v4 = ipv4(host) { return publicIPv4(v4) }
        if host.contains(":") { return publicIPv6(host) }
        if !host.contains(".") { return false }   // localhost, intranet names
        for s in [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".intranet", ".corp"] where host.hasSuffix(s) {
            return false
        }
        return true
    }

    /// A host that ends in a number is an address to the network stack (`127.1`, `0x7f.1`,
    /// `2130706433` all mean loopback): only plain dotted quads are decoded; other numeric
    /// spellings come back as 0 (refused). nil: a name.
    private static func ipv4(_ h: String) -> UInt32? {
        let digits = { (s: Substring) in !s.isEmpty && s.allSatisfy { $0 >= "0" && $0 <= "9" } }
        guard let last = h.split(separator: ".").last,
              digits(last) || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit)) else { return nil }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return 0 }
        var v: UInt32 = 0
        for p in parts {
            guard digits(p), p.count <= 3, let b = UInt8(p) else { return 0 }
            v = v << 8 | UInt32(b)
        }
        return v
    }

    private static func publicIPv4(_ a: UInt32) -> Bool {
        let b0 = a >> 24, b1 = (a >> 16) & 0xFF
        switch b0 {
        case 0, 10, 127: return false
        case 100 where (64...127).contains(b1): return false   // carrier-grade NAT
        case 169 where b1 == 254: return false                 // link-local
        case 172 where (16...31).contains(b1): return false
        case 192 where b1 == 168: return false
        case 224...255: return false                           // multicast, reserved
        default: return true
        }
    }

    private static func publicIPv6(_ h: String) -> Bool {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, h, &addr) == 1 else { return false }
        let b = withUnsafeBytes(of: addr) { Array($0) }
        if b[0..<15].allSatisfy({ $0 == 0 }) { return false }                     // :: and ::1
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return false }                    // fe80::/10 link-local
        if b[0] & 0xFE == 0xFC { return false }                                    // fc00::/7 unique-local
        if b[0] == 0xFF { return false }                                           // multicast
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {   // ::ffff:a.b.c.d
            return publicIPv4(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
        }
        return true
    }
}
