import Foundation

/// Archive-level metadata printed in the `l -slt` header block.
public struct ArchiveProperties: Equatable {
    public var type: String?
    public var physicalSize: Int64?
    public var headersSize: Int64?
    public var method: String?
    public var isSolid: Bool = false
    public var blockCount: Int?
    public var raw: [String: String] = [:]

    public init() {}
}

/// One item inside an archive.
public struct ArchiveEntry: Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let size: Int64
    public let packedSize: Int64?
    public let modified: Date?
    public let attributes: String
    public let crc: String?
    public let method: String?
    public let isDirectory: Bool
    public let isEncrypted: Bool

    public init(
        path: String,
        size: Int64,
        packedSize: Int64?,
        modified: Date?,
        attributes: String,
        crc: String?,
        method: String?,
        isDirectory: Bool,
        isEncrypted: Bool
    ) {
        self.path = path
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.attributes = attributes
        self.crc = crc
        self.method = method
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
    }

    /// Final path component.
    public var name: String {
        (path as NSString).lastPathComponent
    }

    /// Directory portion, `""` for top-level items.
    public var parentPath: String {
        (path as NSString).deletingLastPathComponent
    }
}

/// The parsed result of `7zz l -slt`.
public struct ArchiveListing {
    public var entries: [ArchiveEntry]
    public var properties: ArchiveProperties

    public init(entries: [ArchiveEntry], properties: ArchiveProperties) {
        self.entries = entries
        self.properties = properties
    }

    public var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    public var folderCount: Int { entries.filter { $0.isDirectory }.count }
    public var totalUncompressedSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    public var isEncrypted: Bool {
        if properties.method?.lowercased().contains("aes") == true { return true }
        return entries.contains { $0.isEncrypted }
    }

    /// Parses `7zz l -slt` output.
    ///
    /// The listing is a preamble, an optional header block introduced by `--`,
    /// then `----------` and a sequence of blank-line separated `Key = Value`
    /// records.
    public static func parse(_ text: String) -> ArchiveListing {
        enum Section { case preamble, header, entries }
        var section: Section = .preamble

        var properties = ArchiveProperties()
        var entries: [ArchiveEntry] = []
        var current: [String: String] = [:]

        func commit() {
            guard let path = current["Path"], !path.isEmpty else {
                current = [:]
                return
            }
            entries.append(Self.makeEntry(path: path, fields: current))
            current = [:]
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            if line == "----------" {
                commit()
                section = .entries
                continue
            }
            if line == "--", section == .preamble {
                section = .header
                continue
            }

            if line.isEmpty {
                if section == .entries { commit() }
                continue
            }

            guard let separator = line.range(of: " = ") else { continue }
            let key = String(line[line.startIndex..<separator.lowerBound])
            let value = String(line[separator.upperBound...])

            switch section {
            case .preamble:
                continue
            case .header:
                properties.raw[key] = value
                switch key {
                case "Type": properties.type = value
                case "Physical Size": properties.physicalSize = Int64(value)
                case "Headers Size": properties.headersSize = Int64(value)
                case "Method": properties.method = value
                case "Solid": properties.isSolid = (value == "+")
                case "Blocks": properties.blockCount = Int(value)
                default: break
                }
            case .entries:
                // A new `Path` always starts a new record even if the blank
                // separator line was absent.
                if key == "Path", current["Path"] != nil {
                    commit()
                }
                current[key] = value
            }
        }
        commit()

        return ArchiveListing(entries: entries, properties: properties)
    }

