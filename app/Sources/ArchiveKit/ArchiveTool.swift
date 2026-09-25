import Foundation

/// A located, verified `7zz` executable plus its reported version.
public struct ArchiveTool: Equatable {
    public let executableURL: URL
    public let version: String

    public init(executableURL: URL, version: String) {
        self.executableURL = executableURL
        self.version = version
    }

    /// Environment variable that overrides discovery. Useful for development.
    public static let overrideEnvironmentKey = "ARCHIVE_BINARY"

    /// Name of the helper copied into `Contents/Resources` of the app bundle.
    public static let bundledHelperName = "7zz"

    /// Every location discovery considers, in priority order, for diagnostics.
    public static func searchPaths(bundle: Bundle = .main) -> [URL] {
        var urls: [URL] = []
        if let override = ProcessInfo.processInfo.environment[overrideEnvironmentKey],
           !override.isEmpty {
            urls.append(URL(fileURLWithPath: override))
        }
        if let resource = bundle.resourceURL {
            urls.append(resource.appendingPathComponent(bundledHelperName))
        }
        // `Bundle.main.resourceURL` is nil for a bare executable run out of
        // `.build/debug`; look beside the binary as well.
        if let executable = bundle.executableURL {
            urls.append(executable.deletingLastPathComponent().appendingPathComponent(bundledHelperName))
        }
        urls.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/7zz"),
            URL(fileURLWithPath: "/usr/local/bin/7zz"),
            URL(fileURLWithPath: "/opt/local/bin/7zz"),
            URL(fileURLWithPath: "/usr/bin/7zz"),
        ])
        return urls
    }

    /// Finds the first runnable `7zz` and reads its version banner.
    public static func locate(bundle: Bundle = .main) throws -> ArchiveTool {
        let candidates = searchPaths(bundle: bundle)
        for url in candidates {
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            if let tool = try? probe(url) {
                return tool
            }
        }
        throw ArchiveError.toolNotFound(searched: candidates.map(\.path))
    }

    /// Runs the binary with no arguments and parses the banner line, e.g.
    /// `7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov`.
    public static func probe(_ url: URL) throws -> ArchiveTool {
        let process = Process()
        process.executableURL = url
        process.arguments = []
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ArchiveError.launchFailed(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let version = parseVersion(fromBanner: text) else {
            throw ArchiveError.parseFailed("无法从 7zz 输出识别版本号：\(text.prefix(120))")
        }
        return ArchiveTool(executableURL: url, version: version)
    }

    /// Extracts the version token from a banner, e.g. `26.03`.
    public static func parseVersion(fromBanner text: String) -> String? {
        guard let range = text.range(of: #"7-Zip.*?\s(\d+\.\d+(?:\.\d+)?)"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(text[range])
        guard let versionRange = matched.range(of: #"\d+\.\d+(?:\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        return String(matched[versionRange])
    }
}
