import Foundation
import ArchiveKit

/// What a task actually does when the runner picks it up.
enum TaskPayload {
    case compress(CompressionRequest)
    case extract(ExtractionRequest)
    case test(archive: URL, password: String?)
}

/// One queued or finished unit of work shown in the task list.
///
/// It is an `ObservableObject` so a progress tick redraws a single row instead
/// of the whole window.
@MainActor
final class ArchiveTask: ObservableObject, Identifiable {
    enum Kind: String {
        case compress
        case extract
        case test

        var title: String {
            switch self {
            case .compress: return "压缩"
            case .extract: return "解压"
            case .test: return "测试"
            }
        }

        var symbolName: String {
            switch self {
            case .compress: return "archivebox"
            case .extract: return "square.and.arrow.down"
            case .test: return "checkmark.seal"
            }
        }
    }

    enum State: Equatable {
        case queued
        case running
        case finished
        /// The command ran to completion but 7-Zip reported skipped items.
        /// Distinct from `.finished` so a partial result is never shown as a
        /// clean success.
        case finishedWithWarnings(String)
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .queued, .running: return false
            default: return true
            }
        }

        var label: String {
            switch self {
            case .queued: return "排队中"
            case .running: return "进行中"
            case .finished: return "已完成"
            case .finishedWithWarnings: return "有警告"
            case .failed: return "失败"
            case .cancelled: return "已取消"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    /// Name of the archive being produced or consumed.
    let title: String
    /// Where the work reads from and writes to.
    let subtitle: String
    /// The concrete command this task will run.
    let payload: TaskPayload
    let cancellation = CancellationHandle()

    @Published private(set) var state: State = .queued
    @Published private(set) var fraction: Double?
    @Published private(set) var currentItem: String = ""
    @Published private(set) var logLines: [String] = []
    @Published private(set) var outputURL: URL?
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?

    private var lastProgressPaint = Date.distantPast

    init(kind: Kind, title: String, subtitle: String, payload: TaskPayload) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.payload = payload
    }

    var isCancellable: Bool {
        state == .queued || state == .running
    }

    // 无用代码：`fileName` 只是 `title` 的别名，全文没有任何地方引用，可安全删除。
    var fileName: String { title }

    func markRunning() {
        state = .running
        startedAt = Date()
    }

    /// Applies a progress sample, throttled so a chatty archive cannot flood
    /// the main thread with redraws. The 100% sample always lands.
    func apply(_ progress: TaskProgress) {
        guard state == .running else { return }
        if let value = progress.fraction, value < 1.0 {
            let now = Date()
            if now.timeIntervalSince(lastProgressPaint) < 0.05 { return }
            lastProgressPaint = now
            fraction = value
        } else if progress.fraction == nil {
            return
        } else {
            lastProgressPaint = Date()
            fraction = 1.0
        }
        if let item = progress.currentItem, !item.isEmpty {
            currentItem = item
        }
    }

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 400 {
            logLines.removeFirst(logLines.count - 400)
        }
        if let last = logLines.last, currentItem.isEmpty, state == .running {
            currentItem = last
        }
    }

    func markFinished(output: URL?) {
        state = .finished
        fraction = 1.0
        finishedAt = Date()
        if let output { outputURL = output }
    }

    func markFailed(_ message: String) {
        state = .failed(message)
        finishedAt = Date()
    }

    /// The work produced output, but 7-Zip reported items it had to skip.
    func markFinishedWithWarnings(_ message: String, output: URL?) {
        state = .finishedWithWarnings(message)
        fraction = 1.0
        finishedAt = Date()
        if let output { outputURL = output }
    }

    func markCancelled() {
        state = .cancelled
        finishedAt = Date()
    }

    var durationDescription: String {
        guard let startedAt else { return "" }
        let end = finishedAt ?? Date()
        let seconds = end.timeIntervalSince(startedAt)
        if seconds < 1 { return "<1 秒" }
        if seconds < 60 { return String(format: "%.0f 秒", seconds) }
        return String(format: "%.1f 分钟", seconds / 60)
    }
}

/// Editable state behind the "create archive" sheet.
struct CompressionDraft: Identifiable {
    let id = UUID()
    var sources: [URL]
    var archiveName: String
    var destinationDirectory: URL
    var format: ArchiveFormat = .sevenZip
    var level: Double = 5
    var usePassword = false
    var password = ""
    var encryptFileNames = false
    var splitVolume = ""
    var excludeMacJunk = true

    var destinationURL: URL {
        var name = archiveName
        let suffix = "." + format.fileExtension
        if !name.lowercased().hasSuffix(suffix.lowercased()) {
            name += suffix
        }
        return destinationDirectory.appendingPathComponent(name)
    }

    var validationMessage: String? {
        if sources.isEmpty { return "请先选择要压缩的文件。" }
        if archiveName.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写压缩包名称。" }
        if format.holdsSingleItemOnly {
            if sources.count > 1 {
                return "\(format.displayName) 只能压缩单个文件，当前选了 \(sources.count) 项，"
                    + "请改用 7z、ZIP 或 TAR.GZ。"
            }
            if let first = sources.first, Panels.isDirectory(first) {
                return "\(format.displayName) 只能压缩单个文件，不能压缩文件夹，"
                    + "请改用 7z、ZIP 或 TAR.GZ。"
            }
        }
        if usePassword && password.isEmpty { return "已启用密码，但密码为空。" }
        if usePassword && !format.supportsEncryption {
            return "\(format.displayName) 格式不支持加密，请改用 7z 或 ZIP。"
        }
        return nil
    }

    /// A sensible default name derived from what is being compressed.
    static func suggestedName(for sources: [URL], format: ArchiveFormat) -> String {
        if sources.count == 1, let first = sources.first {
            return first.deletingPathExtension().lastPathComponent
        }
        if let first = sources.first {
            return first.deletingLastPathComponent().lastPathComponent
        }
        return "归档"
    }
}

/// Editable state behind the "extract" sheet.
struct ExtractionDraft: Identifiable {
    let id = UUID()
    var archive: URL
    var destinationDirectory: URL
    var password = ""
    var overwrite: OverwriteMode = .overwrite
    var flattenPaths = false
    var selectedPaths: [String] = []
    var archiveIsEncrypted = false

    /// `<parent>/<archive name without extension>`, the usual destination.
    static func suggestedDestination(for archive: URL) -> URL {
        let parent = archive.deletingLastPathComponent()
        var name = archive.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz", ".txz"] {
            if name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                return parent.appendingPathComponent(name, isDirectory: true)
            }
        }
        name = (name as NSString).deletingPathExtension
        return parent.appendingPathComponent(name, isDirectory: true)
    }
}
