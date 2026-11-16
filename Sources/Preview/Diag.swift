#if PEEP_DIAG
import Foundation
import os

/// Diagnostics for time spent outside our code, built in with `DIAG=1 Scripts/build.sh install`
/// (category "diag"): a watchdog thread that pings the main queue every 5 ms and logs each
/// stall over 40 ms, the process footprint whenever it moves by 50 MB, and (in
/// PreviewViewController) when each prepare begins and when Quick Look shows the preview.
/// These found the ~500 ms Quick Look waited for background layout, and ViewBridge's
/// synchronous teardown during panel resizes. Pair with `peep-dev panelwatch`; to see what a
/// stalled main thread waits on: `sample <pid> 10 1` while reproducing.
enum Diag {
    static let log = Logger(subsystem: "com.lingrino.peep", category: "diag")
    nonisolated(unsafe) private static var ping: UInt64 = 0

    static func start() {
        Thread.detachNewThread {
            var stalledSince: UInt64 = 0
            var lastMB = 0.0
            while true {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let p = ping
                if p != 0 && now - p > 40_000_000 {
                    if stalledSince == 0 { stalledSince = p }
                } else if stalledSince != 0 {
                    log.notice("main thread stalled \(Double(now - stalledSince) / 1e6, format: .fixed(precision: 0))ms")
                    stalledSince = 0
                }
                let mb = footprintMB()
                if abs(mb - lastMB) > 50 {
                    log.notice("footprint \(mb, format: .fixed(precision: 0))MB")
                    lastMB = mb
                }
                DispatchQueue.main.async { ping = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
                usleep(5000)
            }
        }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : -1
    }
}
#endif
