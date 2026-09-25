import Foundation

/// Runs one `7zz` invocation and streams its merged output.
///
/// `7zz` writes live progress to stdout as `NN% <count> + <name>` followed by a
/// run of backspaces that erases the line again. Routing stdout is enough to
/// receive it; no pseudo-terminal is required.
public final class RunningProcess {
    private let process = Process()
    private let pipe = Pipe()
    private let stateLock = NSLock()
    private let decoder = UTF8StreamDecoder()

    private var onText: ((String) -> Void)?
    private var completion: ((Result<Int32, Error>) -> Void)?
    private var outputClosed = false
    private var processExited = false
    private var exitCode: Int32 = 0
    private var finished = false
    private var cancelled = false

    public let executableURL: URL
    public let arguments: [String]

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments

        process.executableURL = executableURL
        process.arguments = arguments
        // 7-Zip records item paths relative to the working directory, so the
        // engine sets it to the sources' common parent to keep archives flat.
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe

        var env = environment ?? ProcessInfo.processInfo.environment
        // Pin the locale so progress and error strings stay parseable, and ask
        // 7-Zip for UTF-8 console output so non-ASCII paths survive the pipe.
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        env["TERM"] = "dumb"
        process.environment = env
    }

    /// The exact command line, for logs and the task inspector.
    public var commandLine: String {
        ([executableURL.path] + arguments)
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
    }

    public var isRunning: Bool {
        process.isRunning
    }

    public func start(
        onText: @escaping (String) -> Void,
        completion: @escaping (Result<Int32, Error>) -> Void
    ) {
        stateLock.lock()
        self.onText = onText
        self.completion = completion
        stateLock.unlock()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.markOutputClosed()
            } else {
                self.stateLock.lock()
                let text = self.decoder.decode(data)
                let sink = self.onText
                self.stateLock.unlock()
                if !text.isEmpty { sink?(text) }
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stateLock.lock()
            self.exitCode = proc.terminationStatus
            self.processExited = true
            self.stateLock.unlock()
            self.settleIfReady()
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            stateLock.lock()
            // Shadow the parameters with optionals so the same call shape works
            // as in the success path.
            let sink: ((Result<Int32, Error>) -> Void)? = completion
            finished = true
            self.completion = nil
            self.onText = nil
            stateLock.unlock()
            sink?(.failure(ArchiveError.launchFailed(error.localizedDescription)))
            return
        }

        // The child now owns duplicated copies of the pipe's write end. The
        // parent must drop its own copy or `availableData` never reports EOF.
        pipe.fileHandleForWriting.closeFile()
    }

    private func markOutputClosed() {
        stateLock.lock()
        outputClosed = true
        stateLock.unlock()
        settleIfReady()
    }

    private func settleIfReady() {
        stateLock.lock()
        guard !finished, outputClosed, processExited else {
            stateLock.unlock()
            return
        }
        finished = true
        let sink = completion
        let textSink = onText
        let code = exitCode
        let wasCancelled = cancelled
        let trailing = decoder.flush()
        completion = nil
        onText = nil
        stateLock.unlock()

        if !trailing.isEmpty { textSink?(trailing) }
        // Cancellation only counts if the child actually failed to finish. A
        // cancel that loses the race against an already-exited process (exit 0,
        // output written) must report success: telling the user "已取消" while
        // the archive sits on disk hides a real result.
        let cancelledInTime = wasCancelled && code != 0
        sink?(cancelledInTime ? .failure(ArchiveError.cancelled) : .success(code))
    }

    /// Asks `7zz` to stop, escalating to SIGKILL if it does not exit promptly.
    public func cancel() {
        stateLock.lock()
        cancelled = true
        let running = process.isRunning
        let pid = process.processIdentifier
        stateLock.unlock()
        guard running else { return }

        process.terminate() // SIGTERM
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stillRunning = self.process.isRunning
            self.stateLock.unlock()
            if stillRunning { kill(pid, SIGKILL) }
        }
    }
}
