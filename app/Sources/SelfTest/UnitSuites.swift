import Foundation
@testable import ArchiveKit

/// Captured verbatim from `7zz l -slt` on a real 7z archive.
let solidListingFixture = """

7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=en_US.UTF-8 Threads:8 OPEN_MAX:1048575, ASM

Scanning the drive for archives:
1 file, 200251 bytes (196 KiB)

Listing archive: test.7z

--
Path = test.7z
Type = 7z
Physical Size = 200251
Headers Size = 216
Method = LZMA2:18
Solid = +
Blocks = 1

----------
Path = src
Size = 0
Packed Size = 0
Modified = 2026-09-24 23:24:58.2549524
Attributes = D drwxr-xr-x
CRC = 
Encrypted = -
Method = 
Block = 

Path = src/sub
Size = 0
Packed Size = 0
Modified = 2026-09-24 23:24:58.2583541
Attributes = D drwxr-xr-x
CRC = 
Encrypted = -
Method = 
Block = 

Path = src/a.txt
Size = 12
Packed Size = 200035
Modified = 2026-09-24 23:24:58.2545411
Attributes = A -rw-r--r--
CRC = AF083B2D
Encrypted = -
Method = LZMA2:18
Block = 0

Path = src/big.bin
Size = 200000
Packed Size = 
Modified = 2026-09-24 23:24:58.2580250
Attributes = A -rw-r--r--
CRC = DBEF92FE
Encrypted = -
Method = LZMA2:18
Block = 0

Path = src/sub/c.txt
Size = 7
Packed Size = 
Modified = 2026-09-24 23:24:58.2584303
Attributes = A -rw-r--r--
CRC = EBAB958D
Encrypted = -
Method = LZMA2:18
Block = 0

"""

func registerListingSuite() {
    harness.test("解析 -slt 头部属性") {
        let listing = ArchiveListing.parse(solidListingFixture)
        expectEqual(listing.properties.type, "7z")
        expectEqual(listing.properties.physicalSize, 200251)
        expectEqual(listing.properties.headersSize, 216)
        expectEqual(listing.properties.method, "LZMA2:18")
        expectTrue(listing.properties.isSolid)
        expectEqual(listing.properties.blockCount, 1)
    }

    harness.test("解析全部条目并保持顺序") {
        let listing = ArchiveListing.parse(solidListingFixture)
        expectEqual(listing.entries.count, 5)
        expectEqual(listing.entries.map(\.path),
                    ["src", "src/sub", "src/a.txt", "src/big.bin", "src/sub/c.txt"])
    }

    harness.test("区分目录与文件") {
        let listing = ArchiveListing.parse(solidListingFixture)
        expectEqual(listing.entries.filter(\.isDirectory).map(\.path), ["src", "src/sub"])
        expectEqual(listing.folderCount, 2)
        expectEqual(listing.fileCount, 3)
    }

    harness.test("读取大小与校验和") {
        let listing = ArchiveListing.parse(solidListingFixture)
        let entry = listing.entries.first { $0.path == "src/a.txt" }
        expectEqual(entry?.size, 12)
        expectEqual(entry?.packedSize, 200035)
        expectEqual(entry?.crc, "AF083B2D")
        expectEqual(entry?.name, "a.txt")
        expectEqual(entry?.parentPath, "src")

        // Inside a solid block 7-Zip omits the per-file packed size.
        expectNil(listing.entries.first { $0.path == "src/big.bin" }?.packedSize)
    }

    harness.test("汇总未压缩总大小") {
        expectEqual(ArchiveListing.parse(solidListingFixture).totalUncompressedSize, 200019)
    }

    harness.test("解析七位小数的时间戳") {
        let date = try require(ArchiveListing.parseTimestamp("2026-09-24 23:24:58.2549524"))
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        expectEqual(components.year, 2026)
        expectEqual(components.month, 9)
        expectEqual(components.day, 24)
        expectEqual(components.hour, 23)
        expectEqual(components.minute, 24)
        expectEqual(components.second, 58)
    }

    harness.test("时间戳缺失或非法时返回 nil") {
        expectNotNil(ArchiveListing.parseTimestamp("2026-09-24 23:24:58"))
        expectNotNil(ArchiveListing.parseTimestamp("2026-09-24"))
        expectNil(ArchiveListing.parseTimestamp(""))
        expectNil(ArchiveListing.parseTimestamp(nil))
        expectNil(ArchiveListing.parseTimestamp("not a date"))
    }

    harness.test("从 Method 字段识别加密") {
        let encrypted = solidListingFixture.replacingOccurrences(
            of: "Method = LZMA2:18\nSolid = +",
            with: "Method = LZMA2:18 7zAES\nSolid = +"
        )
        expectTrue(ArchiveListing.parse(encrypted).isEncrypted)
        expectFalse(ArchiveListing.parse(solidListingFixture).isEncrypted)
    }

    harness.test("缺少空行时仍能以 Path 切分记录") {
        let text = """
        ----------
        Path = a.txt
        Size = 1
        Path = b.txt
        Size = 2
        """
        expectEqual(ArchiveListing.parse(text).entries.map(\.path), ["a.txt", "b.txt"])
    }

    harness.test("空输出得到空列表") {
        expectTrue(ArchiveListing.parse("").entries.isEmpty)
    }
}

