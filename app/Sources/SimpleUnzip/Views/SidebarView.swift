import ArchiveKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            archiveSection
            taskSection
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var archiveSection: some View {
        Section("当前压缩包") {
            if let archive = model.openArchive, let listing = model.listing {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.zipper")
                            .foregroundStyle(Color.accentColor)
                        Text(archive.lastPathComponent)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let type = listing.properties.type {
                        InfoLine(label: "格式", value: type.uppercased())
                    }
                    InfoLine(label: "文件", value: DisplayFormat.count(listing.fileCount))
                    InfoLine(label: "文件夹", value: DisplayFormat.count(listing.folderCount))
                    InfoLine(label: "原始大小", value: DisplayFormat.bytesAlways(listing.totalUncompressedSize))
                    InfoLine(label: "压缩后", value: DisplayFormat.bytes(listing.properties.physicalSize))
                    if listing.isEncrypted {
                        Label("已加密", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)

                Button("关闭压缩包") { model.closeArchive() }
                    .buttonStyle(.link)
                    .font(.caption)
            } else {
                Text("尚未打开压缩包")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var taskSection: some View {
        Section {
            if model.tasks.isEmpty {
                Text("暂无任务")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.tasks) { task in
                    TaskRowView(task: task)
                }
            }
        } header: {
            HStack {
                Text("任务")
                if model.runningTaskCount > 0 {
                    Text("\(model.runningTaskCount)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                }
                Spacer()
                if model.tasks.contains(where: { $0.state.isTerminal }) {
                    Button("清除") { model.clearFinishedTasks() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }
}

struct InfoLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.primary)
        }
    }
}

struct TaskRowView: View {
    @ObservedObject var task: ArchiveTask
    @EnvironmentObject private var model: AppModel
    @State private var isShowingLog = false

    /// A result on disk is worth revealing whenever the task produced one —
    /// including the partial result that ended with warnings.
    private var showsRevealButton: Bool {
        guard task.outputURL != nil else { return false }
        switch task.state {
        case .finished, .finishedWithWarnings: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: task.kind.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(task.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                StateBadge(state: task.state)
            }

            switch task.state {
            case .running:
                ProgressView(value: task.fraction ?? 0, total: 1)
                    .progressViewStyle(.linear)
                if !task.currentItem.isEmpty {
                    Text(task.currentItem)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            case .queued:
                Text(task.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            case .finishedWithWarnings(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            case .finished, .cancelled:
                Text("\(task.subtitle) · \(task.durationDescription)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 10) {
                if task.isCancellable {
                    Button("取消") { model.cancel(task) }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
                if showsRevealButton {
                    Button("在访达中显示") { model.reveal(task) }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
                if !task.logLines.isEmpty {
                    Button(isShowingLog ? "隐藏输出" : "查看输出") {
                        isShowingLog.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
            }

            if isShowingLog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(task.logLines.suffix(60).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 4)
    }
}

struct StateBadge: View {
    let state: ArchiveTask.State

    var body: some View {
        Text(state.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(background))
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch state {
        case .queued: return Color.secondary.opacity(0.18)
        case .running: return Color.accentColor.opacity(0.22)
        case .finished: return Color.green.opacity(0.22)
        case .finishedWithWarnings: return Color.orange.opacity(0.22)
        case .failed: return Color.red.opacity(0.22)
        case .cancelled: return Color.orange.opacity(0.22)
        }
    }

    private var foreground: Color {
        switch state {
        case .queued: return .secondary
        case .running: return .accentColor
        case .finished: return .green
        case .finishedWithWarnings: return .orange
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}
