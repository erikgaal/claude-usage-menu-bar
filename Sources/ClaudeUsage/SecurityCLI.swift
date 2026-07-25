import Foundation

/// Reads and writes keychain items by driving `/usr/bin/security`, instead of
/// calling `SecItem*` in this process.
///
/// Only for items belonging to *another* application — this app's own vault
/// uses `Keychain` and the framework APIs, which is simpler and correct there.
///
/// The reason is a keychain mechanism separate from the familiar ACL: every
/// item also carries a **partition list** (`apple:`, `apple-tool:`,
/// `teamid:…`), and a write from a third-party-signed binary resets it to that
/// binary's own `teamid:`. Claude Code reads its credentials by shelling out to
/// `security find-generic-password -w`, which runs in `apple-tool:`, so a
/// single `SecItemUpdate` from this app costs the CLI its silent access — and
/// the user a login-password dialog on its next read, after every switch,
/// indefinitely. Going through `security` keeps every access inside
/// `apple-tool:`, so nothing is ever evicted: no dialog for Claude Code, and
/// none for this app either, since it needs no grant of its own.
///
/// Verified against a scratch item at each step: an update from a
/// team-signed binary evicts `apple-tool:` and blocks the CLI's read; the same
/// update from an Apple-signed binary does not (which is how an early probe
/// cleared `SecItemUpdate` wrongly — it was `swift`, not this app); and a
/// rewrite through `security` restores an already-evicted item.
///
/// Requires the app to stay un-sandboxed. A sandboxed build cannot spawn this,
/// and there is no framework-level equivalent — setting a partition list needs
/// the user's password.
enum SecurityCLI {
    static let toolPath = "/usr/bin/security"

    /// The item's data, or nil when there is no such item. Reading this way
    /// costs no authorization, where `SecItemCopyMatching` on a foreign item
    /// would prompt.
    static func readGenericPassword(account: String, service: String) throws -> Data? {
        let result = try run(
            arguments: ["find-generic-password", "-a", account, "-s", service, "-w"])
        guard result.status == 0 else { return nil }

        // `-w` terminates the value with a newline of its own making.
        var text = String(decoding: result.output, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return Data(text.utf8)
    }

    /// Updates the item in place, creating it only if absent (`-U`).
    ///
    /// The payload is hex-encoded and passed as `-X`, and the whole command
    /// goes to `security -i` — which reads *commands* from stdin — so the
    /// secret never appears in `argv` where any local process could read it.
    /// This is the same shape Claude Code uses to store an API key.
    ///
    /// Hex rather than `-w <text>` for two reasons: it sidesteps quoting a JSON
    /// payload full of `"` into a shell-ish command line, and it avoids the
    /// tool's interactive reader, whose `readpassphrase` buffer truncates at
    /// 128 bytes — silently, mid-token, which destroys the sign-in it was
    /// meant to update.
    static func writeGenericPassword(
        _ data: Data, account: String, service: String
    ) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = """
            add-generic-password -U -a \(quoted(account)) -s \(quoted(service)) -X \(hex)

            """
        let result = try run(arguments: ["-i"], stdin: Data(command.utf8))
        guard result.status == 0 else {
            let detail = String(decoding: result.errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SecurityCLIError.commandFailed(status: result.status, detail: detail)
        }
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private struct Result {
        var status: Int32
        var output: Data
        var errorOutput: Data
    }

    private static func run(arguments: [String], stdin: Data? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        let input = stdin.map { _ in Pipe() }
        if let input { process.standardInput = input }

        try process.run()
        if let input, let stdin {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }
        // Read both pipes to EOF before waiting: a process blocked on a full
        // pipe buffer never exits, and `security -i` echoes to stderr.
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: out, errorOutput: err)
    }
}

enum SecurityCLIError: LocalizedError {
    case commandFailed(status: Int32, detail: String)

    var errorDescription: String? {
        if case .commandFailed(let status, let detail) = self {
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return "Keychain command failed (\(status))\(suffix)"
        }
        return nil
    }
}
