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
            apply(listing: listing, for: url)
        } catch let error as ArchiveError {
            if case .wrongPassword = error {
                pendingPasswordArchive = url
                alert = AlertPayload(
                    title: "需要密码",
                    message: "\(url.lastPathComponent) 的内容已加密，请输入密码后重试。"
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

    /// Set when a listing failed because the archive needs a password.
    @Published var pendingPasswordArchive: URL?

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
        runIntegrityTest(on: openArchive, password: nil)
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
            if case .cancelled = error {
                task.markCancelled()
                statusMessage = "已取消 \(task.title)"
            } else {
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
