import Foundation

public struct MCPConnectionTest: Equatable, Sendable {
    public let toolCount: Int?
    public let toolNames: [String]

    init(output: String) {
        let lines = output.split(whereSeparator: \.isNewline)
        let prefix = "Tools discovered:"
        let summary = lines.firstIndex { $0.contains(prefix) }
        toolCount = summary.flatMap { lines[$0].components(separatedBy: prefix).last }
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let summary, let toolCount, toolCount > 0 else {
            toolNames = []
            return
        }
        toolNames = lines.dropFirst(summary + 1).filter { $0.hasPrefix("    ") }.prefix(toolCount)
            .compactMap { $0.split(whereSeparator: \.isWhitespace).first }
            .map(String.init)
            .filter { $0.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil }
    }
}

extension HermesRuntime {
    public func testMCPConnection(_ connection: MCPServer.Connection) async throws -> MCPConnectionTest {
        try await Task.detached(priority: .userInitiated) { try probeMCP(connection) }.value
    }

    func refreshMCP(sessionID: String, home: URL, serverNames: [String]) throws {
        // 旧版 Hermes 在 ACP 进程内读取配置，没有独立的网关需要刷新。
        guard ["gateway.pid", "gateway.sock", "gateway.sock.path"].contains(where: {
            FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path)
        }) else { return }
        let outcome = try gatewayOperation(Self.mcpRefreshProgram,
            request: ["session": sessionID, "servers": serverNames], home: home, timeout: 38)
        switch outcome {
        case "refreshed": return
        case "unavailable":
            throw StudioError.message("当前 Hermes 网关无法刷新 MCP，请检查本机 Hermes 并更新后重试。")
        case "busy": throw StudioError.message("此对话仍在执行，请等当前回复结束后再应用 MCP 变更。")
        default: throw StudioError.message("Hermes 未能确认原对话的 MCP 变更，请重试。")
        }
    }

    private func probeMCP(_ connection: MCPServer.Connection) throws -> MCPConnectionTest {
        try connection.validate()
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("studio-mcp-\(UUID())", isDirectory: true)
        try files.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: home) }

        var config = connection.hermesConfig
        config["connect_timeout"] = 12
        let data = try JSONSerialization.data(withJSONObject: ["mcp_servers": [connection.name: config]])
        try MCPStore.writePrivate(data, to: home.appendingPathComponent("config.yaml"))
        var environment = ["HERMES_HOME": home.path]
        try attachInstalledDependencies(to: home, environment: &environment)
        do {
            let result = try captureCommandOutput(["mcp", "test", connection.name], timeout: 28,
                output: home.appendingPathComponent("output"), directory: home, overrides: environment)
            guard result.code == 0 else { throw StudioError.message(Self.mcpTestFailure(result.output, connection.transport)) }
            return MCPConnectionTest(output: result.output)
        } catch CapturedCommandError.timedOut {
            throw StudioError.message("连接测试超时，请检查服务是否已经启动。")
        } catch CapturedCommandError.failed {
            throw StudioError.message("未能完成连接测试，请检查本机 Hermes 是否可用。")
        }
    }

    private static func mcpTestFailure(_ output: String, _ transport: MCPServer.Transport) -> String {
        let failure = output.split(whereSeparator: \.isNewline)
            .first { $0.contains("Connection failed") }?.lowercased() ?? ""
        if failure.contains("timed out") { return "连接测试超时，请检查服务是否已经启动。" }
        if failure.contains("401") || failure.contains("403") {
            return "服务拒绝访问，请检查 HTTP 请求头和凭据。"
        }
        if failure.contains("command not found") || failure.contains("no such file or directory") {
            return "找不到服务命令，请填写可执行文件的绝对路径。"
        }
        return transport == .stdio ? "无法连接，请检查服务命令、参数和环境变量。"
            : "无法连接，请检查网络、MCP 地址和 HTTP 请求头。"
    }

    private static let mcpRefreshProgram = gatewayProgram + """

        async def reload_mcp(client, request):
            try:
                from acp_adapter.catalog import logical_session_id
                session = await asyncio.to_thread(logical_session_id, get_hermes_home(), request["session"])
            except ImportError:
                session = request["session"]
            try:
                result = await client.rpc("reload.mcp", session_id=session, confirm=True, _timeout=32)
            except GatewayRPCError as error:
                if str(error) in {"method_not_found", "unknown_method"}:
                    return "unavailable"
                return "unconfirmed"
            if result.get("session") == "busy":
                return "busy"
            servers = result.get("session_servers")
            if (result.get("status") == "reloaded" and result.get("session") in {"applied", "unchanged"}
                    and isinstance(servers, list) and set(servers) <= set(request["servers"])):
                return "refreshed"
            return "unconfirmed"

        respond(reload_mcp)
        """
}
