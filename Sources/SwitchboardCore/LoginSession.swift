import Foundation
import Darwin

public final class LoginSession {
    public let installation: ClaudeInstallation
    private let process = Process()
    private let input = Pipe()
    public init(directory: URL, executable: URL) throws {
        installation = .isolated(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        process.executableURL = executable
        process.arguments = ["auth", "login", "--claudeai"]
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_") || key == "CLAUDECODE" {
            environment.removeValue(forKey: key)
        }
        environment.merge(installation.configurationEnvironment) { _, new in new }
        environment["USER"] = installation.keychainAccount
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        // OAuth URLs and login codes must never reach app logs or persisted files.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }
    public func start() throws {
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw SwitchboardError.message("Cannot open Claude Code's sign-in channel.")
        }
        try process.run()
    }
    public func submit(code: String) throws {
        guard process.isRunning else { throw SwitchboardError.message("The sign-in process has finished. Choose Save new login.") }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !code.contains("\n"), !code.contains("\r") else {
            throw SwitchboardError.message("Paste the single code returned by Claude.")
        }
        try input.fileHandleForWriting.write(contentsOf: Data((code + "\n").utf8))
    }
    public func checkFinished() throws {
        guard !process.isRunning else { throw SwitchboardError.message("Finish signing in in the browser, then choose Save new login.") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SwitchboardError.message("Claude Code did not complete sign-in. Cancel and try again.")
        }
    }
    public func stop() {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? input.fileHandleForWriting.close()
    }
    deinit { stop() }
}

public enum ClaudeExecutable {
    /// Reads public installation metadata, without starting a CLI or opening an account store.
    public static func installedVersion(at executable: URL) -> String? {
        let resolved = executable.resolvingSymlinksInPath()
        if resolved.deletingLastPathComponent().lastPathComponent == "versions",
           validVersion(resolved.lastPathComponent) { return resolved.lastPathComponent }
        let package = resolved.deletingLastPathComponent().appendingPathComponent("package.json")
        guard let size = try? package.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
              let data = try? Data(contentsOf: package), data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["name"] as? String == "@anthropic-ai/claude-code",
              let version = object["version"] as? String, validVersion(version) else { return nil }
        return version
    }

    static func validVersion(_ version: String) -> Bool {
        version.utf8.count <= 64 && !version.contains(where: { $0.isNewline }) &&
        version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$"#,
                                               options: .regularExpression) != nil
    }

    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        var paths = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw SwitchboardError.message("Claude Code is not installed. Install it from code.claude.com, then reopen Switchboard.")
        }
        return URL(fileURLWithPath: path)
    }
}
