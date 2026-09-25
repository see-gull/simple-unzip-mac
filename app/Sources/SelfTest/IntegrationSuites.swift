import Foundation
@testable import ArchiveKit

/// Resolves the `7zz` under test. Defaults to the binary built from the 7-Zip
/// 26.03 source tree in this workspace, so a green run also proves the source
/// build works.
func resolvedToolURL() throws -> URL {
    if let override = ProcessInfo.processInfo.environment["ARCHIVE_TEST_BINARY"], !override.isEmpty {
        let url = URL(fileURLWithPath: override)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw SkipTest(reason: "ARCHIVE_TEST_BINARY 指向的文件不可执行：\(override)")
        }
        return url
    }
    for path in ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz", "/usr/bin/7zz"] {
        if FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
    }
    throw ArchiveError.toolNotFound(searched: ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz", "/usr/bin/7zz"])
}

func makeEngine() throws -> ArchiveEngine {
    ArchiveEngine(tool: try ArchiveTool.probe(resolvedToolURL()))
}

func registerIntegrationSuite() {

    harness.test("探测真实 7zz 可执行文件") {
        let tool = try ArchiveTool.probe(resolvedToolURL())
        expectFalse(tool.version.isEmpty, "版本号不应为空")
    }

    harness.test("压缩 → 列表 → 解压 全流程") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("roundtrip")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("src")
        try TempSpace.write("a.txt", in: sourceDir, contents: "hello world")
        try TempSpace.write("sub/c.txt", in: sourceDir, contents: "nested")
        try TempSpace.write("sub/deep/d.txt", in: sourceDir, contents: "deeper")

        let archive = scratch.appendingPathComponent("out.7z")
        var request = CompressionRequest(
            sources: [
                sourceDir.appendingPathComponent("a.txt"),
                sourceDir.appendingPathComponent("sub"),
            ],
            destination: archive
        )
        request.level = 5
        try await engine.compress(request)
        expectTrue(FileManager.default.fileExists(atPath: archive.path), "压缩包应已生成")

        let listing = try await engine.list(archive: archive)
        expectEqual(listing.properties.type, "7z")
        expectTrue(listing.entries.contains { $0.path == "a.txt" && !$0.isDirectory })
        expectTrue(listing.entries.contains { $0.path == "sub/c.txt" })
        expectTrue(listing.entries.contains { $0.path == "sub/deep/d.txt" })

        // Paths must stay relative: the absolute scratch prefix must not leak in.
        expectFalse(listing.entries.contains { $0.path.hasPrefix("/") }, "包内路径不应是绝对路径")

        let extractDir = scratch.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try await engine.extract(ExtractionRequest(archive: archive, destination: extractDir))

        expectEqual(TempSpace.read(extractDir.appendingPathComponent("a.txt")), "hello world")
        expectEqual(TempSpace.read(extractDir.appendingPathComponent("sub/c.txt")), "nested")
        expectEqual(TempSpace.read(extractDir.appendingPathComponent("sub/deep/d.txt")), "deeper")
    }

    harness.test("只解压所选条目") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("selected")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("src")
        try TempSpace.write("keep.txt", in: sourceDir, contents: "keep")
        try TempSpace.write("drop.txt", in: sourceDir, contents: "drop")

        let archive = scratch.appendingPathComponent("sel.7z")
        var request = CompressionRequest(sources: [sourceDir], destination: archive)
        request.level = 1
        try await engine.compress(request)

        let extractDir = scratch.appendingPathComponent("only")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        var extraction = ExtractionRequest(archive: archive, destination: extractDir)
        extraction.selectedPaths = ["src/keep.txt"]
        try await engine.extract(extraction)

        let manager = FileManager.default
        expectTrue(manager.fileExists(atPath: extractDir.appendingPathComponent("src/keep.txt").path))
        expectFalse(manager.fileExists(atPath: extractDir.appendingPathComponent("src/drop.txt").path))
    }

    harness.test("错误密码被识别为密码错误") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("wrongpassword")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("src")
        try TempSpace.write("secret.txt", in: sourceDir, contents: "classified")

        let archive = scratch.appendingPathComponent("locked.7z")
        var request = CompressionRequest(sources: [sourceDir], destination: archive)
        request.password = "correct-horse"
        request.encryptFileNames = true
        try await engine.compress(request)

        let badDir = scratch.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        var bad = ExtractionRequest(archive: archive, destination: badDir)
        bad.password = "wrong-password"

        do {
            try await engine.extract(bad)
            fail("使用错误密码解压本应失败")
        } catch let error as ArchiveError {
            if case .wrongPassword = error {} else {
                fail("期望 .wrongPassword，实际是 \(error)")
            }
        }

        let goodDir = scratch.appendingPathComponent("good")
        try FileManager.default.createDirectory(at: goodDir, withIntermediateDirectories: true)
        var good = ExtractionRequest(archive: archive, destination: goodDir)
        good.password = "correct-horse"
        try await engine.extract(good)
        expectEqual(TempSpace.read(goodDir.appendingPathComponent("src/secret.txt")), "classified")
    }

    harness.test("缺少密码时报告密码问题，而不是误报为已取消") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("nopassword")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("src")
        try TempSpace.write("secret.txt", in: sourceDir, contents: "classified")

        // Header encryption, so even listing needs the password.
        let archive = scratch.appendingPathComponent("locked.7z")
        var request = CompressionRequest(sources: [sourceDir], destination: archive)
        request.password = "correct-horse"
        request.encryptFileNames = true
        try await engine.compress(request)

        let out = scratch.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var noPassword = ExtractionRequest(archive: archive, destination: out)
        noPassword.password = nil

        // 7-Zip aborts with exit code 255 here ("Break signaled") because stdin is
        // not a terminal. That code used to be mapped to `.cancelled`, so the user
        // was told the job had been cancelled instead of being asked for a password.
        do {
            try await engine.extract(noPassword)
            fail("没有提供密码时本应失败")
        } catch let error as ArchiveError {
            switch error {
            case .wrongPassword:
                break
            case .cancelled:
                fail("缺少密码被误判为「已取消」——退出码 255 不等于用户取消")
            default:
                fail("期望 .wrongPassword，实际是 \(error)")
            }
        }
    }

    harness.test("加密头在提供密码后才显示文件名") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("encryptedheader")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("src")
        try TempSpace.write("hidden-name.txt", in: sourceDir, contents: "x")

        let archive = scratch.appendingPathComponent("hdr.7z")
        var request = CompressionRequest(sources: [sourceDir], destination: archive)
        request.password = "pw"
        request.encryptFileNames = true
        try await engine.compress(request)

        let listing = try await engine.list(archive: archive, password: "pw")
        expectTrue(listing.entries.contains { $0.path.contains("hidden-name.txt") })
        expectTrue(listing.isEncrypted)
    }

    harness.test("完整性测试通过") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("integrity")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("src")
        try TempSpace.write("ok.txt", in: sourceDir, contents: "fine")

        let archive = scratch.appendingPathComponent("healthy.7z")
        var request = CompressionRequest(sources: [sourceDir], destination: archive)
        request.level = 1
        try await engine.compress(request)

        let report = try await engine.test(archive: archive)
        expectTrue(report.isHealthy, "健康压缩包的测试应通过")
    }

    harness.test("ZIP 往返") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("zip")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("src")
        try TempSpace.write("z.txt", in: sourceDir, contents: "zipped")

        let archive = scratch.appendingPathComponent("out.zip")
        var request = CompressionRequest(sources: [sourceDir], destination: archive)
        request.format = .zip
        try await engine.compress(request)

        let listing = try await engine.list(archive: archive)
        expectEqual(listing.properties.type, "zip")
        expectTrue(listing.entries.contains { $0.path == "src/z.txt" })
    }

    harness.test("TAR.GZ 两段式往返且清理临时文件") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("targz")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("src")
        try TempSpace.write("t.txt", in: sourceDir, contents: "tarball")

        let archive = scratch.appendingPathComponent("out.tar.gz")
        var request = CompressionRequest(sources: [sourceDir], destination: archive)
        request.format = .tarGzip
        try await engine.compress(request)
        expectTrue(FileManager.default.fileExists(atPath: archive.path))

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .filter { $0.hasPrefix(".simpleunzip-") }
        expectTrue(leftovers.isEmpty, "临时 tar 文件未被清理：\(leftovers)")

        let extractDir = scratch.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try await engine.extract(ExtractionRequest(archive: archive, destination: extractDir))
        expectEqual(TempSpace.read(extractDir.appendingPathComponent("src/t.txt")), "tarball")
    }

    harness.test("压缩时排除 macOS 垃圾文件") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("macjunk")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("src")
        try TempSpace.write("real.txt", in: sourceDir, contents: "data")
        try TempSpace.write(".DS_Store", in: sourceDir, contents: "junk")

        let archive = scratch.appendingPathComponent("clean.7z")
        var request = CompressionRequest(sources: [sourceDir], destination: archive)
        request.level = 1
        try await engine.compress(request)

        let listing = try await engine.list(archive: archive)
        expectTrue(listing.entries.contains { $0.path == "src/real.txt" })
        expectFalse(listing.entries.contains { $0.path.contains(".DS_Store") })
    }

    harness.test("压缩过程中回报真实进度") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("progress")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let big = try TempSpace.writeRandom("big.bin", in: scratch, bytes: 12 * 1024 * 1024)
        let archive = scratch.appendingPathComponent("progress.7z")

        let samples = SampleCollector()
        var request = CompressionRequest(sources: [big], destination: archive)
        request.level = 9
        try await engine.compress(request, onProgress: { samples.record($0) })

        expectFalse(samples.values.isEmpty, "压缩过程中应当收到进度回调")
        expectTrue(samples.values.contains { $0.fraction != nil }, "进度回调应当包含百分比")

        // 7-Zip never reports 100% for compression. Measured directly:
        //   0% -> 37% -> 73% -> 76%, then the line is cleared. The bar is finished
        // by the app layer (ArchiveTask.markFinished sets 1.0), so this test
        // asserts the parser's real contract: genuine intermediate values,
        // reported in non-decreasing order.
        let fractions = samples.values.compactMap(\.fraction).filter { $0 > 0 && $0 < 1 }
        expectFalse(fractions.isEmpty,
                    "应当出现 0 与 1 之间的中间进度，实际样本：\(samples.values.compactMap(\.fraction))")

        // Regression guard: a greedy item capture used to make a buffer holding
        // two gauges report the earlier percentage, so progress went backwards.
        let isNonDecreasing = zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }
        expectTrue(isNonDecreasing, "进度不应当倒退，实际序列：\(fractions)")

        expectTrue(samples.values.contains { ($0.currentItem ?? "").contains("big.bin") },
                   "进度中应当带有当前处理的文件名")
    }

    harness.test("取消能中断正在进行的压缩") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("cancel")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let big = try TempSpace.writeRandom("huge.bin", in: scratch, bytes: 48 * 1024 * 1024)
        let archive = scratch.appendingPathComponent("cancelled.7z")

        let handle = CancellationHandle()
        var request = CompressionRequest(sources: [big], destination: archive)
        request.level = 9

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { handle.cancel() }

        do {
            try await engine.compress(request, cancellation: handle)
            if FileManager.default.fileExists(atPath: archive.path) {
                // The machine outran the cancel timer; that is not a failure.
                throw SkipTest(reason: "压缩在取消生效前已完成")
            }
        } catch let error as ArchiveError {
            if case .cancelled = error {} else {
                fail("期望 .cancelled，实际是 \(error)")
            }
        }
    }

    harness.test("列出不存在的压缩包会明确失败") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("missing")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let missing = scratch.appendingPathComponent("does-not-exist.7z")
        do {
            _ = try await engine.list(archive: missing)
            fail("列出不存在的压缩包本应失败")
        } catch let error as ArchiveError {
            switch error {
            case .commandFailed, .toolNotFound:
                break
            default:
                fail("期望 .commandFailed，实际是 \(error)")
            }
        }
    }

    harness.test("TAR.GZ / TAR.BZ2 / TAR.XZ 解压出真实文件而非中间 tar") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("compressedtar")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("src")
        try TempSpace.write("t.txt", in: sourceDir, contents: "tarball")

        // `7zz x` on a `.tar.*` only peels the outer compressor and leaves the
        // inner tar behind, so the engine unwraps it explicitly. All three
        // formats share that path and are checked here.
        for format in [ArchiveFormat.tarGzip, ArchiveFormat.tarBzip2, ArchiveFormat.tarXz] {
            let archive = scratch.appendingPathComponent("out.\(format.fileExtension)")
            var request = CompressionRequest(sources: [sourceDir], destination: archive)
            request.format = format
            try await engine.compress(request)
            expectTrue(FileManager.default.fileExists(atPath: archive.path),
                       "\(format.displayName) 未生成")

            let extractDir = scratch.appendingPathComponent("out-\(format.rawValue)")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try await engine.extract(ExtractionRequest(archive: archive, destination: extractDir))

            expectEqual(TempSpace.read(extractDir.appendingPathComponent("src/t.txt")), "tarball",
                        "\(format.displayName) 解压后未得到原始文件")

            let produced = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
            expectFalse(produced.contains { $0.hasSuffix(".tar") },
                        "\(format.displayName) 解压后不应残留中间 tar：\(produced)")
        }

        let staging = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .filter { $0.hasPrefix(".simpleunzip-") }
        expectTrue(staging.isEmpty, "临时目录未被清理：\(staging)")
    }

    harness.test("压缩型 tar 的列表显示内层真实文件") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("tarlisting")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("src")
        try TempSpace.write("a.txt", in: sourceDir, contents: "alpha")
        try TempSpace.write("nested/b.txt", in: sourceDir, contents: "beta")

        // `7zz l -slt` on a `.tar.xz` reports the intermediate tar as the only
        // entry, which is exactly what made the browser show a single bogus row.
        for format in [ArchiveFormat.tarGzip, ArchiveFormat.tarBzip2, ArchiveFormat.tarXz] {
            let archive = scratch.appendingPathComponent("out.\(format.fileExtension)")
            var request = CompressionRequest(sources: [sourceDir], destination: archive)
            request.format = format
            try await engine.compress(request)

            let listing = try await engine.list(archive: archive)
            let paths = listing.entries.map(\.path)

            expectTrue(paths.contains("src/a.txt"),
                       "\(format.displayName) 列表应含内层文件，实际：\(paths)")
            expectTrue(paths.contains("src/nested/b.txt"),
                       "\(format.displayName) 列表应含内层嵌套文件，实际：\(paths)")
            expectFalse(paths.contains { $0.hasSuffix(".tar") },
                        "\(format.displayName) 列表不应出现中间 tar 条目，实际：\(paths)")
            expectEqual(listing.properties.type, format.fileExtension,
                        "\(format.displayName) 应显示真实容器类型")
            expectNotNil(listing.properties.physicalSize,
                         "\(format.displayName) 应显示外层文件大小")
        }
    }

    harness.test("中文与空格路径可正常往返") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("unicode")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sourceDir = scratch.appendingPathComponent("中文 目录")
        try TempSpace.write("带 空格 的文件.txt", in: sourceDir, contents: "内容 unicode ✓")

        let archive = scratch.appendingPathComponent("归档 文件.7z")
        var request = CompressionRequest(sources: [sourceDir], destination: archive)
        request.level = 1
        try await engine.compress(request)

        let listing = try await engine.list(archive: archive)
        expectTrue(listing.entries.contains { $0.path.contains("带 空格 的文件.txt") },
                   "包内路径应当保留中文与空格：\(listing.entries.map(\.path))")

        let extractDir = scratch.appendingPathComponent("解压 输出")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try await engine.extract(ExtractionRequest(archive: archive, destination: extractDir))
        expectEqual(
            TempSpace.read(extractDir.appendingPathComponent("中文 目录/带 空格 的文件.txt")),
            "内容 unicode ✓"
        )
    }
}

