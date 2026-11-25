import AppKit
import DiffReviewCore
import Observation

/// One "Ask Claude" conversation. Its first message forks the Claude Code session that opened
/// the review (when there is one), so it answers knowing how the code came to be; follow-ups
/// continue the fork. The session that opened the review is never changed.
@MainActor
@Observable
final class Chat: Identifiable {
    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        /// What the user typed (user messages).
        var text: String
        var answer = ChatAnswer()
    }

    let id = UUID()
    let context: ChatContext
    var messages: [Message] = []
    /// This chat's own session, once Claude has started it.
    var sessionID: String?
    /// The chat began as a copy of the reviewing session (false: a fresh session).
    var isForked: Bool
    /// Why the reviewing session couldn't be forked, when the chat fell back to a fresh one.
    var forkError: String?
    var isRunning: Bool { process != nil }
    var draft = ""

    @ObservationIgnored fileprivate var process: Process?

    init(context: ChatContext, isForked: Bool) {
        self.context = context
        self.isForked = isForked
    }
}

@MainActor
@Observable
final class ChatStore {
    var chats: [Chat] = []
    var activeID: UUID?
    var isOpen = false

    /// The `claude` executable; nil when it isn't installed, and asking is unavailable.
    let claudePath: String?
    /// The Claude Code session that opened the review.
    let parentSession: String?
    /// What's under review, named in each chat's first message.
    private let reviewing: String
    private let directory: URL
    /// Each `claude` run is recorded here (arguments, exit status, stderr, and the output
    /// lines that aren't streamed text), so a failure can be looked into after the fact.
    private let logURL: URL

    init(directory: URL, gitDir: URL, reviewing: String, sessionArgument: String?) {
        let env = ProcessInfo.processInfo.environment
        self.directory = directory
        self.logURL = gitDir.appendingPathComponent("diffreview/chats.log")
        self.reviewing = reviewing
        parentSession = ClaudeCommand.parentSession(argument: sessionArgument, environment: env)
        claudePath = ClaudeCommand.locate(environment: env, home: NSHomeDirectory())
    }

    var isAvailable: Bool { claudePath != nil }
    var active: Chat? { chats.first { $0.id == activeID } }

    /// Opens a new chat about `context` and sends the question.
    func ask(_ question: String, about context: ChatContext) {
        let chat = Chat(context: context, isForked: parentSession != nil)
        chats.append(chat)
        activeID = chat.id
        isOpen = true
        send(question, in: chat)
    }

    func send(_ text: String, in chat: Chat) {
        let question = ChatPrompt.followUp(text)
        guard !question.isEmpty, !chat.isRunning else { return }
        chat.messages.append(.init(role: .user, text: question))
        chat.messages.append(.init(role: .assistant, text: ""))
        // Until Claude has started the chat's session (or if it never did), a message is the
        // chat's first: it carries the code it's about.
        if let session = chat.sessionID {
            run(question, resume: session, fork: false, in: chat)
        } else {
            let prompt = ChatPrompt.first(question: question, context: chat.context, reviewing: reviewing)
            run(prompt, resume: chat.isForked ? parentSession : nil, fork: true, in: chat)
        }
    }

    func stop(_ chat: Chat) {
        chat.process?.terminate()
    }

    /// Removes a chat (stopping its answer); if it was open, the sidebar goes back to the list.
    func delete(_ chat: Chat) {
        stop(chat)
        chats.removeAll { $0.id == chat.id }
        if activeID == chat.id { activeID = nil }
    }

    /// Back to the list of chats.
    func collapse() {
        activeID = nil
    }

    /// Before the app exits: no `claude` is left running on its own.
    func stopAll() {
        for chat in chats { chat.process?.terminate() }
    }

    // MARK: - Running claude

