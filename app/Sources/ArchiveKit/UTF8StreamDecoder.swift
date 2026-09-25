import Foundation

/// Incremental UTF-8 decode that survives multi-byte characters split across
/// two reads from the child process pipe.
final class UTF8StreamDecoder {
    private var carry: [UInt8] = []

    func decode(_ data: Data) -> String {
        var bytes = carry
        bytes.append(contentsOf: data)
        carry = []

        // Walk back over at most one UTF-8 scalar to find its leading byte.
        // When that sequence is not complete yet, the whole sequence is held
        // back rather than decoded into U+FFFD.
        var complete = bytes.count
        var index = bytes.count - 1
        var steps = 0
        while index >= 0 && steps < 4 {
            let byte = bytes[index]
            if byte & 0b1100_0000 == 0b1000_0000 {
                // Continuation byte: keep walking back to the leading byte.
                index -= 1
                steps += 1
                continue
            }
            let needed: Int
            switch byte {
            case 0x00...0x7F: needed = 1
            case 0xC0...0xDF: needed = 2
            case 0xE0...0xEF: needed = 3
            case 0xF0...0xF7: needed = 4
            default: needed = 1
            }
            if bytes.count - index < needed {
                complete = index
            }
            break
        }

        let head = bytes[0..<complete]
        carry = Array(bytes[complete...])
        return String(decoding: head, as: UTF8.self)
    }

    func flush() -> String {
        defer { carry = [] }
        return String(decoding: carry, as: UTF8.self)
    }
}

/// A cancellable handle shared between the UI and a running child process.
///
/// All mutable state sits behind `NSLock`, so sharing it across threads — which
/// is exactly how the cancel button reaches a running child — is safe.
public final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (() -> Void)?

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Registers the action that actually stops the work. If cancellation was
    /// already requested the action runs immediately.
    func attach(_ action: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            action()
            return
        }
        handler = action
        lock.unlock()
    }

    func detach() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let action = handler
        lock.unlock()
        action?()
    }
}
