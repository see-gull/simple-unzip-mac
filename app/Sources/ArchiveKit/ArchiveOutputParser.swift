import Foundation

/// A single progress sample decoded from `7zz` output.
public struct TaskProgress: Equatable {
    /// Completion in the range 0...1, when `7zz` has reported a percentage.
    public var fraction: Double?
    /// Items processed so far, as reported next to the percentage.
    public var itemCount: Int?
    /// The item `7zz` is currently working on.
    public var currentItem: String?

    public init(fraction: Double? = nil, itemCount: Int? = nil, currentItem: String? = nil) {
        self.fraction = fraction
        self.itemCount = itemCount
        self.currentItem = currentItem
    }
}

/// Decodes the interleaved stream that `7zz` writes to stdout and stderr.
///
/// Two shapes arrive on the same pipe:
///   * newline-terminated log lines ("Extracting archive: x.7z", "ERROR: ...")
///   * a percentage gauge with **no** line terminator, rewritten in place by
///     emitting backspaces
///
/// Log lines are emitted as they complete. Progress is taken from the *last*
/// percentage token in the pending buffer, because everything before it has
/// already been erased on the real terminal.
public final class ArchiveOutputParser {
    /// Bounds the pending (unterminated) buffer so a chatty archive cannot grow it forever.
    private static let pendingLimit = 8192

    private static let progressRegex = try! NSRegularExpression(
        pattern: #"(\d{1,3})%(?:\s+(\d+))?(?:\s*([+-])\s*([^\n\r]*))?"#
    )

    /// Used to locate every gauge start before deciding which one is current.
    private static let percentOnlyRegex = try! NSRegularExpression(pattern: #"\d{1,3}%"#)

    /// Cap on retained raw output, so a huge listing cannot exhaust memory.
    private static let rawLimit = 16 * 1024 * 1024

    private var pending = ""
    private let lock = NSLock()

    /// Everything received, unmodified except for the backspace erasures.
    /// `l -slt` output is parsed from here.
    public private(set) var rawOutput = ""
    public private(set) var messages: [String] = []
    public private(set) var errors: [String] = []
    public private(set) var lastProgress = TaskProgress()
    public private(set) var sawCompletionMarker = false

    /// Exit status of the process that produced this output; set by the engine.
    public internal(set) var exitCode: Int32 = 0

    public var onProgress: ((TaskProgress) -> Void)?
    public var onMessage: ((String) -> Void)?
    public var onError: ((String) -> Void)?

    public init() {}

    public func feed(_ chunk: String) {
        lock.lock()
        pending.append(chunk)
        if rawOutput.count < Self.rawLimit {
            rawOutput.append(chunk.replacingOccurrences(of: "\u{8}", with: ""))
        }

        // Pull off every complete line first.
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
            lock.unlock()
            handleLine(line)
            lock.lock()
        }

        if let progress = extractLastProgress(from: pending) {
            lastProgress = progress
            let sink = onProgress
            lock.unlock()
            sink?(progress)
            lock.lock()
        }

        if pending.count > Self.pendingLimit {
            pending = String(pending.suffix(Self.pendingLimit))
        }
        lock.unlock()
    }

    /// Flushes any trailing partial line; call once the process has exited.
    public func finish() {
        lock.lock()
        let remainder = pending
        pending = ""
        lock.unlock()
        if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            handleLine(remainder)
        }
    }

    public var hadErrors: Bool { !errors.isEmpty }

    private func handleLine(_ rawLine: String) {
        let line = Self.clean(rawLine)
        guard !line.isEmpty else { return }

        if line.contains("Everything is Ok") {
            sawCompletionMarker = true
        }

        let lowered = line.lowercased()
        let isFailure = MessageClassifier.isError(line)
            || lowered.hasPrefix("sub items errors")
            || lowered.contains("archives with errors")

        lock.lock()
        if isFailure {
            errors.append(line)
        } else {
            messages.append(line)
        }
        lock.unlock()

        if isFailure {
            onError?(line)
        } else {
            onMessage?(line)
        }
    }

    /// Removes backspace erasure and control noise from a raw line.
    static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\u{8}", "\u{7}", "\u{0}":
                continue
            case "\r":
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// Finds the final `NN% ...` gauge in the pending buffer.
    ///
    /// The item capture must not run past the next gauge, or a buffer holding
    /// two gauges would report the *earlier* percentage and a concatenated
    /// "filename". Since backspaces are stripped before matching, gauges end up
    /// separated only by spaces, so the search anchors on the last `NN%` and
    /// parses forward from there.
    func extractLastProgress(from buffer: String) -> TaskProgress? {
        let text = buffer.replacingOccurrences(of: "\u{8}", with: "")
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }

        let percentMatches = Self.percentOnlyRegex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard let lastPercent = percentMatches.last else { return nil }

        let tail = nsText.substring(from: lastPercent.range.location)
        let tailRange = NSRange(location: 0, length: (tail as NSString).length)
        guard let match = Self.progressRegex.firstMatch(in: tail, range: tailRange) else { return nil }
        guard let percentRange = Range(match.range(at: 1), in: tail),
              let percent = Double(tail[percentRange]) else { return nil }

        var count: Int?
        if match.range(at: 2).location != NSNotFound,
           let countRange = Range(match.range(at: 2), in: tail) {
            count = Int(tail[countRange])
        }

        var item: String?
        if match.range(at: 4).location != NSNotFound,
           let itemRange = Range(match.range(at: 4), in: tail) {
            let candidate = Self.clean(String(tail[itemRange]))
            if !candidate.isEmpty { item = candidate }
        }

        let fraction = min(max(percent / 100.0, 0), 1)
        return TaskProgress(fraction: fraction, itemCount: count, currentItem: item)
    }
}
