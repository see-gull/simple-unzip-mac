import CryptoKit
import Foundation
import ArchiveKit

// Exhaustive round-trip matrix for Simple Unzip's engine layer.
//
//   swift run -c release ExhaustiveTest
//
// Every format the app offers is exercised across every compression level, with
// and without a password where the format supports one. Each case is a full
// round trip: compress -> list -> extract -> compare against a manifest of the
// source -> optional negative check without the password -> clean up.
//
// Configuration (all optional except the tool):
//   ARCHIVE_TEST_BINARY   path to the 7zz under test
//   EXHAUSTIVE_WORK        scratch root (defaults to a system temp directory)
//   EXHAUSTIVE_FILTER      only run cases whose label contains this substring
//   EXHAUSTIVE_LEVELS      comma list of levels, e.g. "0,9"
//   EXHAUSTIVE_PASSWORD    password used for the encrypted cases
//   EXHAUSTIVE_KEEP        set to keep archives instead of deleting them

// MARK: - Configuration

let environment = ProcessInfo.processInfo.environment

func environmentValue(_ key: String) -> String? {
    guard let value = environment[key], !value.isEmpty else { return nil }
    return value
}

guard let toolPath = environmentValue("ARCHIVE_TEST_BINARY") else {
    FileHandle.standardError.write(Data("请设置 ARCHIVE_TEST_BINARY 指向要测试的 7zz\n".utf8))
    exit(2)
}
let toolURL = URL(fileURLWithPath: toolPath)
guard FileManager.default.isExecutableFile(atPath: toolURL.path) else {
    FileHandle.standardError.write(Data("不可执行：\(toolPath)\n".utf8))
    exit(2)
}

let workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .deletingLastPathComponent()   // app/ -> workspace root
let defaultWork = FileManager.default.temporaryDirectory
    .appendingPathComponent("simple-unzip-exhaustive", isDirectory: true)
let workRoot = environmentValue("EXHAUSTIVE_WORK").map { URL(fileURLWithPath: $0) } ?? defaultWork
let password = environmentValue("EXHAUSTIVE_PASSWORD") ?? "SimpleUnzip-Test-2026"
let filter = environmentValue("EXHAUSTIVE_FILTER")
let keepArtifacts = environmentValue("EXHAUSTIVE_KEEP") != nil
let levelsOverride: [Int]? = environmentValue("EXHAUSTIVE_LEVELS").map { raw in
    raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
}

// MARK: - Sources
//
// The material is supplied by the caller rather than hard-coded, so the tool
// works on any machine and no third-party test data has to live in the repo.
//
//   EXHAUSTIVE_FOLDER=/path/to/a/folder
//   EXHAUSTIVE_FILE=/path/to/a/file

guard let folderPath = environmentValue("EXHAUSTIVE_FOLDER"),
      let filePath = environmentValue("EXHAUSTIVE_FILE") else {
    FileHandle.standardError.write(Data("""
    这个穷举测试需要两份素材，请用环境变量指定：

      EXHAUSTIVE_FOLDER=/路径/到一个文件夹     # 用于目录类格式
      EXHAUSTIVE_FILE=/路径/到某个文件         # 用于 gzip / bzip2 / xz

    可选：
      EXHAUSTIVE_WORK=/路径/到临时目录         # 默认使用系统临时目录
      EXHAUSTIVE_FILTER=7z                     # 只跑标签包含该字符串的用例
      EXHAUSTIVE_LEVELS=0,5,9                  # 只跑指定压缩级别
      EXHAUSTIVE_PASSWORD=...                  # 加密用例使用的密码
      EXHAUSTIVE_KEEP=1                        # 保留产物，便于排查

    """.utf8))
    exit(2)
}

let folderSource = URL(fileURLWithPath: folderPath)
let fileSource = URL(fileURLWithPath: filePath)

guard FileManager.default.fileExists(atPath: folderSource.path) else {
    FileHandle.standardError.write(Data("找不到文件夹素材：\(folderSource.path)\n".utf8))
    exit(2)
}
guard FileManager.default.fileExists(atPath: fileSource.path) else {
    FileHandle.standardError.write(Data("找不到单文件素材：\(fileSource.path)\n".utf8))
    exit(2)
}

// MARK: - Matrix definition

enum SourceKind {
    case folder
    case singleFile
}