func registerTreeSuite() {
    func listing(_ paths: [String]) -> ArchiveListing {
        let entries = paths.map {
            ArchiveEntry(path: $0, size: 10, packedSize: nil, modified: nil, attributes: "",
                         crc: nil, method: nil, isDirectory: $0.hasSuffix("/"), isEncrypted: false)
        }
        return ArchiveListing(entries: entries, properties: ArchiveProperties())
    }

    harness.test("构建嵌套树且文件夹优先排序") {
        let tree = ArchiveTreeBuilder.build(from: listing(["b.txt", "sub/", "sub/a.txt", "a.txt"]))
        expectEqual(tree.map(\.name), ["sub", "a.txt", "b.txt"])
        expectEqual(tree[0].children.map(\.name), ["a.txt"])
    }

    harness.test("自动补全缺失的中间目录") {
        let tree = ArchiveTreeBuilder.build(from: listing(["deep/nested/file.txt"]))
        expectEqual(tree.count, 1)
        expectEqual(tree[0].name, "deep")
        expectTrue(tree[0].isDirectory)
        expectEqual(tree[0].children.first?.name, "nested")
        expectEqual(tree[0].children.first?.children.first?.name, "file.txt")
    }

    harness.test("聚合子树大小") {
        let tree = ArchiveTreeBuilder.build(from: listing(["sub/a.txt", "sub/b.txt"]))
        expectEqual(tree[0].aggregateSize, 20)
    }
}

func registerParserSuite() {
    /// The exact shape `7zz -bsp1` writes to a pipe: a gauge rewritten in place
    /// with backspaces, with no line terminator at all.
    func gauge(_ percent: Int, count: Int, name: String) -> String {
        let text = " \(percent)% \(count) + \(name)"
        return text + String(repeating: "\u{8}", count: text.count)
            + String(repeating: " ", count: text.count)
            + String(repeating: "\u{8}", count: text.count)
    }

    harness.test("读取百分比、计数与当前文件") {
        let parser = ArchiveOutputParser()
        let samples = SampleCollector()
        parser.onProgress = { samples.record($0) }

        parser.feed(gauge(15, count: 40, name: "big/rand.bin"))
        parser.feed(gauge(21, count: 40, name: "big/rand.bin"))

        let last = try require(samples.values.last)
        expectEqual(last.fraction ?? 0, 0.21, accuracy: 0.0001)
        expectEqual(last.itemCount, 40)
        expectEqual(last.currentItem, "big/rand.bin")
    }

    harness.test("同一块中的多个进度只取最新") {
        let parser = ArchiveOutputParser()
        let samples = SampleCollector()
        parser.onProgress = { samples.record($0) }

        parser.feed(gauge(15, count: 40, name: "a.bin")
            + gauge(63, count: 40, name: "b.bin")
            + gauge(99, count: 40, name: "c.bin"))

        let last = try require(samples.values.last)
        expectEqual(last.fraction ?? 0, 0.99, accuracy: 0.0001)
        expectEqual(last.currentItem, "c.bin")
    }

    harness.test("百分比被限制在 0...1") {
        let parser = ArchiveOutputParser()
        expectEqual(parser.extractLastProgress(from: "100% 5 + x")?.fraction, 1.0)
        expectNil(parser.extractLastProgress(from: "没有进度信息"))
    }

    harness.test("把日志行与进度噪音分开") {
        let parser = ArchiveOutputParser()
        let messages = LineCollector()
        let errors = LineCollector()
        parser.onMessage = { messages.record($0) }
        parser.onError = { errors.record($0) }

        parser.feed("Extracting archive: test.7z\n")
        parser.feed(gauge(50, count: 3, name: "a.txt"))
        parser.feed("\nERROR: Data Error in encrypted file. Wrong password? : a.txt\n")
        parser.finish()

        expectTrue(messages.values.contains("Extracting archive: test.7z"))
        expectTrue(errors.values.contains { $0.contains("Wrong password") })
        expectTrue(parser.hadErrors)
    }

    harness.test("识别完成标记") {
        let parser = ArchiveOutputParser()
        parser.feed("Everything is Ok\n")
        expectTrue(parser.sawCompletionMarker)
    }

    harness.test("清理退格与回车") {
        expectEqual(ArchiveOutputParser.clean("\u{8}\u{8} 42% done\r"), "42% done")
        expectEqual(ArchiveOutputParser.clean("   \u{8}  "), "")
    }

    harness.test("进度被拆到两次读取时不产生错误值") {
        let parser = ArchiveOutputParser()
        let samples = SampleCollector()
        parser.onProgress = { samples.record($0) }

        parser.feed(" 7")
        parser.feed("5% 12 + partial.bin")

        let last = try require(samples.values.last)
        expectEqual(last.fraction ?? 0, 0.75, accuracy: 0.0001)
        expectEqual(last.currentItem, "partial.bin")
    }

    harness.test("保留原始输出以供列表解析") {
        let parser = ArchiveOutputParser()
        parser.feed("Path = a.txt\nSize = 1\n")
        expectTrue(parser.rawOutput.contains("Path = a.txt"))
    }

    harness.test("待处理缓冲区不会无限增长") {
        let parser = ArchiveOutputParser()
        for _ in 0..<40 {
            parser.feed(String(repeating: "x", count: 1000))
        }
        expectTrue(ArchiveListing.parse(parser.rawOutput).entries.isEmpty)
    }
}

