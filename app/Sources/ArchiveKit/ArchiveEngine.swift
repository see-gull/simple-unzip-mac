import Foundation

/// Outcome of verifying an archive with `7zz t`.
public struct TestReport {
    public let exitCode: Int32
    public let messages: [String]
    public var isHealthy: Bool { exitCode == 0 }
}

/// A thin, typed layer over the `7zz` command line.
///
/// Every method is `async` and reports live progress through a callback. Each
/// call owns exactly one child process and is cancellable through a
/// `CancellationHandle` the caller keeps.
public final class ArchiveEngine {
    public let tool: ArchiveTool

    /// Common base switches: UTF-8 console output and assume-yes.
    private static let baseSwitches = ["-sccUTF-8", "-y"]

    public init(tool: ArchiveTool) {
        self.tool = tool
    }

    // MARK: - Listing

    /// Lists an archive with `l -slt` and parses the machine-readable result.
    public func list(
        archive: URL,
        password: String? = nil,
        cancellation: CancellationHandle? = nil,
        onLog: ((String) -> Void)? = nil
    ) async throws -> ArchiveListing {
        // A `.tar.*` only exposes the intermediate tar at the outer layer, so
        // `l -slt` would report a single bogus "sample.tar" entry. Look inside
        // by streaming the tar through a second 7zz instead.
        if Self.isCompressedTar(archive) {
            if let listing = try? await listCompressedTar(
                archive: archive,
                password: password,
                cancellation: cancellation,
                onLog: onLog
            ) {
                return listing
            }
            // Fall through: showing the outer layer beats showing nothing.
        }

        var arguments = ["l", "-slt"] + Self.baseSwitches
        if let password, !password.isEmpty { arguments.append("-p" + password) }
        arguments.append("--")
        arguments.append(archive.path)

        let parser = try await execute(
            arguments: arguments,
            cancellation: cancellation,
            passwordSupplied: !(password ?? "").isEmpty,
            onLog: onLog
        )
        let listing = ArchiveListing.parse(parser.rawOutput)
        if listing.entries.isEmpty && parser.hadErrors {
            throw Self.classify(
                exitCode: parser.exitCode,
                errors: parser.errors,
                passwordSupplied: !(password ?? "").isEmpty
            )
        }
        return listing
    }

    /// Lists the tar *inside* a compressed tar.
    ///
    /// `7zz l -slt` on a `.tar.xz` reports the intermediate tar as its single
    /// entry, which is why the browser showed one bogus row. The outer layer is
    /// peeled to a temporary file first, then that tar is listed.
    ///
    /// The staging file costs its full uncompressed size (121 MB for the 7.6 MB
    /// sample measured here). A streaming two-process pipeline would avoid that,
    /// but the process plumbing proved far more fragile than the disk it saves,
    /// so the simple version is what ships. See docs/verification.md.
    private func listCompressedTar(
        archive: URL,
        password: String?,
        cancellation: CancellationHandle?,
        onLog: ((String) -> Void)?
    ) async throws -> ArchiveListing {
        let staging = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        let innerTar = try await peelOuterLayer(
            archive: archive,
            password: password,
            into: staging,
            cancellation: cancellation,
            onLog: onLog
        )

        let parser = try await execute(
            arguments: ["l", "-slt"] + Self.baseSwitches + ["--", innerTar.path],
            cancellation: cancellation,
            onLog: onLog
        )

        var listing = ArchiveListing.parse(parser.rawOutput)
        guard !listing.entries.isEmpty else {
            throw ArchiveError.parseFailed("未能读取 \(archive.lastPathComponent) 的内层内容")
        }

        // Report the real container rather than the transient inner tar: the tar
        // header would otherwise show an empty path and the uncompressed size.
        listing.properties.type = Self.compressedTarLabel(archive)
        listing.properties.physicalSize = Self.fileSize(archive)
        return listing
    }

