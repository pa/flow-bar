import Foundation

/// Minimal test harness — no XCTest (unavailable under Command Line Tools).
/// Records pass/fail counts; `main` exits non-zero if anything failed.
@MainActor
enum T {
    static var passed = 0
    static var failed = 0

    static func expect(_ condition: Bool, _ message: String,
                       file: StaticString = #file, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failed += 1
            print("  ✗ FAIL: \(message)  (\(file):\(line))")
        }
    }

    static func equal<V: Equatable>(_ actual: V, _ expected: V, _ message: String = "",
                                    file: StaticString = #file, line: UInt = #line) {
        if actual == expected {
            passed += 1
        } else {
            failed += 1
            print("  ✗ FAIL: \(message) — got \(actual), expected \(expected)  (\(file):\(line))")
        }
    }

    /// Run a named test closure, reporting any thrown error as a failure.
    static func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            failed += 1
            print("  ✗ THREW in \(name): \(error)")
        }
    }

    static func summarize() -> Never {
        print("\n\(failed == 0 ? "✓ all green" : "✗ failures") — \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
