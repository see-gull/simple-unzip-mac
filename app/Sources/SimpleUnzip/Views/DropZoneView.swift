import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: isTargeted ? 3 : 2, dash: [8, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
                .padding(28)

            VStack(spacing: 14) {
                Image(systemName: toolIcon)
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)

                Text(headline)
                    .font(.title3.weight(.medium))

                Text(subheadline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                if model.isEngineAvailable {
                    HStack(spacing: 12) {
                        Button {
                            model.showOpenPanel()
                        } label: {
                            Label("打开压缩包", systemImage: "folder")
                        }
                        .controlSize(.large)

                        Button {
                            model.showNewArchivePanel()
                        } label: {
                            Label("新建压缩包", systemImage: "archivebox")
                        }
                        .controlSize(.large)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(40)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
            // Only claim the drop when there is something we can actually read;
            // returning `true` unconditionally made an unusable drop look like
            // it had been accepted, with nothing happening afterwards.
            guard providers.contains(where: {
                $0.canLoadObject(ofClass: URL.self)
                    || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }) else {
                model.reportUnusableDrop()
                return false
            }

            Panels.loadFileURLs(from: providers) { urls in
                if urls.isEmpty {
                    model.reportUnusableDrop()
                } else {
                    model.handleDrop(urls: urls)
                }
            }
            return true
        }
    }

    private var toolIcon: String {
        if isTargeted { return "arrow.down.doc.fill" }
        switch model.toolStatus {
        case .checking: return "hourglass"
        case .ready: return "doc.zipper"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private var headline: String {
        if isTargeted { return "松开即可" }
        switch model.toolStatus {
        case .checking: return "正在检测 7zz…"
        case .ready: return "拖入文件或文件夹"
        case .unavailable: return "找不到 7zz"
        }
    }

    private var subheadline: String {
        if isTargeted { return "压缩包将被打开，其他文件将被压缩" }
        switch model.toolStatus {
        case .checking:
            return "正在查找随应用附带的 7-Zip 引擎。"
        case .ready(let version, _):
            return """
            拖入压缩包可直接浏览与解压；拖入其他文件则会打开压缩设置。
            当前引擎：7-Zip \(version)
            """
        case .unavailable(let message):
            return """
            \(message)

            请确认应用包内 Contents/Resources 下有 7zz，\
            或通过环境变量 ARCHIVE_BINARY 指定路径。
            """
        }
    }
}
