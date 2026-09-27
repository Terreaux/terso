// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

/// Runs an executable with an argument vector — never through a shell — and
/// feeds input on stdin. Supports timeout and cooperative cancellation.
public enum ProcessRunner {
    public static func run(executable: URL, arguments: [String], stdin: Data, environment: [String: String],
                           workingDirectory: URL, timeout: TimeInterval) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var out = Data(), err = Data(), timedOut = false
        }
        let box = Box()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            box.lock.withLock { box.out.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            box.lock.withLock { box.err.append(d) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let restOut = (try? outPipe.fileHandleForReading.readToEnd()) ?? nil
                    let restErr = (try? errPipe.fileHandleForReading.readToEnd()) ?? nil
                    let (out, err, timedOut) = box.lock.withLock { () -> (Data, Data, Bool) in
                        if let restOut { box.out.append(restOut) }
                        if let restErr { box.err.append(restErr) }
                        return (box.out, box.err, box.timedOut)
                    }
                    if timedOut { cont.resume(throwing: ProviderError.timedOut(timeout)); return }
                    if Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                    cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: out, stderr: err))
                }
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: ProviderError.executableNotFound("\(executable.path): \(error.localizedDescription)"))
                    return
                }
                DispatchQueue.global().async {
                    try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                    try? inPipe.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        box.lock.withLock { box.timedOut = true }
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Resolve a bare command name against PATH plus the usual install
    /// locations (GUI apps inherit a minimal PATH).
    public static func locate(_ command: String, extraPaths: [String] = []) -> URL? {
        let fm = FileManager.default
        if command.contains("/") {
            let url = URL(fileURLWithPath: (command as NSString).expandingTildeInPath)
            return fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = extraPaths + path + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.claude/local", "/usr/bin"]
        for dir in candidates {
            let p = (dir as NSString).appendingPathComponent(command)
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }
}

/// Settings for a command-line assistant such as Codex CLI or Claude Code.
public struct CLIProviderConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var command: String
    /// Arguments; `{workspace}` and `{output}` are substituted. The prompt is
    /// always delivered on stdin, never as an argument.
    public var arguments: [String]
    /// When set, the reply is read from `{output}` instead of stdout.
    public var readsOutputFile: Bool
    public var timeout: TimeInterval
    /// Extra environment variables (non-secret).
    public var environment: [String: String]

    public init(id: String, displayName: String, command: String, arguments: [String], readsOutputFile: Bool = false,
                timeout: TimeInterval = 180, environment: [String: String] = [:]) {
        self.id = id; self.displayName = displayName; self.command = command; self.arguments = arguments
        self.readsOutputFile = readsOutputFile; self.timeout = timeout; self.environment = environment
    }

    public static let codex = CLIProviderConfiguration(
        id: "cli.codex", displayName: "Codex CLI", command: "codex",
        arguments: ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--color", "never",
                    "-C", "{workspace}", "-o", "{output}", "-"],
        readsOutputFile: true)

    public static let claude = CLIProviderConfiguration(
        id: "cli.claude", displayName: "Claude Code", command: "claude",
        arguments: ["-p", "--output-format", "text", "--disallowedTools", "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch"])
}

/// Runs a CLI assistant in a disposable workspace. The workspace holds only
/// the transmitted context; the user's file path is never passed, and the
/// workspace is deleted afterwards. Whatever the agent does to its copy has no
/// effect on the document.
public struct CLIProvider: WritingAssistantProvider {
    public let configuration: CLIProviderConfiguration
    public var id: ProviderID { ProviderID(configuration.id) }
    public var displayName: String { configuration.displayName }
    // CLI agents typically call a hosted model.
    public var locality: ProviderLocality { .network }
    public let capabilities: Set<ProviderCapability> = Set(ProviderCapability.allCases)

    public init(configuration: CLIProviderConfiguration) { self.configuration = configuration }

    public var executableURL: URL? { ProcessRunner.locate(configuration.command) }

    public func analyze(_ request: AnalysisRequest) async throws -> AnalysisResponse {
        guard let exe = executableURL else { throw ProviderError.executableNotFound(configuration.command) }
        let ws = try Workspace.create()
        defer { ws.destroy() }
        try request.context.text.write(to: ws.url.appendingPathComponent("passage.md"), atomically: true, encoding: .utf8)
        let output = ws.url.appendingPathComponent("reply.txt")
        let args = configuration.arguments.map {
            $0.replacingOccurrences(of: "{workspace}", with: ws.url.path).replacingOccurrences(of: "{output}", with: output.path)
        }
        let result = try await ProcessRunner.run(
            executable: exe, arguments: args, stdin: Data(PromptBuilder.combined(request).utf8),
            environment: Self.environment(extra: configuration.environment, exe: exe),
            workingDirectory: ws.url, timeout: configuration.timeout)
        guard result.status == 0 else {
            throw ProviderError.processFailed(status: result.status, stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        let reply = configuration.readsOutputFile
            ? ((try? String(contentsOf: output, encoding: .utf8)) ?? String(decoding: result.stdout, as: UTF8.self))
            : String(decoding: result.stdout, as: UTF8.self)
        return ResponseParser.parse(reply)
    }

    /// A small, explicit environment: HOME (tools keep their login there),
    /// PATH, locale, plus configured extras. Nothing else is inherited.
    static func environment(extra: [String: String], exe: URL) -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var out: [String: String] = [
            "HOME": env["HOME"] ?? NSHomeDirectory(),
            "PATH": [exe.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":"),
            "LANG": env["LANG"] ?? "en_US.UTF-8",
            "TERM": "dumb", "NO_COLOR": "1",
        ]
        if let user = env["USER"] { out["USER"] = user }
        if let tmp = env["TMPDIR"] { out["TMPDIR"] = tmp }
        return out.merging(extra) { _, new in new }
    }
}

struct Workspace {
    let url: URL
    static func create() throws -> Workspace {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terso-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Workspace(url: url)
    }
    func destroy() { try? FileManager.default.removeItem(at: url) }
}
