import ArchiveKit
import SwiftUI

struct ExtractSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ExtractionDraft

    init(initial: ExtractionDraft) {
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
        // Tall enough that the password field is visible without scrolling.
        .frame(width: 560, height: 580)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("解压")
                    .font(.headline)
                Text(draft.archive.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var form: some View {
        Form {
            Section("内容") {
                LabeledContent("压缩包") {
                    Text(draft.archive.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("范围") {
                    Text(draft.selectedPaths.isEmpty
                         ? "全部内容"
                         : "仅所选 \(draft.selectedPaths.count) 项")
                        .foregroundStyle(draft.selectedPaths.isEmpty ? .secondary : .primary)
                }
                if !draft.selectedPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(draft.selectedPaths.prefix(5), id: \.self) { path in
                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if draft.selectedPaths.count > 5 {
                            Text("…以及另外 \(draft.selectedPaths.count - 5) 项")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section("解压到") {
                LabeledContent("目标文件夹") {
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
                Toggle("不保留目录结构（把所有文件平铺到目标文件夹）", isOn: $draft.flattenPaths)
            }

            Section("选项") {
                Picker("同名文件", selection: $draft.overwrite) {
                    ForEach(OverwriteMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                LabeledField(title: "密码（若压缩包已加密）") {
                    SecureField("密码", text: $draft.password)
                        .textFieldStyle(.roundedBorder)
                }
                if draft.archiveIsEncrypted {
                    Label("该压缩包的条目已加密，需要正确密码。",
                          systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("开始解压") {
                model.startExtraction(draft)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func chooseDestination() {
        if let directory = Panels.chooseDirectory(
            title: "选择解压位置",
            prompt: "选择",
            defaultURL: draft.destinationDirectory.deletingLastPathComponent()
        ) {
            draft.destinationDirectory = directory
        }
    }
}
