import Foundation

public struct HermesCompletion: Identifiable, Equatable, Sendable {
    public enum Query: Equatable, Sendable {
        case slash(String)
        case reference(word: String, project: URL)
    }

    public let text: String
    public let display: String
    public let detail: String
    public var id: String { text }

    // ACP 支持的命令少于 TUI，补全结果只展示能在当前聊天入口执行的命令。
    fileprivate static let acpCommands: Set<String> = [
        "help", "model", "tools", "context", "reset", "compress", "steer", "queue", "version"
    ]

    public static func reference(at caret: Int, in text: String) -> (word: String, range: NSRange)? {
        let source = text as NSString
        guard caret > 0, caret <= source.length else { return nil }
        let prefix = source.substring(to: caret) as NSString
        let range = prefix.range(of: "(?:^|\\s)@[^@\\s]*$", options: .regularExpression)
        guard range.location != NSNotFound else { return nil }
        let start = prefix.range(of: "@", range: range).location
        let token = NSRange(location: start, length: caret - start)
        return (prefix.substring(with: token), token)
    }

    public var insertion: String {
        guard text.hasPrefix("@"), let colon = text.firstIndex(of: ":"), !text.hasSuffix(":") else { return text }
        let path = text[text.index(after: colon)...]
        if path.contains(where: \.isWhitespace) { return "\(text[...colon])\"\(path)\" " }
        return text.hasSuffix("/") ? text : text + " "
    }
}

extension HermesRuntime {
    public func complete(_ query: HermesCompletion.Query) async -> [HermesCompletion] {
        let control = TurnControl()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completionWorker.queue.async {
                    guard !control.isCancelled else {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(returning: completionWorker.complete(query, runtime: self))
                }
            }
        } onCancel: {
            control.cancel()
        }
    }
}

final class HermesCompletionWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "studio.hermes.completion", qos: .userInitiated)
    private var connection: (process: Process, rpc: ACPConnection, home: URL)?

    func complete(_ query: HermesCompletion.Query, runtime: HermesRuntime) -> [HermesCompletion] {
        do {
            let rpc = try connect(runtime: runtime)
            let response: [String: Any]
            switch query {
            case .slash(let text):
                response = try rpc.call("complete.slash", parameters: ["text": text], timeout: .seconds(5))
            case .reference(let word, let project):
                response = try rpc.call("complete.path", parameters: ["word": word, "cwd": project.path], timeout: .seconds(5))
            }
            var seen: Set<String> = []
            return (response["items"] as? [[String: Any]] ?? []).compactMap { item in
                guard let value = item["text"] as? String, !value.isEmpty else { return nil }
                let text: String
                switch query {
                case .slash:
                    let name = value.hasPrefix("/") ? String(value.dropFirst()) : value
                    guard item["kind"] as? String != "skill", HermesCompletion.acpCommands.contains(name) else {
                        return nil
                    }
                    text = "/" + name
                case .reference(_, let project):
                    guard isProjectReference(value, in: project) else { return nil }
                    text = value
                }
                guard seen.insert(text).inserted else { return nil }
                return HermesCompletion(text: text, display: (item["display"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text,
                    detail: item["meta"] as? String ?? "")
            }
        } catch {
            close()
            return []
        }
    }

    private func isProjectReference(_ text: String, in project: URL) -> Bool {
        guard text.hasPrefix("@file:") || text.hasPrefix("@folder:"), let colon = text.firstIndex(of: ":") else {
            return false
        }
        let path = String(text[text.index(after: colon)...])
        if path.isEmpty { return true }
        guard !path.hasPrefix("/"), !path.contains("\""), !path.contains(where: \.isNewline) else { return false }
        let root = project.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = project.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func connect(runtime: HermesRuntime) throws -> ACPConnection {
        if let connection, connection.process.isRunning { return connection.rpc }
        close()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-studio-completion-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            // 补全用独立的本地网关，不创建 ACP 会话，也不读取角色记忆。
            var environment = ["HERMES_HOME": home.path, "HERMES_TUI_SIDECAR_URL": ""]
            try runtime.attachInstalledDependencies(to: home, environment: &environment)
            let process = runtime.process(arguments: ["--run-module", "tui_gateway.entry"], directory: home, overrides: environment)
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            let rpc = ACPConnection(input: input.fileHandleForWriting, output: output.fileHandleForReading)
            connection = (process, rpc, home)
            return rpc
        } catch {
            try? FileManager.default.removeItem(at: home)
            throw error
        }
    }

    private func close() {
        guard let connection else { return }
        self.connection = nil
        if connection.process.isRunning { connection.process.terminate() }
        try? connection.rpc.input.close()
        try? connection.rpc.output.close()
        try? FileManager.default.removeItem(at: connection.home)
    }

    deinit { close() }
}