struct MatrixCase {
    let label: String
    let format: ArchiveFormat
    let level: Int?
    let password: String?
    let hideNames: Bool
    let source: URL
    let sourceKind: SourceKind
}

func buildCases() -> [MatrixCase] {
    var cases: [MatrixCase] = []

    // Formats that can hold a directory tree.
    let directoryFormats: [ArchiveFormat] = [
        .sevenZip, .zip, .tar, .tarGzip, .tarBzip2, .tarXz, .wim,
    ]

    for format in directoryFormats {
        let levels: [Int?] = format.supportsCompressionLevel
            ? (levelsOverride ?? Array(0...9)).map { Optional($0) }
            : [nil]
        for level in levels {
            let levelLabel = level.map { "mx\($0)" } ?? "无级别"

            if format.supportsEncryption {
                cases.append(MatrixCase(
                    label: "\(format.rawValue) \(levelLabel)",
                    format: format, level: level, password: nil, hideNames: false,
                    source: folderSource, sourceKind: .folder
                ))
                cases.append(MatrixCase(
                    label: "\(format.rawValue) \(levelLabel) 密码",
                    format: format, level: level, password: password, hideNames: false,
                    source: folderSource, sourceKind: .folder
                ))
                if format == .sevenZip {
                    cases.append(MatrixCase(
                        label: "\(format.rawValue) \(levelLabel) 密码+隐藏文件名",
                        format: format, level: level, password: password, hideNames: true,
                        source: folderSource, sourceKind: .folder
                    ))
                }
            } else {
                cases.append(MatrixCase(
                    label: "\(format.rawValue) \(levelLabel)",
                    format: format, level: level, password: nil, hideNames: false,
                    source: folderSource, sourceKind: .folder
                ))
            }
        }
    }

    // Formats that only ever hold a single file.
    for format in [ArchiveFormat.gzip, .bzip2, .xz] {
        for level in levelsOverride ?? Array(0...9) {
            cases.append(MatrixCase(
                label: "\(format.rawValue) mx\(level)",
                format: format, level: level, password: nil, hideNames: false,
                source: fileSource, sourceKind: .singleFile
            ))
        }
    }

    return cases
}

let allCases = buildCases().filter { entry in
    guard let filter else { return true }
    return entry.label.contains(filter)
}

// MARK: - Manifest

struct ManifestEntry: Hashable {
    let relativePath: String
    let isDirectory: Bool
    let size: Int64
    let digest: String?
}

enum ManifestError: Error, CustomStringConvertible {
    case unreadable(String, String)
    var description: String {
        switch self {
        case .unreadable(let path, let reason): return "无法读取 \(path)：\(reason)"
        }
    }
}

func buildManifest(root: URL) throws -> [ManifestEntry] {
    let fileManager = FileManager.default
    var entries: [ManifestEntry] = []

    if fileManager.fileExists(atPath: root.path),
       (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true {
        // A single file: the manifest is just that file.
        let data = try Data(contentsOf: root)
        entries.append(ManifestEntry(
            relativePath: root.lastPathComponent,
            isDirectory: false,
            size: Int64(data.count),
            digest: SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        ))
        return entries
    }

    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
        options: [],
        errorHandler: { _, _ in true }
    ) else {
        throw ManifestError.unreadable(root.path, "无法枚举")
    }

    let rootPath = root.standardizedFileURL.path
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        // Skip the scratch area itself if it ever ends up nested.
        var relative = url.standardizedFileURL.path
        if relative.hasPrefix(rootPath + "/") {
            relative = String(relative.dropFirst(rootPath.count + 1))
        }

        if values.isDirectory == true {
            entries.append(ManifestEntry(relativePath: relative, isDirectory: true, size: 0, digest: nil))
        } else if values.isRegularFile == true {
            let data = try Data(contentsOf: url)
            entries.append(ManifestEntry(
                relativePath: relative,
                isDirectory: false,
                size: Int64(data.count),
                digest: SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            ))
        }
    }
    return entries.sorted { $0.relativePath < $1.relativePath }
}

