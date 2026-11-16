import AppKit
@preconcurrency import XPC

/// The extension's side of the keyboard agent protocol (see Sources/App/Agent.swift).
///
/// One connection per extension process, created lazily. launchd starts the agent on
/// demand when we look up its mach service, so previews work even if it wasn't running.
@MainActor
final class AgentClient {
    static let shared = AgentClient()
    static let service = "com.lingrino.peep.agent"

    typealias KeyHandler = (_ code: UInt16, _ chars: String, _ mods: UInt64) -> Void
    /// A click the agent saw in the Quick Look panel: point from the panel's top-left, panel
    /// size, and the event's timestamp (the late copy Quick Look delivers carries the same).
    typealias ClickHandler = (_ point: CGPoint, _ panel: CGSize, _ timestamp: TimeInterval) -> Void
    private var conn: xpc_connection_t?
    private var handlers: [UInt64: KeyHandler] = [:]
    private var clickHandlers: [UInt64: ClickHandler] = [:]
    /// Last state sent per preview, replayed if the agent restarts.
    private var states: [UInt64: xpc_object_t] = [:]
    private var nextID: UInt64 = 1

    func register(_ handler: @escaping KeyHandler, click: @escaping ClickHandler) -> UInt64 {
        let id = nextID
        nextID += 1
        handlers[id] = handler
        clickHandlers[id] = click
        return id
    }

    func unregister(_ id: UInt64) {
        handlers[id] = nil
        clickHandlers[id] = nil
        states[id] = nil
    }

    func sendState(id: UInt64, size: CGSize, visible: Bool, find: Bool, selection: Bool, matches: Bool) {
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "t", "state")
        xpc_dictionary_set_uint64(m, "id", id)
        xpc_dictionary_set_double(m, "w", size.width)
        xpc_dictionary_set_double(m, "h", size.height)
        xpc_dictionary_set_bool(m, "visible", visible)
        xpc_dictionary_set_bool(m, "find", find)
        xpc_dictionary_set_bool(m, "sel", selection)
        xpc_dictionary_set_bool(m, "matches", matches)
        states[id] = visible ? m : nil
        xpc_connection_send_message(connection(), m)
    }

    /// Fetches a remote resource through the agent (the extension's sandbox has no network).
    func fetch(_ url: URL, _ done: @escaping @MainActor (Data?) -> Void) {
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "t", "fetch")
        xpc_dictionary_set_string(m, "url", url.absoluteString)
        xpc_connection_send_message_with_reply(connection(), m, DispatchQueue.main) { reply in
            var data: Data?
            if xpc_get_type(reply) == XPC_TYPE_DICTIONARY {
                var len = 0
                if let p = xpc_dictionary_get_data(reply, "data", &len), len > 0 { data = Data(bytes: p, count: len) }
            }
            MainActor.assumeIsolated { done(data) }
        }
    }

    func open(_ url: String) {
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "t", "open")
        xpc_dictionary_set_string(m, "url", url)
        xpc_connection_send_message(connection(), m)
    }

    private func connection() -> xpc_connection_t {
        if let conn { return conn }
        let c = xpc_connection_create_mach_service(AgentClient.service, DispatchQueue.main, 0)
        xpc_connection_set_event_handler(c) { msg in
            MainActor.assumeIsolated { AgentClient.shared.received(msg) }
        }
        xpc_connection_resume(c)
        conn = c
        return c
    }

    private func received(_ msg: xpc_object_t) {
        let type = xpc_get_type(msg)
        if type == XPC_TYPE_ERROR {
            if msg === XPC_ERROR_CONNECTION_INTERRUPTED {
                // Agent restarted: re-announce visible previews.
                for (_, s) in states { xpc_connection_send_message(connection(), s) }
            } else {
                conn = nil
            }
            return
        }
        guard type == XPC_TYPE_DICTIONARY, let tp = xpc_dictionary_get_string(msg, "t") else { return }
        let t = String(cString: tp)
        let id = xpc_dictionary_get_uint64(msg, "id")
        if t == "key" {
            let chars = xpc_dictionary_get_string(msg, "chars").map { String(cString: $0) } ?? ""
            handlers[id]?(UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(msg, "code")), chars, xpc_dictionary_get_uint64(msg, "mods"))
        } else if t == "click" {
            clickHandlers[id]?(CGPoint(x: xpc_dictionary_get_double(msg, "x"), y: xpc_dictionary_get_double(msg, "y")),
                               CGSize(width: xpc_dictionary_get_double(msg, "pw"), height: xpc_dictionary_get_double(msg, "ph")),
                               xpc_dictionary_get_double(msg, "ts"))
        }
    }
}
