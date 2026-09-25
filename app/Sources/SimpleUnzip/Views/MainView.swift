import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            DetailView()
        }
        .frame(minWidth: 960, minHeight: 620)
        .toolbar { toolbarContent }
        .sheet(item: $model.compressDraft) { draft in
            CompressSheet(initial: draft)
                .environmentObject(model)
        }
        .sheet(item: $model.extractDraft) { draft in
            ExtractSheet(initial: draft)
                .environmentObject(model)
        }
        .sheet(item: $model.passwordPrompt) { prompt in
            PasswordSheet(prompt: prompt)
                .environmentObject(model)
        }
        .alert(item: $model.alert) { payload in
            Alert(
                title: Text(payload.title),
                message: Text(payload.message),
                dismissButton: .default(Text("好"))
            )
        }
        .onAppear { model.bootstrap() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.showOpenPanel()
            } label: {
                Label("打开", systemImage: "folder")
            }
            .help("打开一个压缩包")

            Button {
                model.showNewArchivePanel()
            } label: {
                Label("压缩", systemImage: "archivebox")
            }
            .help("选择文件并压缩")
            .disabled(!model.isEngineAvailable)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let archive = model.openArchive {
                Button {
                    model.beginExtraction(of: archive)
                } label: {
                    Label("解压", systemImage: "square.and.arrow.down")
                }
                .help("解压整个压缩包")

                Button {
                    model.testOpenArchive()
                } label: {
                    Label("校验", systemImage: "checkmark.seal")
                }
                .help("校验压缩包完整性")
            }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let archive = model.openArchive, let listing = model.listing {
                    ArchiveBrowserView(archive: archive, listing: listing)
                } else {
                    DropZoneView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            StatusBarView()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isLoadingArchive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
            }
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(toolLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusSymbol: String {
        switch model.toolStatus {
        case .checking: return "hourglass"
        case .ready: return "checkmark.circle"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch model.toolStatus {
        case .checking: return .secondary
        case .ready: return .green
        case .unavailable: return .orange
        }
    }

    private var toolLabel: String {
        switch model.toolStatus {
        case .checking: return "正在检测 7zz…"
        case .ready(let version, let path): return "7-Zip \(version) · \(path)"
        case .unavailable: return "7zz 不可用"
        }
    }
}