/// Compares two manifests and returns a short description of the first
/// difference, or `nil` when they match.
func manifestDifference(expected: [ManifestEntry], actual: [ManifestEntry]) -> String? {
    let expectedFiles = expected.filter { !$0.isDirectory }
    let actualFiles = actual.filter { !$0.isDirectory }
    let expectedDirs = expected.filter(\.isDirectory).count
    let actualDirs = actual.filter(\.isDirectory).count

    if expectedFiles.count != actualFiles.count {
        return "文件数不符：期望 \(expectedFiles.count)，实际 \(actualFiles.count)"
    }
    if expectedDirs != actualDirs {
        return "目录数不符：期望 \(expectedDirs)，实际 \(actualDirs)"
    }

    let expectedByPath = Dictionary(uniqueKeysWithValues: expectedFiles.map { ($0.relativePath, $0) })
    let actualByPath = Dictionary(uniqueKeysWithValues: actualFiles.map { ($0.relativePath, $0) })

    for (path, want) in expectedByPath {
        guard let got = actualByPath[path] else { return "缺少文件：\(path)" }
        if got.size != want.size { return "\(path) 大小不符：期望 \(want.size)，实际 \(got.size)" }
        if got.digest != want.digest { return "\(path) 内容校验和不符" }
    }
    for path in actualByPath.keys where expectedByPath[path] == nil {
        return "多出文件：\(path)"
    }
    return nil
}

// MARK: - Running

struct CaseResult {
    let label: String
    let passed: Bool
    let seconds: Double
    let archiveBytes: Int64
    let note: String
}

let fileManager = FileManager.default
try? fileManager.createDirectory(at: workRoot, withIntermediateDirectories: true)

let scratch = workRoot.appendingPathComponent("scratch", isDirectory: true)
let archiveDirectory = scratch.appendingPathComponent("archives", isDirectory: true)
let extractionDirectory = scratch.appendingPathComponent("extracted", isDirectory: true)
try? fileManager.removeItem(at: scratch)
try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)

let engine = ArchiveEngine(tool: try ArchiveTool.probe(toolURL))

print("Simple Unzip 穷举往返测试")
print(String(repeating: "=", count: 72))
print("引擎      : \(toolURL.path)")
print("工作目录  : \(workRoot.path)")
print("文件夹素材: \(folderSource.lastPathComponent)")
print("单文件素材: \(fileSource.lastPathComponent)")
print("用例数    : \(allCases.count)")
print(String(repeating: "=", count: 72))
fflush(stdout)

print("正在为素材建立校验和清单…")
fflush(stdout)
let folderManifest = try buildManifest(root: folderSource)
let fileManifest = try buildManifest(root: fileSource)
print("  文件夹：\(folderManifest.filter { !$0.isDirectory }.count) 个文件，" +
      "\(folderManifest.filter(\.isDirectory).count) 个目录")
print("  单文件：\(fileManifest.count) 项")
print(String(repeating: "-", count: 72))
fflush(stdout)

var results: [CaseResult] = []