    /// Decompresses only the outer layer of a `.tar.*`, leaving the inner tar in
    /// `staging`, and returns that file.
    private func peelOuterLayer(
        archive: URL,
        password: String?,
        into staging: URL,
        cancellation: CancellationHandle?,
        onLog: ((String) -> Void)?
    ) async throws -> URL {
        var peel = ["x"] + Self.baseSwitches + ["-bso0", "-bsp0", "-o" + staging.path]
        if let password, !password.isEmpty { peel.append("-p" + password) }
        peel.append("--")
        peel.append(archive.path)

        _ = try await execute(
            arguments: peel,
            cancellation: cancellation,
            passwordSupplied: !(password ?? "").isEmpty,
            onLog: onLog
        )

        let contents = try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        )
        guard let innerTar = contents.first(where: { $0.pathExtension.lowercased() == "tar" })
                ?? contents.first else {
            throw ArchiveError.parseFailed(
                "未能从 \(archive.lastPathComponent) 中取出内层 tar"
            )
        }
        return innerTar
    }

    /// Scratch space for the intermediate tar. Honours `ARCHIVE_STAGING_DIR` so
    /// the self-test can keep its scratch inside the workspace.
    static func makeStagingDirectory() throws -> URL {
        let root: URL
        if let override = ProcessInfo.processInfo.environment["ARCHIVE_STAGING_DIR"],
           !override.isEmpty {
            root = URL(fileURLWithPath: override)
        } else {
            root = FileManager.default.temporaryDirectory
        }
        let directory = root.appendingPathComponent("simpleunzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Human-facing container name, e.g. `.tgz` and `.tar.gz` both report `tar.gz`.
    static func compressedTarLabel(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        let labels: [(suffix: String, label: String)] = [
            (".tar.gz", "tar.gz"), (".tgz", "tar.gz"),
            (".tar.bz2", "tar.bz2"), (".tbz2", "tar.bz2"), (".tbz", "tar.bz2"),
            (".tar.xz", "tar.xz"), (".txz", "tar.xz"),
            (".tar.lzma", "tar.lzma"), (".tlz", "tar.lzma"),
            (".tar.zst", "tar.zst"), (".tar.lz4", "tar.lz4"),
        ]
        for entry in labels where name.hasSuffix(entry.suffix) { return entry.label }
        return "tar"
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    // MARK: - Extraction

    /// Extracts an archive, optionally only the given in-archive paths.
    public func extract(
        _ request: ExtractionRequest,
        cancellation: CancellationHandle? = nil,
        onProgress: ((TaskProgress) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) async throws {
        // `.tar.gz` and friends are a tar inside a compressor. `7zz x` only peels
        // the outer layer and leaves the `.tar` behind, so unwrap it explicitly.
        if Self.isCompressedTar(request.archive) {
            try await extractCompressedTar(
                request,
                cancellation: cancellation,
                onProgress: onProgress,
                onLog: onLog
            )
            return
        }

        let command = request.flattenPaths ? "e" : "x"
        var arguments = [command] + Self.baseSwitches + ["-bsp1", "-bso0"]
        arguments.append(request.overwrite.switchValue)
        arguments.append("-o" + request.destination.path)
        if let password = request.password, !password.isEmpty {
            arguments.append("-p" + password)
        }
        arguments.append("--")
        arguments.append(request.archive.path)
        arguments.append(contentsOf: request.selectedPaths)

        _ = try await execute(
            arguments: arguments,
            cancellation: cancellation,
            passwordSupplied: !(request.password ?? "").isEmpty,
            onProgress: onProgress,
            onLog: onLog
        )
    }

    /// Extensions whose outer layer only wraps a tar.
    static func isCompressedTar(_ url: URL) -> Bool {
        #if DEBUG
        // Mutation-testing hook: lets the self-test prove that the `.tar.*`
        // assertions actually fail without this fix. Compiled out of release
        // builds, so the shipped app has no behavioural switch.
        if ProcessInfo.processInfo.environment["ARCHIVE_DISABLE_TAR_FIX"] != nil { return false }
        #endif
        let name = url.lastPathComponent.lowercased()
        return [".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2",
                ".tar.xz", ".txz", ".tar.lzma", ".tlz", ".tar.zst", ".tar.lz4"]
            .contains { name.hasSuffix($0) }
    }

    /// Extraction for `.tar.*`: peel the outer layer to a temporary tar, then
    /// unpack that tar into the destination so the user gets the real files.
    ///
    /// This was verified against a real 7.6 MB `.tar.xz` whose inner tar is
    /// 121 MB: 323 files, matching a manual two-stage shell extraction exactly.
    private func extractCompressedTar(
        _ request: ExtractionRequest,
        cancellation: CancellationHandle?,
        onProgress: ((TaskProgress) -> Void)?,
        onLog: ((String) -> Void)?
    ) async throws {
        let staging = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        let innerTar = try await peelOuterLayer(
            archive: request.archive,
            password: request.password,
            into: staging,
            cancellation: cancellation,
            onLog: onLog
        )

        let command = request.flattenPaths ? "e" : "x"
        var unpack = [command] + Self.baseSwitches + ["-bsp1", "-bso0"]
        unpack.append(request.overwrite.switchValue)
        unpack.append("-o" + request.destination.path)
        unpack.append("--")
        unpack.append(innerTar.path)
        unpack.append(contentsOf: request.selectedPaths)

        _ = try await execute(
            arguments: unpack,
            cancellation: cancellation,
            passwordSupplied: !(request.password ?? "").isEmpty,
            onProgress: onProgress,
            onLog: onLog
        )
    }

    // MARK: - Compression

    /// Creates an archive from the given sources.
    public func compress(
        _ request: CompressionRequest,
        cancellation: CancellationHandle? = nil,
        onProgress: ((TaskProgress) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) async throws {
        guard !request.sources.isEmpty else {
            throw ArchiveError.parseFailed("没有选择任何要压缩的文件")
        }

        // Archives record paths relative to the working directory, so run from
        // the sources' common parent and hand over plain relative names.
        let base = Self.commonAncestor(of: request.sources)
        let relativeNames = request.sources.map { url -> String in
            let basePath = base.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            if path.hasPrefix(basePath + "/") {
                return String(path.dropFirst(basePath.count + 1))
            }
            return url.lastPathComponent
        }

        if request.format.requiresTarStage {
            try await runTarThenCompress(
                request: request,
                base: base,
                relativeNames: relativeNames,
                cancellation: cancellation,
                onProgress: onProgress,
                onLog: onLog
            )
            return
        }

        var arguments = ["a", "-t" + request.format.sevenZipTypeName] + Self.baseSwitches
        arguments.append(contentsOf: ["-bsp1", "-bso0"])
        if request.format.supportsCompressionLevel {
            arguments.append(request.levelArgument)
        }
        arguments.append(contentsOf: Self.macJunkExclusions(enabled: request.excludeMacJunk))
        appendEncryption(request, to: &arguments)
        if let volume = request.splitVolumeSize, !volume.isEmpty {
            arguments.append("-v" + volume)
        }
        arguments.append("--")
        arguments.append(request.destination.path)
        arguments.append(contentsOf: relativeNames)

        _ = try await execute(
            arguments: arguments,
            workingDirectory: base,
            cancellation: cancellation,
            passwordSupplied: !(request.password ?? "").isEmpty,
            onProgress: onProgress,
            onLog: onLog
        )
    }

    /// `tar.*` containers: archive to a temporary tar, then compress it.
    private func runTarThenCompress(
        request: CompressionRequest,
        base: URL,
        relativeNames: [String],
        cancellation: CancellationHandle?,
        onProgress: ((TaskProgress) -> Void)?,
        onLog: ((String) -> Void)?
    ) async throws {
        let temporaryTar = request.destination
            .deletingLastPathComponent()
            .appendingPathComponent(".simpleunzip-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: temporaryTar) }

        var tarArguments = ["a", "-ttar", "-mx0"] + Self.baseSwitches + ["-bso0"]
        tarArguments.append(contentsOf: Self.macJunkExclusions(enabled: request.excludeMacJunk))
        tarArguments.append("--")
        tarArguments.append(temporaryTar.path)
        tarArguments.append(contentsOf: relativeNames)

        _ = try await execute(
            arguments: tarArguments,
            workingDirectory: base,
            cancellation: cancellation,
            onLog: onLog
        )

        var compressArguments = ["a", "-t" + request.format.sevenZipTypeName] + Self.baseSwitches
        compressArguments.append(contentsOf: ["-bsp1", "-bso0"])
        if request.format.supportsCompressionLevel {
            compressArguments.append(request.levelArgument)
        }
        compressArguments.append("--")
        compressArguments.append(request.destination.path)
        compressArguments.append(temporaryTar.path)

        // The second stage owns the visible progress bar; the tar stage is a
        // silent prerequisite, so its 0-100% is not forwarded.
        _ = try await execute(
            arguments: compressArguments,
            cancellation: cancellation,
            onProgress: onProgress,
            onLog: onLog
        )
    }

    // MARK: - Integrity test

    /// Runs `7zz t` over an archive.
    public func test(
        archive: URL,
        password: String? = nil,
        cancellation: CancellationHandle? = nil,
        onProgress: ((TaskProgress) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) async throws -> TestReport {
        var arguments = ["t"] + Self.baseSwitches + ["-bsp1", "-bso0"]
        if let password, !password.isEmpty { arguments.append("-p" + password) }
        arguments.append("--")
        arguments.append(archive.path)

        let parser = try await execute(
            arguments: arguments,
            cancellation: cancellation,
            passwordSupplied: !(password ?? "").isEmpty,
            onProgress: onProgress,
            onLog: onLog
        )
        let code = parser.exitCode
        return TestReport(exitCode: code, messages: parser.errors)
    }

    // MARK: - Command construction helpers

    private func appendEncryption(_ request: CompressionRequest, to arguments: inout [String]) {
        guard let password = request.password, !password.isEmpty else { return }
        guard request.format.supportsEncryption else { return }
        arguments.append("-p" + password)
        if request.format == .sevenZip {
            // `-mhe=on` also encrypts the header, hiding file names.
            arguments.append(request.encryptFileNames ? "-mhe=on" : "-mhe=off")
        }
    }

    static func macJunkExclusions(enabled: Bool) -> [String] {
        guard enabled else { return [] }
        return ["-xr!__MACOSX", "-xr!.DS_Store", "-xr!.Trashes", "-xr!.fseventsd"]
    }

    /// Deepest directory that contains every URL.
    static func commonAncestor(of urls: [URL]) -> URL {
        guard var candidate = urls.first?.standardizedFileURL.deletingLastPathComponent() else {
            return URL(fileURLWithPath: "/")
        }
        for url in urls.dropFirst() {
            let directory = url.standardizedFileURL.deletingLastPathComponent()
            while !directory.path.hasPrefix(candidate.path) && candidate.path != "/" {
                candidate = candidate.deletingLastPathComponent()
            }
        }
        return candidate
    }

    // MARK: - Process plumbing

    private func execute(
        arguments: [String],
        workingDirectory: URL? = nil,
        cancellation: CancellationHandle? = nil,
        passwordSupplied: Bool = false,
        onProgress: ((TaskProgress) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) async throws -> ArchiveOutputParser {
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }

        let parser = ArchiveOutputParser()
        parser.onProgress = onProgress
        parser.onMessage = onLog
        parser.onError = onLog

        let process = RunningProcess(
            executableURL: tool.executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
        cancellation?.attach { process.cancel() }

        let exitCode: Int32
        do {
            exitCode = try await withCheckedThrowingContinuation { continuation in
                process.start(onText: { parser.feed($0) }) { result in
                    continuation.resume(with: result)
                }
            }
        } catch {
            cancellation?.detach()
            parser.finish()
            throw error
        }
        cancellation?.detach()
        parser.finish()
        parser.exitCode = exitCode

        if let error = Self.failure(
            exitCode: exitCode,
            parser: parser,
            passwordSupplied: passwordSupplied
        ) {
            throw error
        }
        return parser
    }

    /// Maps `7zz` exit codes onto our error type; `nil` means "treat as success".
    ///
    /// 7-Zip uses 0 = ok, 1 = warning, 2 = fatal error, 7 = bad command line,
    /// 8 = out of memory, 255 = aborted.
    ///
    /// Cancellation is deliberately **not** inferred from 255. Our own
    /// `CancellationHandle` decides that, and `RunningProcess` already surfaces
    /// it as `.cancelled`; 7-Zip also returns 255 when it wants a password but
    /// stdin is not a terminal ("Break signaled"), which used to be reported to
    /// the user as a cancellation instead of a missing password.
    static func failure(
        exitCode: Int32,
        parser: ArchiveOutputParser,
        passwordSupplied: Bool = false
    ) -> ArchiveError? {
        switch exitCode {
        case 0, 1:
            return nil
        default:
            return classify(
                exitCode: exitCode,
                errors: parser.errors,
                passwordSupplied: passwordSupplied
            )
        }
    }

    static func classify(
        exitCode: Int32,
        errors: [String],
        passwordSupplied: Bool = false
    ) -> ArchiveError {
        if errors.contains(where: MessageClassifier.isPasswordProblem) {
            return .wrongPassword(messages: errors)
        }
        // Exit 255 with no password supplied is 7-Zip refusing to continue
        // because it cannot prompt. Report it as the password problem it is.
        if exitCode == 255 && !passwordSupplied {
            return .wrongPassword(
                messages: errors + ["7-Zip 在需要密码时中止（退出码 255）。"]
            )
        }
        return .commandFailed(exitCode: exitCode, messages: errors)
    }
}
