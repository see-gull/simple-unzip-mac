import AppKit
import SwiftUI

/// Renders SwiftUI screens to PNG files without a visible window.
///
/// This exists because screen capture needs the Screen Recording permission,
/// which is not available here. Rendering the view hierarchy offscreen proves
/// the layout actually builds and draws, and works in a headless-ish context.
///
/// Triggered by `ARCHIVE_RENDER_PREVIEWS=<output directory>`; the app exits
/// once the images are written.
@MainActor
enum PreviewRenderer {

    static func runIfRequested() -> Bool {
        guard let directory = ProcessInfo.processInfo.environment["ARCHIVE_RENDER_PREVIEWS"],
              !directory.isEmpty else {
            return false
        }
        let output = URL(fileURLWithPath: directory)
        Task { @MainActor in
            await run(outputDirectory: output)
            exit(0)
        }
        return true
    }

    static func run(outputDirectory: URL) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let model = AppModel.shared
        model.bootstrap()
        print("[preview] 工具状态：\(model.toolStatus)")

        var archivePath: String? = ProcessInfo.processInfo.environment["ARCHIVE_PREVIEW_ARCHIVE"]
        if archivePath == nil || archivePath!.isEmpty {
            archivePath = nil
        }

        if let archivePath {
            await model.load(archive: URL(fileURLWithPath: archivePath))
            print("[preview] 已加载压缩包，条目数：\(model.listing?.entries.count ?? -1)")
        }

        // 无用代码：`model2` 与 `model` 是同一个对象，纯冗余别名，可直接改用 `model`（此别名可删）。
        let model2 = model

        render(
            MainView().environmentObject(model),
            size: CGSize(width: 1120, height: 720),
            to: outputDirectory.appendingPathComponent("01-main.png")
        )

        render(
            SidebarView().environmentObject(model),
            size: CGSize(width: 300, height: 620),
            to: outputDirectory.appendingPathComponent("02-sidebar.png")
        )

        if let listing = model2.listing, let archive = model2.openArchive {
            render(
                ArchiveBrowserView(archive: archive, listing: listing).environmentObject(model),
                size: CGSize(width: 820, height: 620),
                to: outputDirectory.appendingPathComponent("03-browser.png")
            )
        }

        render(
            DropZoneView().environmentObject(model),
            size: CGSize(width: 820, height: 560),
            to: outputDirectory.appendingPathComponent("04-dropzone.png")
        )

        let demoRoot: URL
        if let override = ProcessInfo.processInfo.environment["ARCHIVE_PREVIEW_DEMO"], !override.isEmpty {
            demoRoot = URL(fileURLWithPath: override)
        } else {
            demoRoot = outputDirectory.appendingPathComponent("demo", isDirectory: true)
        }
        var compressionDraft = CompressionDraft(
            sources: [demoRoot],
            archiveName: "示例归档",
            destinationDirectory: outputDirectory
        )
        compressionDraft.usePassword = true
        compressionDraft.password = "hunter2"
        compressionDraft.encryptFileNames = true
        render(
            CompressSheet(initial: compressionDraft).environmentObject(model),
            size: CGSize(width: 600, height: 740),
            to: outputDirectory.appendingPathComponent("05-compress-sheet.png")
        )

        if let archive = model2.openArchive {
            var extractionDraft = ExtractionDraft(
                archive: archive,
                destinationDirectory: ExtractionDraft.suggestedDestination(for: archive)
            )
            extractionDraft.archiveIsEncrypted = true
            extractionDraft.password = "hunter2"
            render(
                ExtractSheet(initial: extractionDraft).environmentObject(model),
                size: CGSize(width: 560, height: 580),
                to: outputDirectory.appendingPathComponent("06-extract-sheet.png")
            )
        }

        print("[preview] 完成，输出目录：\(outputDirectory.path)")
    }

    /// Snapshots a view through an `NSHostingView` embedded in a real (but
    /// off-screen) window.
    ///
    /// A bare hosting view is not enough: `List`, `NavigationSplitView` and
    /// other AppKit-backed controls only populate once they belong to a window,
    /// so the snapshot would show empty chrome.
    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.appearance = NSAppearance(named: .aqua)
        window.isExcludedFromWindowsMenu = true
        window.orderFront(nil)

        // Let AppKit materialise table views, split views, popups and spinners.
        for _ in 0..<12 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        defer { window.orderOut(nil) }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("[preview] 无法为 \(url.lastPathComponent) 创建位图")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("[preview] 无法编码 \(url.lastPathComponent)")
            return
        }
        do {
            try png.write(to: url)
            print("[preview] 已写出 \(url.lastPathComponent) (\(Int(size.width))x\(Int(size.height)), \(png.count) 字节)")
        } catch {
            print("[preview] 写入失败 \(url.lastPathComponent)：\(error)")
        }
    }
}
