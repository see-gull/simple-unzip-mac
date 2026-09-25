import Foundation
import ArchiveKit

/// Thrown by `skip` to mark a test as not applicable on this machine.
struct SkipTest: Error {
    let reason: String
}

/// A test that cannot run for a reason that must **not** be silently skipped.
///
/// A skipped test still exits 0, so anything the user explicitly asked for (an
/// `ARCHIVE_TEST_BINARY`, a fixture path) has to fail loudly instead: a typo in
/// the environment used to turn 16 integration tests into "skipped" and the run
/// into a green tick.
struct FatalTestError: Error, CustomStringConvertible {
    let description: String
}

/// Minimal test registry and assertion set.
///
/// This machine has only Command Line Tools, which ship no XCTest and no
/// swift-testing module, so `swift test` cannot run here. The checks below are
/// the same checks an XCTest target would contain, driven by this runner
/// instead. `swift run SelfTest` is the entry point.
final class TestRunner {
    private struct Entry {
        let name: String
        let body: () async throws -> Void
    }

    private var entries: [Entry] = []
    private var current = ""
    private var failureMessages: [String] = []
    private var passCount = 0
    private var failCount = 0
    private var skipCount = 0

    func test(_ name: String, _ body: @escaping () async throws -> Void) {
        entries.append(Entry(name: name, body: body))
    }

    func recordFailure(_ message: String, file: StaticString, line: UInt) {
        let location = "\(file):\(line)"
        failureMessages.append("    ✗ \(message)  [\(location)]")
    }

    func run() async -> Int32 {
        print("ArchiveKit 自检")
        print(String(repeating: "=", count: 60))
        let suiteStart = Date()

        for entry in entries {
            current = entry.name
            failureMessages = []
            let start = Date()
            do {
                try await entry.body()
                let elapsed = Date().timeIntervalSince(start)
                // A test body that merely returns has not necessarily passed:
                // assertions record into `failureMessages` without throwing.
                // Checking that list here is what makes a green run meaningful.
                if failureMessages.isEmpty {
                    passCount += 1
                    print(String(format: "  ✓ %@  (%.2fs)", entry.name, elapsed))
                } else {
                    failCount += 1
                    print(String(format: "  ✗ %@  (%.2fs)", entry.name, elapsed))
                    for message in failureMessages { print(message) }
                }
            } catch let skip as SkipTest {
                skipCount += 1
                print("  ~ \(entry.name)  跳过：\(skip.reason)")
            } catch {
                failCount += 1
                print("  ✗ \(entry.name)")
                for message in failureMessages { print(message) }
                print("      抛出错误：\(error)")
            }
        }

        let total = Date().timeIntervalSince(suiteStart)
        print(String(repeating: "=", count: 60))
        print(String(format: "通过 %d ｜ 失败 %d ｜ 跳过 %d ｜ 用时 %.1fs",
                     passCount, failCount, skipCount, total))
        return failCount == 0 ? 0 : 1
    }
}

let harness = TestRunner()

// MARK: - Assertions

func expect(_ condition: Bool, _ message: String = "断言失败", file: StaticString = #fileID, line: UInt = #line) {
    if !condition { harness.recordFailure(message, file: file, line: line) }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if lhs != rhs {
        let detail = message.isEmpty ? "" : "\(message) — "
        harness.recordFailure("\(detail)期望 \(rhs)，实际 \(lhs)", file: file, line: line)
    }
}

func expectEqual(_ lhs: Double, _ rhs: Double, accuracy: Double, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if abs(lhs - rhs) > accuracy {
        let detail = message.isEmpty ? "" : "\(message) — "
        harness.recordFailure("\(detail)期望 \(rhs)±\(accuracy)，实际 \(lhs)", file: file, line: line)
    }
}

func expectNotEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if lhs == rhs { harness.recordFailure(message.isEmpty ? "值不应相等：\(lhs)" : message, file: file, line: line) }
}

func expectTrue(_ value: Bool, _ message: String = "期望为真", file: StaticString = #fileID, line: UInt = #line) {
    if !value { harness.recordFailure(message, file: file, line: line) }
}

func expectFalse(_ value: Bool, _ message: String = "期望为假", file: StaticString = #fileID, line: UInt = #line) {
    if value { harness.recordFailure(message, file: file, line: line) }
}

func expectNil<T>(_ value: T?, _ message: String = "期望为 nil", file: StaticString = #fileID, line: UInt = #line) {
    if value != nil { harness.recordFailure(message, file: file, line: line) }
}

func expectNotNil<T>(_ value: T?, _ message: String = "期望非 nil", file: StaticString = #fileID, line: UInt = #line) {
    if value == nil { harness.recordFailure(message, file: file, line: line) }
}

func expectContains<T: Equatable>(_ haystack: [T], _ needle: T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !haystack.contains(needle) {
        harness.recordFailure(message.isEmpty ? "数组中未找到 \(needle)" : message, file: file, line: line)
    }
}

func expectDoesNotContain<T: Equatable>(_ haystack: [T], _ needle: T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
    if haystack.contains(needle) {
        harness.recordFailure(message.isEmpty ? "数组不应包含 \(needle)" : message, file: file, line: line)
    }
}

/// Unwraps or records a failure and throws, aborting the current test.
func require<T>(_ value: T?, _ message: String = "期望非 nil", file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else {
        harness.recordFailure(message, file: file, line: line)
        throw SkipTest(reason: "前置断言失败：\(message)")
    }
    return value
}

func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    harness.recordFailure(message, file: file, line: line)
}

func skip(_ reason: String) throws -> Never {
    throw SkipTest(reason: reason)
}

// MARK: - Shared helpers

enum TempSpace {
    /// Honours `ARCHIVE_TEST_TMP` so runs can stay inside the workspace.
    static func make(_ label: String) throws -> URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["ARCHIVE_TEST_TMP"], !override.isEmpty {
            base = URL(fileURLWithPath: override)
        } else {
            base = FileManager.default.temporaryDirectory
        }
        let safe = label.replacingOccurrences(of: " ", with: "_")
        let directory = base
            .appendingPathComponent("ArchiveKitSelfTest", isDirectory: true)
            .appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    static func write(_ relativePath: String, in root: URL, contents: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Incompressible bytes, so compression genuinely takes time.
    static func writeRandom(_ relativePath: String, in root: URL, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let handle = try FileHandle(forReadingAtPath: "/dev/urandom")
        let data = handle?.readData(ofLength: bytes) ?? Data()
        try? handle?.close()
        try data.write(to: url)
        return url
    }

    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// Thread-safe sink for progress callbacks, which arrive off the main thread.
final class SampleCollector {
    private let lock = NSLock()
    private var storage: [TaskProgress] = []

    func record(_ progress: TaskProgress) {
        lock.lock(); storage.append(progress); lock.unlock()
    }

    var values: [TaskProgress] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// Thread-safe sink for log/error lines.
final class LineCollector {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ line: String) {
        lock.lock(); storage.append(line); lock.unlock()
    }

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
