import AppKit
import Foundation
import ArchiveKit
import SwiftUI

/// A blocking message shown as a sheet-level alert.
struct AlertPayload: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// A header-encrypted archive that cannot even be listed without a password.
struct PasswordPrompt: Identifiable {
    let id = UUID()
    let archive: URL
    let message: String
}

/// The single source of truth for the window: tool discovery, the open archive,
/// and the task queue.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum ToolStatus: Equatable {
        case checking
        case ready(version: String, path: String)
        case unavailable(String)
    }

    @Published private(set) var toolStatus: ToolStatus = .checking
    @Published private(set) var tasks: [ArchiveTask] = []
    @Published private(set) var openArchive: URL?
    @Published private(set) var listing: ArchiveListing?
    @Published private(set) var tree: [ArchiveTreeNode] = []
    @Published private(set) var isLoadingArchive = false
    @Published var selection: Set<String> = []
    @Published var statusMessage = "拖入文件即可压缩，或打开一个压缩包"
    @Published var alert: AlertPayload?
    @Published var compressDraft: CompressionDraft?
    @Published var extractDraft: ExtractionDraft?
    /// Set when an archive needs a password before it can be listed at all.
    @Published var passwordPrompt: PasswordPrompt?
    /// Bound to the password field of `PasswordSheet`.
    @Published var passwordInput = ""
    /// The password that successfully opened `openArchive`, reused when the
    /// extract sheet opens so header-encrypted archives need to be typed once.
    private var openArchivePassword = ""

    private var engine: ArchiveEngine?
    private var runningJob: Task<Void, Never>?

    private init() {}

    // MARK: - Tool discovery

    func bootstrap() {
        // `onAppear` can fire more than once; only the first pass should probe.
        // 注意：下面这行不是无用代码——它是“只在首次时探测”的守卫，等价于
        // `guard case .checking = toolStatus else { return }`，只是写得别扭。请勿当死代码删除。
        if case .checking = toolStatus {} else { return }
        do {
            let tool = try ArchiveTool.locate()
            engine = ArchiveEngine(tool: tool)
            toolStatus = .ready(version: tool.version, path: tool.executableURL.path)
            statusMessage = "7-Zip \(tool.version) 已就绪"
        } catch {
            engine = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            toolStatus = .unavailable(message)
            statusMessage = "未找到 7zz"
        }
    }

    var isEngineAvailable: Bool {
        if case .ready = toolStatus { return true }
        return false
    }

    // MARK: - Opening archives

    func open(archive url: URL, password: String = "") {
        guard let engine else { return }
        isLoadingArchive = true
        statusMessage = "正在读取 \(url.lastPathComponent)…"

        Task {
            // 无用代码：此行没有任何实际作用，仅为引用局部 `engine` 以避免“未使用”告警；可安全删除。
            _ = engine
            await load(archive: url, password: password)
        }
    }

    /// Loads a listing and publishes it. `open` wraps this in a detached task;
    /// the preview renderer awaits it directly.
    func load(archive url: URL, password: String = "") async {
        guard let engine else { return }
        isLoadingArchive = true
        defer { isLoadingArchive = false }
        do {
            let listing = try await engine.list(
                archive: url,
                password: password.isEmpty ? nil : password
            )
            openArchivePassword = password
            apply(listing: listing, for: url)
        } catch let error as ArchiveError {
            if case .wrongPassword = error {
                // Header-encrypted archives (`-mhe=on`) produce no listing at
                // all without the password, so the browser cannot open them and
                // there is nothing to extract from. Ask for it here; the old
                // code recorded the URL in a property that nothing ever read,
                // leaving the user with a dead end.
                passwordPrompt = PasswordPrompt(
                    archive: url,
                    message: password.isEmpty
                        ? "\(url.lastPathComponent) 的内容与文件名都已加密，需要密码才能打开。"
                        : "密码不正确，请重新输入 \(url.lastPathComponent) 的密码。"
                )
            } else {
                alert = AlertPayload(
                    title: "无法打开压缩包",
                    message: error.errorDescription ?? "未知错误"
                )
            }
        } catch {
            alert = AlertPayload(title: "无法打开压缩包", message: error.localizedDescription)
        }
    }

    /// Runs the password the user typed in `PasswordSheet`.
    func submitPassword() {
        guard let prompt = passwordPrompt else { return }
        let password = passwordInput
        passwordInput = ""
        passwordPrompt = nil
        open(archive: prompt.archive, password: password)
    }

    func cancelPasswordEntry() {
        passwordPrompt = nil
        passwordInput = ""
        statusMessage = "已取消打开加密压缩包"
    }

    private func apply(listing: ArchiveListing, for url: URL) {
        self.listing = listing
        self.tree = ArchiveTreeBuilder.build(from: listing)
        self.openArchive = url
        self.selection = []
        let folders = listing.folderCount
        let files = listing.fileCount
        statusMessage = "\(url.lastPathComponent)：\(DisplayFormat.count(files)) 个文件，\(DisplayFormat.count(folders)) 个文件夹"
    }

    func closeArchive() {
        openArchive = nil
        listing = nil
        tree = []
        selection = []
        openArchivePassword = ""
        statusMessage = "拖入文件即可压缩，或打开一个压缩包"
    }

    // MARK: - Panel entry points

    func showOpenPanel() {
        guard let url = Panels.chooseArchives().first else { return }
        open(archive: url)
    }

    func showNewArchivePanel() {
        let sources = Panels.chooseSourcesToCompress()
        guard !sources.isEmpty else { return }
        beginCompression(sources: sources)
    }

    func handleDrop(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if urls.count == 1, let url = urls.first, Panels.looksLikeArchive(url),
           !Panels.isDirectory(url) {
            open(archive: url)
        } else {
            beginCompression(sources: urls)
        }
    }

    /// Feedback for a drop we cannot turn into file URLs.
    ///
    /// Without this the drop simply vanished: the zone claimed every drop, the
    /// unusable providers were discarded, and nothing on screen changed.
    func reportUnusableDrop() {
        statusMessage = "拖入的内容不是文件或文件夹，已忽略"
        alert = AlertPayload(
            title: "无法处理拖入的内容",
            message: "拖入的项目不是文件或文件夹。请从访达中拖入文件、文件夹或压缩包。"
        )
    }

    func handleOpenURLs(_ urls: [URL]) {
        guard let first = urls.first else { return }
        open(archive: first)
    }

    // MARK: - Compression

    func beginCompression(sources: [URL]) {
        guard !sources.isEmpty else { return }
        let directory = sources.first?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        compressDraft = CompressionDraft(
            sources: sources,
            archiveName: CompressionDraft.suggestedName(for: sources, format: .sevenZip),
            destinationDirectory: directory
        )
    }

    func startCompression(_ draft: CompressionDraft) {
        var request = CompressionRequest(sources: draft.sources, destination: draft.destinationURL)
        request.format = draft.format
        request.level = Int(draft.level.rounded())
        request.password = draft.usePassword ? draft.password : nil
        request.encryptFileNames = draft.encryptFileNames
        request.splitVolumeSize = draft.splitVolume.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : draft.splitVolume
        request.excludeMacJunk = draft.excludeMacJunk

        let task = ArchiveTask(
            kind: .compress,
            title: request.destination.lastPathComponent,
            subtitle: draft.sources.count == 1
                ? (draft.sources.first?.lastPathComponent ?? "")
                : "\(draft.sources.count) 个项目",
            payload: .compress(request)
        )
        tasks.insert(task, at: 0)
        pump()
    }

    // MARK: - Extraction

    func beginExtraction(of archive: URL, selectedPaths: [String] = []) {
        extractDraft = ExtractionDraft(
            archive: archive,
            destinationDirectory: ExtractionDraft.suggestedDestination(for: archive),
            // Reuse the password that opened this archive, so a header-encrypted
            // one does not have to be typed a second time.
            password: archive == openArchive ? openArchivePassword : "",
            selectedPaths: selectedPaths,
            archiveIsEncrypted: listing?.isEncrypted ?? false
        )
    }

    func beginExtractionOfSelection() {
        guard let openArchive else { return }
        let paths = selection.sorted()
        beginExtraction(of: openArchive, selectedPaths: paths)
    }

    func startExtraction(_ draft: ExtractionDraft) {
        var request = ExtractionRequest(archive: draft.archive, destination: draft.destinationDirectory)
        request.password = draft.password.isEmpty ? nil : draft.password
        request.overwrite = draft.overwrite
        request.flattenPaths = draft.flattenPaths
        request.selectedPaths = draft.selectedPaths

        let task = ArchiveTask(
            kind: .extract,
            title: draft.archive.lastPathComponent,
            subtitle: draft.destinationDirectory.path,
            payload: .extract(request)
        )
        tasks.insert(task, at: 0)
        pump()
    }

    // MARK: - Integrity test

    func runIntegrityTest(on archive: URL, password: String? = nil) {
        let task = ArchiveTask(
            kind: .test,
            title: archive.lastPathComponent,
            subtitle: "完整性校验",
            payload: .test(archive: archive, password: password)
        )
        tasks.insert(task, at: 0)
        pump()
        statusMessage = "正在校验 \(archive.lastPathComponent)"
    }

    func testOpenArchive() {
        guard let openArchive else { return }
        runIntegrityTest(
            on: openArchive,
            password: openArchivePassword.isEmpty ? nil : openArchivePassword
        )
    }

    // MARK: - Queue

    /// Runs queued tasks one at a time.
    private func pump() {
        guard runningJob == nil else { return }
        guard let next = tasks.last(where: { $0.state == .queued }) else { return }
        runningJob = Task { [weak self] in
            await self?.execute(next)
            self?.runningJob = nil
            self?.pump()
        }
    }

    private func execute(_ task: ArchiveTask) async {
        guard let engine else {
            task.markFailed("7zz 不可用")
            return
        }
        task.markRunning()
        statusMessage = "\(task.kind.title)中：\(task.title)"

        let onProgress: (TaskProgress) -> Void = { [weak task] progress in
            Task { @MainActor in task?.apply(progress) }
        }
        let onLog: (String) -> Void = { [weak task] line in
            Task { @MainActor in task?.appendLog(line) }
        }

        do {
            switch task.payload {
            case .compress(let request):
                try await engine.compress(
                    request,
                    cancellation: task.cancellation,
                    onProgress: onProgress,
                    onLog: onLog
                )
                task.markFinished(output: request.destination)
                statusMessage = "已创建 \(request.destination.lastPathComponent)"

            case .extract(let request):
                try FileManager.default.createDirectory(
                    at: request.destination,
                    withIntermediateDirectories: true
                )
                try await engine.extract(
                    request,
                    cancellation: task.cancellation,
                    onProgress: onProgress,
                    onLog: onLog
                )
                task.markFinished(output: request.destination)
                statusMessage = "已解压到 \(request.destination.lastPathComponent)"

            case .test(let archive, let password):
                let report = try await engine.test(
                    archive: archive,
                    password: password,
                    cancellation: task.cancellation,
                    onProgress: onProgress,
                    onLog: onLog
                )
                task.markFinished(output: nil)
                statusMessage = report.isHealthy
                    ? "\(archive.lastPathComponent) 校验通过"
                    : "\(archive.lastPathComponent) 存在问题"
            }
        } catch let error as ArchiveError {
            switch error {
            case .cancelled:
                task.markCancelled()
                statusMessage = "已取消 \(task.title)"
            case .completedWithWarnings(let messages):
                // The command finished, but 7-Zip skipped items. Report the
                // partial result as such instead of a green "已完成".
                let details = messages.isEmpty
                    ? "7-Zip 未说明跳过原因。"
                    : messages.joined(separator: "\n")
                task.markFinishedWithWarnings(
                    "7-Zip 跳过了部分项目，结果不完整。",
                    output: outputURL(for: task)
                )
                task.appendLog(details)
                statusMessage = "\(task.kind.title)完成，但有项目被跳过：\(task.title)"
                alert = AlertPayload(
                    title: "\(task.kind.title)完成，但有警告",
                    message: "\(task.title)\n\n7-Zip 跳过了部分项目，结果可能不完整：\n\(details)"
                )
            default:
                task.markFailed(error.shortDescription)
                if let description = error.errorDescription {
                    task.appendLog(description)
                }
                alert = AlertPayload(
                    title: "\(task.kind.title)失败：\(task.title)",
                    message: error.errorDescription ?? "未知错误"
                )
            }
        } catch {
            task.markFailed(error.localizedDescription)
            alert = AlertPayload(
                title: "\(task.kind.title)失败：\(task.title)",
                message: error.localizedDescription
            )
        }
    }

    /// Where a task's result lands on disk, when it produces one.
    private func outputURL(for task: ArchiveTask) -> URL? {
        switch task.payload {
        case .compress(let request): return request.destination
        case .extract(let request): return request.destination
        case .test: return nil
        }
    }

    func cancel(_ task: ArchiveTask) {
        task.cancellation.cancel()
    }

    func cancelAllTasks() {
        for task in tasks where task.isCancellable {
            task.cancellation.cancel()
        }
    }

    func clearFinishedTasks() {
        tasks.removeAll { $0.state.isTerminal }
    }

    var runningTaskCount: Int {
        tasks.filter { !$0.state.isTerminal }.count
    }

    // MARK: - Output helpers

    func reveal(_ task: ArchiveTask) {
        guard let url = task.outputURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            Panels.reveal(url)
        }
    }

    func revealOpenArchive() {
        guard let openArchive else { return }
        Panels.reveal(openArchive)
    }
}
