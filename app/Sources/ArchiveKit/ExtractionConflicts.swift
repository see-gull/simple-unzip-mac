import Foundation

/// One archive item that extraction would write on top of something that is
/// already on disk.
public struct ExtractionConflict: Hashable, Identifiable, Sendable {
    /// Path of the item inside the archive, e.g. `src/a.txt`.
    public let entryPath: String
    /// Absolute path the item would be written to.
    public let destinationPath: String
    /// Whether the archive item is a folder.
    public let entryIsDirectory: Bool
    /// Whether what already sits at the destination is a folder.
    ///
    /// `false` also covers a file or a symbolic link, including the case of an
    /// archive folder whose name is taken by an existing file.
    public let existingIsDirectory: Bool

    public init(
        entryPath: String,
        destinationPath: String,
        entryIsDirectory: Bool,
        existingIsDirectory: Bool
    ) {
        self.entryPath = entryPath
        self.destinationPath = destinationPath
        self.entryIsDirectory = entryIsDirectory
        self.existingIsDirectory = existingIsDirectory
    }

    public var id: String { destinationPath }
}

/// Screens an extraction against its destination *before* `7zz` runs.
///
/// 7-Zip replaces a same-named file without asking (`-aoa`), so the only thing
/// standing between the user and a replaced file is a check that runs before
/// the process starts. Compression already asks about an existing archive;
/// this is what lets extraction ask about the files inside one.
public enum ExtractionConflictScanner {
    /// Everything the extraction would replace, in archive order and without
    /// duplicates.
    ///
    /// Returns an empty array when the destination folder does not exist yet —
    /// the common case, and the one that has to stay cheap for a large
    /// archive: nothing can collide inside a folder that is not there.
    public static func conflicts(
        listing: ArchiveListing,
        request: ExtractionRequest,
        fileManager: FileManager = .default
    ) -> [ExtractionConflict] {
        // `/tmp` is itself a symlink on macOS, so the destination has to be
        // resolved before asking what kind of thing it is.
        let destination = request.destination.standardizedFileURL.resolvingSymlinksInPath()
        guard isDirectoryLike(destination, fileManager: fileManager) else {
            return []
        }

        let selection = request.selectedPaths.compactMap(normalizedPath)

        // Each intermediate folder is stat'ed once: an archive with 50k
        // entries usually touches a few hundred folders, so the expensive
        // "does this parent exist" question is asked per folder, not per file.
        var descendableDirectories: [String: Bool] = [:]
        var seen: Set<String> = []
        var found: [ExtractionConflict] = []

        for entry in listing.entries {
            // `7zz e` drops the folder structure, so folder entries cannot
            // collide in flatten mode.
            if request.flattenPaths, entry.isDirectory { continue }
            guard let entryPath = normalizedPath(entry.path) else { continue }
            guard isSelected(entryPath, by: selection) else { continue }

            let relative = request.flattenPaths
                ? normalizedPath(entry.name)
                : entryPath
            guard let relative else { continue }

            let candidate = destination.appendingPathComponent(relative).standardizedFileURL
            let key = candidate.path
            guard !seen.contains(key) else { continue }

            let parent = candidate.deletingLastPathComponent()
            if let descendable = descendableDirectories[parent.path] {
                guard descendable else { continue }
            } else {
                let descendable = isDirectoryLike(parent, fileManager: fileManager)
                descendableDirectories[parent.path] = descendable
                guard descendable else { continue }
            }

            guard let existing = kind(at: candidate, fileManager: fileManager) else { continue }
            // Merging two folders of the same name is ordinary extraction.
            if entry.isDirectory, existing == .directory { continue }

            seen.insert(key)
            found.append(
                ExtractionConflict(
                    entryPath: entryPath,
                    destinationPath: key,
                    entryIsDirectory: entry.isDirectory,
                    existingIsDirectory: existing == .directory
                )
            )
        }

        return found
    }

    /// The sentence shown before a destructive extraction starts.
    ///
    /// It lives beside the scan rather than in the view so that "what was
    /// found" and "what the user is told" cannot drift apart, and so the
    /// wording that announces the loss is covered by a test.
    public static func warningMessage(
        for conflicts: [ExtractionConflict],
        limit: Int = 6
    ) -> String {
        guard !conflicts.isEmpty else { return "" }
        var text = "目标文件夹中已有 \(conflicts.count) 个同名项目，继续解压会替换它们：\n\n"
        text += conflicts.prefix(limit).map { "· " + $0.entryPath }.joined(separator: "\n")
        if conflicts.count > limit {
            text += "\n…以及另外 \(conflicts.count - limit) 个"
        }
        text += "\n\n选择「跳过已存在」可以只解压目标文件夹里还没有的项目。"
        return text
    }

    // MARK: - Helpers

    enum Kind {
        case file
        case directory
        case symlink
    }

    /// Whether entries can be written into `url`.
    ///
    /// A symbolic link that resolves to a folder counts: 7-Zip writes straight
    /// through it, so a conflict behind one is a real conflict. Following the
    /// link is also what makes a symlinked destination (`/tmp`) work.
    static func isDirectoryLike(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    /// What is at `url`, or `nil` when nothing is.
    ///
    /// A dangling symbolic link still occupies the name — `attributesOfItem`
    /// follows links and reports nothing for one, which would hide a collision
    /// the user can see in Finder.
    static func kind(at url: URL, fileManager: FileManager) -> Kind? {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return .symlink
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.type] as? FileAttributeType) == .typeDirectory ? .directory : .file
    }

    /// A `/`-separated archive path with `.` and `..` resolved away.
    ///
    /// `nil` when nothing is left, or when the path climbs out of the
    /// destination: a listing must never make this check stat a path outside
    /// the folder the user picked.
    static func normalizedPath(_ raw: String) -> String? {
        let components = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)

        var parts: [String] = []
        for component in components {
            if component == "." { continue }
            if component == ".." { return nil }
            parts.append(String(component))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// Mirrors how `7zz` reads the path arguments the app passes: an exact
    /// item, or everything below a selected folder.
    static func isSelected(_ entryPath: String, by selection: [String]) -> Bool {
        if selection.isEmpty { return true }
        for selected in selection {
            if entryPath == selected { return true }
            if entryPath.hasPrefix(selected + "/") { return true }
        }
        return false
    }
}
