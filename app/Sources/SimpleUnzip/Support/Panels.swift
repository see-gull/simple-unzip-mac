import AppKit
import Foundation
import UniformTypeIdentifiers

/// Thin wrappers over the AppKit panels, which stay more predictable than
/// SwiftUI's file importers for multi-select and directory selection.
enum Panels {
    static func chooseArchives() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "打开压缩包"
        panel.prompt = "打开"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = archiveContentTypes()
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseSourcesToCompress() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "选择要压缩的文件或文件夹"
        panel.prompt = "选择"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseDirectory(title: String, prompt: String, defaultURL: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let defaultURL, FileManager.default.fileExists(atPath: defaultURL.path) {
            panel.directoryURL = defaultURL
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 无用代码：当前没有任何调用方（存储位置由 CompressSheet 内部决定），可安全删除。
    static func chooseSaveLocation(suggestedName: String, in directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.title = "存储压缩包"
        panel.prompt = "存储"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            panel.directoryURL = directory
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 无用代码：当前没有任何调用方，可安全删除。
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Extensions `7zz` can open, used only to bias the open panel.
    static func archiveContentTypes() -> [UTType] {
        var types: [UTType] = [.archive, .zip, .gzip, .bz2]
        for identifier in ["public.7z-archive", "org.7-zip.7-zip-archive", "public.xz-archive",
                           "com.rarlab.rar-archive", "public.iso-image"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        for identifier in ["7z", "xz", "rar", "lzma", "zst", "lz4", "cab", "wim", "cpio", "lz",
                           "tar", "tgz", "tbz", "tbz2", "txz"] {
            if let type = UTType(filenameExtension: identifier) { types.append(type) }
        }
        return types
    }

    /// `FileManager` has no directory predicate, so state it explicitly.
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Best-effort archive detection by extension, used by drag and drop.
    static func looksLikeArchive(_ url: URL) -> Bool {
        let known: Set<String> = [
            "7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz",
            "lzma", "zst", "lz4", "cab", "iso", "wim", "cpio", "arj", "lzh", "lha",
            "rpm", "deb", "dmg", "xar", "apk", "jar", "war", "z", "lz", "br", "chm",
            "msi", "nsis", "udf", "vhd", "vhdx", "vdi", "vmdk", "qcow", "squashfs",
            "apfs", "hfs", "fat", "mbr", "gpt", "base64", "b64", "aa", "a",
        ]
        let ext = url.pathExtension.lowercased()
        if known.contains(ext) { return true }
        // Compound containers such as `.tar.gz`.
        let name = url.lastPathComponent.lowercased()
        return [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4"]
            .contains { name.hasSuffix($0) }
    }

    /// Resolves dropped item providers into file URLs.
    static func loadFileURLs(
        from providers: [NSItemProvider],
        completion: @escaping ([URL]) -> Void
    ) {
        let lock = NSLock()
        var collected: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(collected)
        }
    }
}