func runCase(_ testCase: MatrixCase, index: Int) async -> CaseResult {
    let started = Date()
    let archive = archiveDirectory.appendingPathComponent("case-\(index).\(testCase.format.fileExtension)")
    let output = extractionDirectory.appendingPathComponent("case-\(index)", isDirectory: true)

    func finish(passed: Bool, note: String) -> CaseResult {
        let size = (try? fileManager.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)
            .flatMap { $0?.int64Value } ?? 0
        if !keepArtifacts {
            try? fileManager.removeItem(at: archive)
            try? fileManager.removeItem(at: output)
        }
        return CaseResult(
            label: testCase.label,
            passed: passed,
            seconds: Date().timeIntervalSince(started),
            archiveBytes: size,
            note: note
        )
    }

    do {
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

        // 1. Compress
        var compression = CompressionRequest(sources: [testCase.source], destination: archive)
        compression.format = testCase.format
        if let level = testCase.level { compression.level = level }
        compression.password = testCase.password
        compression.encryptFileNames = testCase.hideNames
        // Pure round trip: do not silently drop .DS_Store and friends.
        compression.excludeMacJunk = false
        try await engine.compress(compression)

        guard fileManager.fileExists(atPath: archive.path) else {
            return finish(passed: false, note: "压缩包未生成")
        }

        // 2. List
        let listing = try await engine.list(archive: archive, password: testCase.password)
        if listing.entries.isEmpty {
            return finish(passed: false, note: "列表为空")
        }

        // 3. Negative check: without the password an encrypted archive must not open.
        if testCase.password != nil {
            let probe = extractionDirectory.appendingPathComponent("probe-\(index)", isDirectory: true)
            try fileManager.createDirectory(at: probe, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: probe) }
            do {
                var wrong = ExtractionRequest(archive: archive, destination: probe)
                wrong.password = nil
                try await engine.extract(wrong)
                let produced = (try? fileManager.contentsOfDirectory(atPath: probe.path)) ?? []
                if !produced.isEmpty {
                    return finish(passed: false, note: "无密码竟然解压成功（\(produced.count) 项）")
                }
            } catch let error as ArchiveError {
                if case .cancelled = error {
                    return finish(passed: false, note: "无密码解压被误判为取消")
                }
                // Any refusal is the expected outcome.
            }
        }

        // 4. Extract with the correct credentials
        var extraction = ExtractionRequest(archive: archive, destination: output)
        extraction.password = testCase.password
        try await engine.extract(extraction)

        // 5. Verify
        let expected: [ManifestEntry]
        let producedRoot: URL
        switch testCase.sourceKind {
        case .folder:
            expected = folderManifest
            producedRoot = output.appendingPathComponent(testCase.source.lastPathComponent)
        case .singleFile:
            expected = fileManifest
            producedRoot = output
        }

        guard fileManager.fileExists(atPath: producedRoot.path) else {
            return finish(passed: false, note: "解压结果缺少 \(producedRoot.lastPathComponent)")
        }

        let actual = try buildManifest(root: producedRoot)
        if let difference = manifestDifference(expected: expected, actual: actual) {
            return finish(passed: false, note: difference)
        }

        return finish(passed: true, note: "\(actual.filter { !$0.isDirectory }.count) 文件校验一致")
    } catch {
        let described = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let firstLine = described.split(separator: "\n").first.map(String.init) ?? described
        return finish(passed: false, note: firstLine)
    }
}

for (offset, testCase) in allCases.enumerated() {
    let result = await runCase(testCase, index: offset)
    results.append(result)
    let mark = result.passed ? "✓" : "✗"
    let sizeText = result.archiveBytes > 0
        ? ByteCountFormatter.string(fromByteCount: result.archiveBytes, countStyle: .file)
        : "—"
    let line = String(
        format: "  %@ [%3d/%3d] %-28@ %6.1fs  %8@  %@",
        mark, offset + 1, allCases.count, testCase.label as NSString,
        result.seconds, sizeText as NSString, result.note as NSString
    )
    print(line)
    fflush(stdout)
}

// MARK: - Report

let passed = results.filter(\.passed).count
let failed = results.count - passed
let totalSeconds = results.reduce(0) { $0 + $1.seconds }

print(String(repeating: "=", count: 72))
print(String(format: "通过 %d ｜ 失败 %d ｜ 总用例 %d ｜ 用时 %.1f 分钟",
             passed, failed, results.count, totalSeconds / 60))

if failed > 0 {
    print("\n失败明细：")
    for result in results where !result.passed {
        print("  ✗ \(result.label)：\(result.note)")
    }
}

// Markdown report
var report = "# 穷举往返测试报告\n\n"
report += "- 引擎：`\(toolURL.path)`\n"
report += "- 素材：`\(folderSource.path)`（\(folderManifest.filter { !$0.isDirectory }.count) 文件 / "
report += "\(folderManifest.filter(\.isDirectory).count) 目录）、`\(fileSource.path)`\n"
report += "- 密码：`\(password)`\n"
report += "- 结果：**通过 \(passed) ｜ 失败 \(failed) ｜ 共 \(results.count)**，"
report += String(format: "用时 %.1f 分钟\n\n", totalSeconds / 60)
report += "| # | 用例 | 结果 | 耗时 | 压缩包 | 说明 |\n"
report += "| --- | --- | --- | --- | --- | --- |\n"
for (offset, result) in results.enumerated() {
    let sizeText = result.archiveBytes > 0
        ? ByteCountFormatter.string(fromByteCount: result.archiveBytes, countStyle: .file)
        : "—"
    report += "| \(offset + 1) | \(result.label) | \(result.passed ? "✓" : "✗") | "
    report += String(format: "%.1fs", result.seconds) + " | \(sizeText) | \(result.note) |\n"
}

let reportPath = workRoot.appendingPathComponent("report.md")
try? report.write(to: reportPath, atomically: true, encoding: .utf8)
print("\n报告已写入：\(reportPath.path)")

exit(failed == 0 ? 0 : 1)