func registerDecoderSuite() {
    harness.test("跨读取重组多字节字符") {
        let decoder = UTF8StreamDecoder()
        let data = Data("压缩".utf8)
        let first = decoder.decode(data.prefix(4))
        let second = decoder.decode(data.suffix(from: 4))
        expectEqual(first + second, "压缩")
    }

    harness.test("解码纯 ASCII") {
        expectEqual(UTF8StreamDecoder().decode(Data("hello".utf8)), "hello")
    }

    harness.test("flush 释放不完整的尾部") {
        let decoder = UTF8StreamDecoder()
        _ = decoder.decode(Data("压缩".utf8).prefix(2))
        expectFalse(decoder.flush().isEmpty)
    }
}

func registerToolSuite() {
    harness.test("从横幅解析版本号") {
        let banner = "\n7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03\n 64-bit arm_v:8.5-A"
        expectEqual(ArchiveTool.parseVersion(fromBanner: banner), "26.03")
        expectEqual(ArchiveTool.parseVersion(fromBanner: "7-Zip (z) 9.20.1 (x64)"), "9.20.1")
        expectNil(ArchiveTool.parseVersion(fromBanner: "not seven zip"))
    }
}

func registerCommandSuite() {
    harness.test("同目录文件的公共父目录") {
        let base = URL(fileURLWithPath: "/tmp/x/base")
        let urls = [base.appendingPathComponent("a.txt"), base.appendingPathComponent("sub/c.txt")]
        expectEqual(ArchiveEngine.commonAncestor(of: urls).path, "/tmp/x/base")
    }

    harness.test("跨目录文件的公共祖先") {
        let urls = [
            URL(fileURLWithPath: "/tmp/x/one/a.txt"),
            URL(fileURLWithPath: "/tmp/x/two/b.txt"),
        ]
        expectEqual(ArchiveEngine.commonAncestor(of: urls).path, "/tmp/x")
    }

    harness.test("单个文件的公共父目录是其所在目录") {
        let urls = [URL(fileURLWithPath: "/tmp/x/one/a.txt")]
        expectEqual(ArchiveEngine.commonAncestor(of: urls).path, "/tmp/x/one")
    }

    harness.test("macOS 垃圾文件排除开关") {
        expectTrue(ArchiveEngine.macJunkExclusions(enabled: true).contains("-xr!.DS_Store"))
        expectTrue(ArchiveEngine.macJunkExclusions(enabled: false).isEmpty)
    }

    harness.test("格式能力表") {
        expectTrue(ArchiveFormat.sevenZip.supportsEncryption)
        expectTrue(ArchiveFormat.zip.supportsEncryption)
        expectFalse(ArchiveFormat.tar.supportsEncryption)
        expectTrue(ArchiveFormat.tarGzip.requiresTarStage)
        expectFalse(ArchiveFormat.sevenZip.requiresTarStage)
        expectEqual(ArchiveFormat.tarGzip.sevenZipTypeName, "gzip")
    }

    harness.test("覆盖模式开关") {
        expectEqual(OverwriteMode.overwrite.switchValue, "-aoa")
        expectEqual(OverwriteMode.skip.switchValue, "-aos")
    }
}

func registerCancellationSuite() {
    harness.test("取消会执行已挂载的动作") {
        let handle = CancellationHandle()
        var fired = false
        handle.attach { fired = true }
        handle.cancel()
        expectTrue(fired)
    }

    harness.test("先取消后挂载仍会立即执行") {
        let handle = CancellationHandle()
        handle.cancel()
        var fired = false
        handle.attach { fired = true }
        expectTrue(fired)
        expectTrue(handle.isCancelled)
    }

    harness.test("卸载后取消不再触发") {
        let handle = CancellationHandle()
        var fired = false
        handle.attach { fired = true }
        handle.detach()
        handle.cancel()
        expectFalse(fired)
    }
}