    private func run(_ prompt: String, resume: String?, fork: Bool, in chat: Chat) {
        guard let claudePath else {
            finish(chat, error: "The claude command wasn't found on PATH or in ~/.local/bin.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ClaudeCommand.arguments(resume: resume, fork: fork)
        process.environment = ClaudeCommand.environment(ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = directory

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let reader = LineReader()
        let notable = ErrorCollector()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            let lines = data.isEmpty ? reader.finish() : reader.append(data)
            if data.isEmpty { handle.readabilityHandler = nil }
            guard !lines.isEmpty else { return }
            // Streamed text and whole assistant messages are the answer, shown in the chat;
            // everything else (init, results, plain-text errors) goes to the log.
            for line in lines where !line.hasPrefix(#"{"type":"stream_event""#) && !line.hasPrefix(#"{"type":"assistant""#) {
                notable.append(Data((String(line.prefix(4000)) + "\n").utf8))
            }
            let events = lines.flatMap(ClaudeStream.parse)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(events, to: chat) }
            }
        }
        let errors = ErrorCollector()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errors.append(data) }
        }
        let arguments = process.arguments ?? []
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            // Let the last output lines arrive before deciding how the turn ended.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    self?.log("""
                        claude \(arguments.joined(separator: " "))
                        exit status: \(status)\(reason == .uncaughtSignal ? " (signal)" : "")
                        stderr:
                        \(errors.text)
                        output:
                        \(notable.text)
                        """)
                    self?.ended(chat, status: status, stopped: reason == .uncaughtSignal,
                                stderr: errors.text, resume: resume, fork: fork, prompt: prompt)
                }
            }
        }

        do {
            try process.run()
        } catch {
            finish(chat, error: "Couldn't start claude: \(error.localizedDescription)")
            return
        }
        chat.process = process
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()
    }

    private func apply(_ events: [ClaudeEvent], to chat: Chat) {
        guard let last = chat.messages.indices.last else { return }
        for event in events {
            switch event {
            case .session(let id):
                chat.sessionID = id
            case .result(_, _, let session?):
                chat.sessionID = session
            default:
                break
            }
            chat.messages[last].answer.apply(event)
        }
    }

    private func ended(_ chat: Chat, status: Int32, stopped: Bool, stderr: String,
                       resume: String?, fork: Bool, prompt: String) {
        chat.process = nil
        guard let last = chat.messages.indices.last else { return }
        var answer = chat.messages[last].answer
        // The reviewing session couldn't be forked (it may not have been saved yet):
        // ask again in a fresh session, which only knows the code.
        if fork, resume != nil, !stopped, answer.text.isEmpty, status != 0 || answer.error != nil {
            let reason = answer.error ?? stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            chat.forkError = reason.isEmpty ? "claude exited with status \(status)." : reason
            chat.isForked = false
            chat.sessionID = nil
            chat.messages[last].answer = ChatAnswer()
            run(prompt, resume: nil, fork: true, in: chat)
            return
        }
        guard !answer.isDone else { return }
        if stopped {
            answer.apply(.result(text: answer.text.isEmpty ? "Stopped." : "", isError: answer.text.isEmpty, session: nil))
        } else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            answer.apply(.result(text: message.isEmpty ? "claude exited with status \(status)." : message,
                                 isError: true, session: nil))
        }
        chat.messages[last].answer = answer
    }

    /// Appends an entry to the log; failing to write it never gets in the way of a chat.
    private func log(_ entry: String) {
        let text = "=== \(Date().formatted(.iso8601))\n\(entry)\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Kept small: past 1 MB it starts over.
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        if size < 1_000_000, let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: logURL)
        }
    }

    private func finish(_ chat: Chat, error: String) {
        guard let last = chat.messages.indices.last else { return }
        chat.messages[last].answer.apply(.result(text: error, isError: true, session: nil))
    }
}

/// Cuts stdout into lines; called from the pipe's reading thread only.
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    func finish() -> [String] {
        defer { buffer = Data() }
        return buffer.isEmpty ? [] : [String(decoding: buffer, as: UTF8.self)]
    }
}

/// stderr, collected on the pipe's thread and read once the process has ended.
private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
