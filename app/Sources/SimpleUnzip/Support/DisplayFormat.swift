import Foundation

enum DisplayFormat {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// `nil` means "unknown" and prints as an em dash. A real `0` is not
    /// unknown — a zero-byte file exists and is empty — so it must print as
    /// `Zero bytes`, not as `—`.
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return byteFormatter.string(fromByteCount: value)
    }

    static func bytesAlways(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return dateFormatter.string(from: value)
    }

    static func count(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    /// Ratio of compressed to original size, e.g. `42%`.
    static func compressionRatio(uncompressed: Int64, compressed: Int64?) -> String {
        guard let compressed, uncompressed > 0 else { return "—" }
        let ratio = Double(compressed) / Double(uncompressed) * 100
        return String(format: "%.0f%%", ratio)
    }
}
