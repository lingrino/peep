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
    private var conn: xpc_connection_t?
    private var handlers: [UInt64: KeyHandler] = [:]
    /// Last state sent per preview, replayed if the agent restarts.
    private var states: [UInt64: xpc_object_t] = [:]
    private var nextID: UInt64 = 1

    func register(_ handler: @escaping KeyHandler) -> UInt64 {
        let id = nextID
        nextID += 1
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt64) {
        handlers[id] = nil
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
        guard type == XPC_TYPE_DICTIONARY, let t = xpc_dictionary_get_string(msg, "t"), String(cString: t) == "key" else { return }
        let id = xpc_dictionary_get_uint64(msg, "id")
        let chars = xpc_dictionary_get_string(msg, "chars").map { String(cString: $0) } ?? ""
        handlers[id]?(UInt16(truncatingIfNeeded: xpc_dictionary_get_uint64(msg, "code")), chars, xpc_dictionary_get_uint64(msg, "mods"))
    }
}