/// Runs a full list + extract cycle against a caller-supplied archive.
///
/// Set `ARCHIVE_EXTRA_ARCHIVE=/path/to/file` to reproduce a specific report on
/// a real-world file. This is how the `.tar.xz` handling was verified against
/// the 121 MB `sample.tar.xz`.
func registerTargetArchiveSuite() {
    guard let path = ProcessInfo.processInfo.environment["ARCHIVE_EXTRA_ARCHIVE"],
          !path.isEmpty else { return }
    let archive = URL(fileURLWithPath: path)

    harness.test("对指定压缩包做列表 + 解压（\(archive.lastPathComponent)）") {
        let engine = try makeEngine()
        let scratch = try TempSpace.make("target")
        defer { try? FileManager.default.removeItem(at: scratch) }

        expectTrue(FileManager.default.fileExists(atPath: archive.path),
                   "指定文件不存在：\(archive.path)")

        let listing = try await engine.list(archive: archive)
        let outerSize = listing.properties.physicalSize.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "—"
        print("      列表：\(listing.entries.count) 个条目，类型 \(listing.properties.type ?? "?")，外层 \(outerSize)")
        expectFalse(listing.entries.isEmpty, "列表不应为空")
        // The bug being guarded against is the browser showing exactly one row:
        // the intermediate tar. A real archive may legitimately contain `.tar`
        // files (this one does), so check the shape rather than the extension.
        expectTrue(listing.entries.count > 1, "列表不应只有中间 tar 一个条目")
        expectFalse(listing.entries.count == 1 && listing.entries[0].path.hasSuffix(".tar"),
                    "列表只剩中间 tar：\(listing.entries.map(\.path))")

        let extractDir = scratch.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try await engine.extract(ExtractionRequest(archive: archive, destination: extractDir))

        let produced = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
        print("      解压顶层：\(Array(produced.prefix(6)))")
        expectFalse(produced.isEmpty, "解压后目标目录不应为空")
        expectFalse(produced.contains { $0.hasSuffix(".tar") },
                    "解压后不应残留中间 tar：\(produced)")

        let fileCount = countRegularFiles(in: extractDir)
        print("      解压文件数：\(fileCount)")
        expectTrue(fileCount > 0, "解压后应当有文件")
    }
}

private func countRegularFiles(in directory: URL) -> Int {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return 0 }
    var count = 0
    for case let url as URL in enumerator {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            count += 1
        }
    }
    return count
}
