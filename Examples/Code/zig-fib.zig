const std = @import("std");

/// Iterative Fibonacci with overflow checks.
fn fib(n: u32) !u64 {
    var a: u64 = 0;
    var b: u64 = 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const next = try std.math.add(u64, a, b);
        a = b;
        b = next;
    }
    return a;
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    for ([_]u32{ 10, 50, 90 }) |n| {
        try stdout.print("fib({d}) = {d}\n", .{ n, try fib(n) });
    }
}
