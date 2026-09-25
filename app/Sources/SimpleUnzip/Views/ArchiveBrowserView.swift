import ArchiveKit
import SwiftUI

/// One visible line of the outline, flattened with its indent depth.
private struct FlatRow: Identifiable {
    let id: String
    let node: ArchiveTreeNode
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
}

struct ArchiveBrowserView: View {
    @EnvironmentObject private var model: AppModel
    let archive: URL
    let listing: ArchiveListing

    @State private var expanded: Set<String> = []
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                columnHeader
                Divider()
                entryList
            }
            Divider()
            footer
        }
        .onAppear(perform: expandTopLevel)
        .onChange(of: archive) { _ in
            expanded = []
            filter = ""
            expandTopLevel()
        }
        // A row that the filter hides must not stay selected: "解压所选" would
        // otherwise extract entries the user can no longer see.
        .onChange(of: filter) { _ in
            let visible = Set(rows.map(\.id))
            model.selection.formIntersection(visible)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.zipper")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(archive.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("筛选", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(width: 150)
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var columnHeader: some View {
        HStack(spacing: 6) {
            Text("名称")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("大小")
                .frame(width: 90, alignment: .trailing)
            Text("修改日期")
                .frame(width: 132, alignment: .leading)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
    }

    private var entryList: some View {
        List(selection: $model.selection) {
            ForEach(rows) { row in
                EntryRow(row: row) {
                    toggle(row.node)
                }
                .tag(row.id)
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 20)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: filter.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(filter.isEmpty ? "这个压缩包是空的" : "没有匹配「\(filter)」的项目")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.selection.isEmpty
                 ? "共 \(DisplayFormat.count(listing.entries.count)) 项"
                 : "已选 \(DisplayFormat.count(model.selection.count)) 项")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.selection.isEmpty {
                Button("全不选") { model.selection = [] }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            Spacer()

            Button("解压所选…") {
                model.beginExtractionOfSelection()
            }
            .disabled(model.selection.isEmpty)

            Button("全部解压…") {
                model.beginExtraction(of: archive)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Derived state

    private var summaryLine: String {
        var parts: [String] = []
        if let type = listing.properties.type { parts.append(type.uppercased()) }
        parts.append("\(DisplayFormat.count(listing.fileCount)) 个文件")
        parts.append("\(DisplayFormat.count(listing.folderCount)) 个文件夹")
        parts.append("原始 \(DisplayFormat.bytesAlways(listing.totalUncompressedSize))")
        if let packed = listing.properties.physicalSize {
            parts.append("压缩后 \(DisplayFormat.bytesAlways(packed))")
            parts.append("压缩率 \(DisplayFormat.compressionRatio(uncompressed: listing.totalUncompressedSize, compressed: packed))")
        }
        if listing.properties.isSolid { parts.append("固实") }
        if listing.isEncrypted { parts.append("加密") }
        return parts.joined(separator: " · ")
    }

    private var rows: [FlatRow] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty else {
            // A filter turns the outline into a flat list of matching paths.
            // Rows still borrow the real tree node, so a matched folder shows
            // its true subtree size instead of the 0 of a synthetic leaf.
            let index = nodesByPath
            return listing.entries
                .filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
                .map { entry in
                    FlatRow(
                        id: entry.path,
                        node: index[entry.path] ?? ArchiveTreeNode(
                            name: entry.name,
                            path: entry.path,
                            entry: entry,
                            children: []
                        ),
                        depth: 0,
                        hasChildren: false,
                        isExpanded: false
                    )
                }
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }

        var result: [FlatRow] = []
        flatten(model.tree, depth: 0, into: &result)
        return result
    }

    /// Every node of the current tree, keyed by in-archive path.
    private var nodesByPath: [String: ArchiveTreeNode] {
        var index: [String: ArchiveTreeNode] = [:]
        func walk(_ nodes: [ArchiveTreeNode]) {
            for node in nodes {
                index[node.path] = node
                walk(node.children)
            }
        }
        walk(model.tree)
        return index
    }

    private func flatten(_ nodes: [ArchiveTreeNode], depth: Int, into result: inout [FlatRow]) {
        for node in nodes {
            let hasChildren = !node.children.isEmpty
            let isExpanded = expanded.contains(node.id)
            result.append(
                FlatRow(id: node.id, node: node, depth: depth,
                        hasChildren: hasChildren, isExpanded: isExpanded)
            )
            if hasChildren && isExpanded {
                flatten(node.children, depth: depth + 1, into: &result)
            }
        }
    }

    private func toggle(_ node: ArchiveTreeNode) {
        if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else {
            expanded.insert(node.id)
        }
    }

    private func expandTopLevel() {
        for node in model.tree where !node.children.isEmpty {
            expanded.insert(node.id)
        }
    }
}

private struct EntryRow: View {
    let row: FlatRow
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)

            if row.hasChildren {
                Button(action: onToggle) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }

            Image(systemName: row.node.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(row.node.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 14)

            Text(row.node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            if row.node.entry?.isEncrypted == true {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 12)

            Text(sizeText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)

            Text(DisplayFormat.date(row.node.modified))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }

    private var sizeText: String {
        if row.node.isDirectory {
            return DisplayFormat.bytes(row.node.aggregateSize)
        }
        return DisplayFormat.bytes(row.node.entry?.size)
    }
}
