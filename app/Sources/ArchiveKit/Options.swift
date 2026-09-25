import Foundation

/// Formats the GUI can create.
public enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case sevenZip = "7z"
    case zip = "zip"
    case tar = "tar"
    case tarGzip = "tar.gz"
    case tarBzip2 = "tar.bz2"
    case tarXz = "tar.xz"
    case gzip = "gz"
    case bzip2 = "bz2"
    case xz = "xz"
    case wim = "wim"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sevenZip: return "7z"
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .tarGzip: return "TAR.GZ"
        case .tarBzip2: return "TAR.BZ2"
        case .tarXz: return "TAR.XZ"
        case .gzip: return "GZIP"
        case .bzip2: return "BZIP2"
        case .xz: return "XZ"
        case .wim: return "WIM"
        }
    }

    public var fileExtension: String { rawValue }

    /// The `-t` value passed to `7zz` for the compressing step.
    var sevenZipTypeName: String {
        switch self {
        case .sevenZip: return "7z"
        case .zip: return "zip"
        case .tar: return "tar"
        case .tarGzip: return "gzip"
        case .tarBzip2: return "bzip2"
        case .tarXz: return "xz"
        case .gzip: return "gzip"
        case .bzip2: return "bzip2"
        case .xz: return "xz"
        case .wim: return "wim"
        }
    }

    /// tar.* containers are produced by tarring first, then compressing.
    public var requiresTarStage: Bool {
        switch self {
        case .tarGzip, .tarBzip2, .tarXz: return true
        default: return false
        }
    }

    /// Whether a password can be applied by 7-Zip for this format.
    public var supportsEncryption: Bool {
        switch self {
        case .sevenZip, .zip: return true
        default: return false
        }
    }

    /// Whether the user may choose a compression level that matters.
    public var supportsCompressionLevel: Bool {
        switch self {
        case .tar: return false
        default: return true
        }
    }
}

/// How `7zz` should treat a file that already exists at the destination.
public enum OverwriteMode: String, CaseIterable, Identifiable, Sendable {
    case overwrite
    case skip
    case renameExisting
    case renameNew

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .overwrite: return "覆盖"
        case .skip: return "跳过已存在"
        case .renameExisting: return "重命名已存在文件"
        case .renameNew: return "重命名新文件"
        }
    }

    /// The `-ao*` switch value.
    var switchValue: String {
        switch self {
        case .overwrite: return "-aoa"
        case .skip: return "-aos"
        case .renameExisting: return "-aot"
        case .renameNew: return "-aou"
        }
    }
}

/// Parameters for creating an archive.
public struct CompressionRequest: Sendable {
    public var sources: [URL]
    public var destination: URL
    public var format: ArchiveFormat = .sevenZip
    /// 0 (store) through 9 (ultra).
    public var level: Int = 5
    public var password: String?
    public var encryptFileNames: Bool = false
    public var splitVolumeSize: String?
    public var excludeMacJunk: Bool = true

    public init(sources: [URL], destination: URL) {
        self.sources = sources
        self.destination = destination
    }

    /// The `-mx` value.
    var levelArgument: String { "-mx\(min(max(level, 0), 9))" }
}

/// Parameters for extracting an archive.
public struct ExtractionRequest: Sendable {
    public var archive: URL
    public var destination: URL
    public var password: String?
    public var overwrite: OverwriteMode = .overwrite
    /// When non-empty, only these in-archive paths are extracted.
    public var selectedPaths: [String] = []
    /// Flatten the directory structure (`7zz e`) instead of restoring it (`7zz x`).
    public var flattenPaths: Bool = false

    public init(archive: URL, destination: URL) {
        self.archive = archive
        self.destination = destination
    }
}
