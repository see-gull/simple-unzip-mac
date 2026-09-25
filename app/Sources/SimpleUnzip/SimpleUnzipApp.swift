import AppKit
import SwiftUI

@main
struct SimpleUnzipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Simple Unzip") {
            MainView()
                .environmentObject(model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开压缩包…") { model.showOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)

                Button("新建压缩包…") { model.showNewArchivePanel() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.isEngineAvailable)
            }

            CommandMenu("操作") {
                Button("解压所选…") { model.beginExtractionOfSelection() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.selection.isEmpty)

                Button("全部解压…") {
                    if let archive = model.openArchive { model.beginExtraction(of: archive) }
                }
                .disabled(model.openArchive == nil)

                Button("校验压缩包") { model.testOpenArchive() }
                    .disabled(model.openArchive == nil)

                Divider()

                Button("关闭压缩包") { model.closeArchive() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.openArchive == nil)

                Button("取消所有任务") { model.cancelAllTasks() }
                    .disabled(model.runningTaskCount == 0)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Handles "Open With" and drags onto the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppModel.shared.handleOpenURLs(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Offscreen screenshot mode, used to verify the UI without the Screen
        // Recording permission. Exits as soon as the images are written.
        if PreviewRenderer.runIfRequested() { return }

        // The window may not exist yet; check again once it has settled.
        for delay in [0.2, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.pullWindowsBackOnScreen()
            }
        }
    }

    /// macOS cascades windows on repeated launches and can eventually park the
    /// main window mostly — or entirely — outside the visible area. Measured on
    /// this machine: a launch landed at (729, 677) on a 1440x900 screen.
    /// Pull any such window back to the centre of the usable area.
    private static func pullWindowsBackOnScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame

        for window in NSApp.windows
        where window.isVisible && window.styleMask.contains(.titled) {
            let frame = window.frame
            guard frame.width > 1, frame.height > 1 else { continue }

            let intersection = frame.intersection(visible)
            let shownArea = intersection.isNull ? 0 : intersection.width * intersection.height
            let coverage = shownArea / (frame.width * frame.height)
            guard coverage < 0.9 else { continue }

            var target = frame
            target.size.width = min(frame.width, visible.width - 40)
            target.size.height = min(frame.height, visible.height - 40)
            target.origin.x = visible.midX - target.width / 2
            target.origin.y = visible.midY - target.height / 2
            window.setFrame(target, display: true)
        }
    }
}
