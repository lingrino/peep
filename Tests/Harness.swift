import Darwin

// A deliberately tiny test harness: no XCTest/Swift Testing/SwiftPM dependency, so tests
// build with the same swiftc invocation as the product (see Scripts/test.sh).
//
// Each test file exposes `let <area>Tests: [Test]`; Tests/main.swift lists them all.

struct Test: Sendable {
    let name: String
    let body: @Sendable () -> Void
    init(_ name: String, _ body: @escaping @Sendable () -> Void) {
        self.name = name
        self.body = body
    }
}

nonisolated(unsafe) var currentFailures = 0
nonisolated(unsafe) var totalFailures = 0

func fail(_ message: String, file: StaticString, line: UInt) {
    currentFailures += 1
    print("    FAIL \(file):\(line): \(message)")
}

func expect(_ cond: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !cond { fail(message(), file: file, line: line) }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    if a != b { fail("\(a) != \(b) \(message())", file: file, line: line) }
}

func runTests(_ tests: [Test], filter: String?) -> Int32 {
    var ran = 0
    for t in tests where filter == nil || t.name.contains(filter!) {
        currentFailures = 0
        t.body()
        ran += 1
        if currentFailures > 0 {
            print("✗ \(t.name)")
            totalFailures += 1
        }
    }
    print(totalFailures == 0 ? "ok: \(ran) tests" : "FAILED: \(totalFailures) of \(ran) tests")
    return totalFailures == 0 ? 0 : 1
}
