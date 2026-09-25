import ArchiveKit
import SwiftUI

struct CompressSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CompressionDraft
    /// The existing file that the next "开始压缩" would overwrite.
    @State private var pendingOverwrite: URL?
    @State private var isConfirmingOverwrite = false

    init(initial: CompressionDraft) {
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        // Tall enough that the encryption and advanced sections are visible
        // without scrolling on a 900pt-tall display.
        .frame(width: 600, height: 740)
        .onChange(of: draft.format) { newFormat in
            // A format without encryption support hides the password field and
            // disables its toggle, so leaving the toggle on left the user stuck
            // on a message ("请改用 7z 或 ZIP") with no way to clear it.
            if !newFormat.supportsEncryption {
                draft.usePassword = false
            }
        }
        .alert(
            "压缩包已存在",
            isPresented: $isConfirmingOverwrite,
            presenting: pendingOverwrite
        ) { _ in
            Button("覆盖", role: .destructive) {
                pendingOverwrite = nil
                model.startCompression(draft)
                dismiss()
            }
            Button("取消", role: .cancel) { pendingOverwrite = nil }
        } message: { existing in
            Text("\(existing.lastPathComponent) 已存在，继续将覆盖它。")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("新建压缩包")
                    .font(.headline)
                Text("使用 7-Zip 引擎创建归档")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var form: some View {
        Form {
            Section("要压缩的内容") {
                if draft.sources.count == 1, let first = draft.sources.first {
                    LabeledContent("项目", value: first.lastPathComponent)
                    LabeledContent("位置") {
                        Text(first.deletingLastPathComponent().path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("项目数", value: "\(draft.sources.count) 个")
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(draft.sources.prefix(6), id: \.self) { url in
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if draft.sources.count > 6 {
                            Text("…以及另外 \(draft.sources.count - 6) 项")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Button("重新选择…") { reselectSources() }
                    .controlSize(.small)
            }

            Section("存储") {
                LabeledField(title: "压缩包名称") {
                    TextField("未命名", text: $draft.archiveName)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("文件夹") {
                    HStack(spacing: 6) {
                        Text(draft.destinationDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("更改…") { chooseDestination() }
                            .controlSize(.small)
                    }
                }

                LabeledContent("完整路径") {
                    Text(draft.destinationURL.path)
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            Section("格式") {
                Picker("压缩格式", selection: $draft.format) {
                    ForEach(ArchiveFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                if draft.format.supportsCompressionLevel {
                    LabeledContent("压缩级别") {
                        HStack(spacing: 10) {
                            Slider(value: $draft.level, in: 0...9, step: 1)
                            Text(Self.levelName(Int(draft.level.rounded())))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .leading)
                        }
                    }
                    Text(draft.format.requiresTarStage
                         ? "该格式会先打包为 tar，再压缩。"
                         : "级别越高越慢，压缩率越好。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("加密") {
                Toggle("使用密码", isOn: $draft.usePassword)
                    .disabled(!draft.format.supportsEncryption)

                if draft.usePassword && draft.format.supportsEncryption {
                    LabeledField(title: "密码") {
                        SecureField("密码", text: $draft.password)
                            .textFieldStyle(.roundedBorder)
                    }
                    if draft.format == .sevenZip {
                        Toggle("同时加密文件名（隐藏文件列表）", isOn: $draft.encryptFileNames)
                    }
                }

                if !draft.format.supportsEncryption {
                    Text("\(draft.format.displayName) 格式不支持加密，7-Zip 仅能为 7z 与 ZIP 设置密码。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("高级") {
                LabeledField(title: "分卷大小") {
                    TextField("例如 100m、700m，留空表示不分卷", text: $draft.splitVolume)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("排除 macOS 元数据（.DS_Store、__MACOSX）", isOn: $draft.excludeMacJunk)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = draft.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("开始压缩") {
                if let existing = existingOutput() {
                    pendingOverwrite = existing
                    isConfirmingOverwrite = true
                } else {
                    model.startCompression(draft)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft.validationMessage != nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    /// The file this draft would replace, if any.
    ///
    /// 7-Zip overwrites a same-named archive without asking, so the confirmation
    /// has to come from here. Split volumes are checked through their first
    /// part, which is the file the user would recognise.
    private func existingOutput() -> URL? {
        let destination = draft.destinationURL
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if !draft.splitVolume.trimmingCharacters(in: .whitespaces).isEmpty {
            let firstVolume = URL(fileURLWithPath: destination.path + ".001")
            if FileManager.default.fileExists(atPath: firstVolume.path) { return firstVolume }
        }
        return nil
    }

    private func reselectSources() {
        let picked = Panels.chooseSourcesToCompress()
        guard !picked.isEmpty else { return }
        draft.sources = picked
        if draft.archiveName.isEmpty {
            draft.archiveName = CompressionDraft.suggestedName(for: picked, format: draft.format)
        }
    }

    private func chooseDestination() {
        if let directory = Panels.chooseDirectory(
            title: "选择存储位置",
            prompt: "选择",
            defaultURL: draft.destinationDirectory
        ) {
            draft.destinationDirectory = directory
        }
    }

    static func levelName(_ level: Int) -> String {
        switch level {
        case 0: return "0 · 仅存储"
        case 1: return "1 · 最快"
        case 3: return "3 · 快速"
        case 5: return "5 · 标准"
        case 7: return "7 · 最大"
        case 9: return "9 · 极限"
        default: return "\(level)"
        }
    }
}
