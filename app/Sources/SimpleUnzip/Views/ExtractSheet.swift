import ArchiveKit
import SwiftUI

struct ExtractSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ExtractionDraft
    /// The same-named items found the moment "开始解压" was pressed. Only ever
    /// filled for the destructive strategy; see `beginExtraction()`.
    @State private var pendingConflicts: [ExtractionConflict] = []
    @State private var isConfirmingOverwrite = false

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
        .alert("目标位置已有同名文件", isPresented: $isConfirmingOverwrite) {
            Button("覆盖", role: .destructive) {
                model.startExtraction(draft)
                dismiss()
            }
            Button("跳过已存在") {
                // The user asked to be asked; let the answer be the safe one
                // without sending them back to the picker.
                draft.overwrite = .skip
                model.startExtraction(draft)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(ExtractionConflictScanner.warningMessage(for: pendingConflicts))
        }
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
                Text(destinationNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
            Button("开始解压") { beginExtraction() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Overwrite guard

    /// Starts the extraction, asking first when the chosen strategy would
    /// replace existing files.
    ///
    /// 7-Zip's `-aoa` silently overwrites, and extraction used to inherit that
    /// without a word while compression confirmed its overwrite — the exact
    /// same data loss, one panel apart. The other strategies (`跳过`,
    /// `重命名…`) lose nothing, so interrupting for them would be noise.
    private func beginExtraction() {
        let conflicts = model.extractionConflicts(for: draft)
        if draft.overwrite.replacesExistingFiles, !conflicts.isEmpty {
            pendingConflicts = conflicts
            isConfirmingOverwrite = true
            return
        }
        model.startExtraction(draft)
        dismiss()
    }

    /// A one-`stat` note about the destination folder: the real conflict check
    /// runs on "开始解压", so nothing here walks the archive.
    private var destinationNote: String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: draft.destinationDirectory.path,
            isDirectory: &isDirectory
        )
        if !exists { return "该文件夹尚不存在，解压时会新建。" }
        if !isDirectory.boolValue { return "该位置已是一个文件，请改用其他文件夹。" }
        return "该文件夹已存在，开始解压前会检查其中的同名项目。"
    }

    private func chooseDestination() {
        // Seed the panel with the folder the sheet actually shows. Seeding it
        // with the *parent* meant that confirming without navigating silently
        // moved the destination one level up, scattering the files next to the
        // archive. A directory picker selects the folder it is *browsing*, so
        // the folder has to exist for the panel to open inside it.
        let destination = draft.destinationDirectory
        let alreadyExisted = FileManager.default.fileExists(atPath: destination.path)
        if !alreadyExisted {
            try? FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        }

        let picked = Panels.chooseDirectory(
            title: "选择解压位置",
            prompt: "选择",
            defaultURL: destination
        )

        if let picked {
            draft.destinationDirectory = picked
        } else if !alreadyExisted {
            // The folder only existed to position the panel; if the user backed
            // out, leave the disk as it was — and only if nothing landed in it.
            removeIfEmpty(destination)
        }
    }

    private func removeIfEmpty(_ url: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
