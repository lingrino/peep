import AppKit

// One binary, two roles:
//  - launched by launchd as the `com.lingrino.peep.agent` job -> keyboard agent (no UI)
//  - launched by the user (Finder/open)                       -> small host/status app
if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Agent.label {
    Agent.run()
} else {
    HostApp.run()
}