    private static func makeEntry(path: String, fields: [String: String]) -> ArchiveEntry {
        let attributes = fields["Attributes"] ?? ""
        let isDirectory = attributes.hasPrefix("D") || fields["Folder"] == "+"
        let size = Int64(fields["Size"] ?? "") ?? 0
        let packed = Int64(fields["Packed Size"] ?? "")
        let encrypted = (fields["Encrypted"] == "+")
            || (fields["Method"]?.lowercased().contains("aes") ?? false)
        let method = (fields["Method"]?.isEmpty == false) ? fields["Method"] : nil
        let crc = (fields["CRC"]?.isEmpty == false) ? fields["CRC"] : nil

        return ArchiveEntry(
            path: path,
            size: size,
            packedSize: packed,
            modified: parseTimestamp(fields["Modified"]),
            attributes: attributes,
            crc: crc,
            method: method,
            isDirectory: isDirectory,
            isEncrypted: encrypted
        )
    }

    /// Parses the timestamps `7zz` prints, e.g. `2026-09-24 23:24:58.2549524`.
    /// Fractional digits vary in length and the fraction may be absent.
    public static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: " ")
        let datePart = parts[0].split(separator: "-")
        guard datePart.count == 3,
              let year = Int(datePart[0]),
              let month = Int(datePart[1]),
              let day = Int(datePart[2]) else { return nil }

        var hour = 0, minute = 0, second = 0
        var nanosecond = 0
        if parts.count > 1 {
            let timeParts = parts[1].split(separator: ".")
            let hms = timeParts[0].split(separator: ":")
            if hms.count == 3 {
                hour = Int(hms[0]) ?? 0
                minute = Int(hms[1]) ?? 0
                second = Int(hms[2]) ?? 0
            }
            if timeParts.count > 1 {
                let digits = String(timeParts[1]).prefix(9)
                let padded = digits.padding(toLength: 9, withPad: "0", startingAt: 0)
                nanosecond = Int(padded) ?? 0
            }
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        return Calendar.current.date(from: components)
    }
}

/// A directory tree built from a flat listing, for outline display.
public final class ArchiveTreeNode: Identifiable {
    public let id: String
    public let name: String
    public let path: String
    public let entry: ArchiveEntry?
    public private(set) var children: [ArchiveTreeNode]

    public init(name: String, path: String, entry: ArchiveEntry?, children: [ArchiveTreeNode]) {
        self.id = path
        self.name = name
        self.path = path
        self.entry = entry
        self.children = children
    }

    public var isDirectory: Bool { entry?.isDirectory ?? true }
    public var size: Int64 { entry?.size ?? 0 }
    public var modified: Date? { entry?.modified }

    /// Total size of this node's subtree.
    public var aggregateSize: Int64 {
        if let entry, !entry.isDirectory { return entry.size }
        return children.reduce(0) { $0 + $1.aggregateSize }
    }
}

public enum ArchiveTreeBuilder {
    /// Builds a sorted tree; implicit intermediate directories are synthesised.
    public static func build(from listing: ArchiveListing) -> [ArchiveTreeNode] {
        final class Mutable {
            let name: String
            let path: String
            var entry: ArchiveEntry?
            var children: [String: Mutable] = [:]
            init(name: String, path: String, entry: ArchiveEntry?) {
                self.name = name
                self.path = path
                self.entry = entry
            }
        }

        let root = Mutable(name: "", path: "", entry: nil)

        for entry in listing.entries {
            let components = entry.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty else { continue }

            var node = root
            var accumulated = ""
            for (index, component) in components.enumerated() {
                accumulated = accumulated.isEmpty ? component : accumulated + "/" + component
                let isLeaf = (index == components.count - 1)
                if let existing = node.children[component] {
                    if isLeaf { existing.entry = entry }
                    node = existing
                } else {
                    let created = Mutable(
                        name: component,
                        path: accumulated,
                        entry: isLeaf ? entry : nil
                    )
                    node.children[component] = created
                    node = created
                }
            }
        }

        func freeze(_ node: Mutable) -> ArchiveTreeNode {
            let kids = node.children.values
                .map(freeze)
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            return ArchiveTreeNode(
                name: node.name,
                path: node.path,
                entry: node.entry,
                children: kids
            )
        }

        return root.children.values
            .map(freeze)
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
