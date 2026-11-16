import Darwin

/// Monotonic nanoseconds (pipeline timing, time budgets).
@inline(__always) public func nanotime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
