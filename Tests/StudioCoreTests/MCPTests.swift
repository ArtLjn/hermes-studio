import Darwin
import Foundation
import XCTest
@testable import StudioCore

final class MCPTests: XCTestCase {
    func testRoleDirectoryReturnsCurrentPeersWithoutPrivateFields() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let caller = Role(name: "当前助手", summary: "", template: .blank)
        var collaborator = Role(name: "测试助手", summary: "负责回归测试", template: .blank)
        let archived = Role(name: "已归档助手", summary: "", template: .blank)
        try store.create(caller, instructions: "")
        try store.create(collaborator, instructions: "私有角色设定", initialMemory: [.memory: "私有记忆"])
        try store.create(archived, instructions: "")
        _ = try store.archive(archived.id)
        XCTAssertEqual(try store.collaborators(for: caller.id),
            [RoleDirectoryEntry(id: collaborator.id, name: collaborator.name, summary: collaborator.summary)])
        XCTAssertThrowsError(try store.collaborators(for: archived.id))

        collaborator.name = "质量助手"
        try store.update(collaborator)
        XCTAssertEqual(try store.collaborators(for: caller.id).first?.name, "质量助手")
        let data = try JSONEncoder().encode(store.collaborators(for: caller.id))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(entries.first).keys), ["id", "name", "summary"])

        var configured = MCPServer.Connection()
        configured.name = "Studio-Role-Directory"
        let helper = URL(fileURLWithPath: "/test bundle/StudioRoleDirectory")
        let connection = store.roleDirectoryConnection(for: caller.id, executable: helper, alongside: [configured])
        XCTAssertEqual(connection.name, "studio_role_directory_2")
        XCTAssertEqual(connection.arguments, [root.path, caller.id.uuidString])
    }

    func testRoleDirectoryDisablesGroupLookupForLocalConsultationFollowUp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let caller = Role(name: "糖糖", summary: "", template: .blank)
        try store.create(caller, instructions: "")
        var group = GroupDiscussion(title: "闲聊群", goal: "", memberIDs: [caller.id])
        group.turns = [GroupTurn(role: caller, question: "在群里的问题")]
        group.recordReply("只能从群聊查到的内容", at: 0, activeMembers: [caller])
        try GroupDiscussionStore(root: root).save(group)

        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("StudioRoleDirectory")
        func execute(allowGroupLookup: Bool) throws -> [[String: Any]] {
            let connection = store.roleDirectoryConnection(for: caller.id, executable: helper, allowGroupLookup: allowGroupLookup)
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = helper
            process.arguments = connection.arguments
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            let messages = """
                {"jsonrpc":"2.0","id":1,"method":"tools/list"}
                {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_group_chat","arguments":{}}}

                """
            try input.fileHandleForWriting.write(contentsOf: Data(messages.utf8))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return try data.split(separator: 10).map { line in
                let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                return try XCTUnwrap(response["result"] as? [String: Any])
            }
        }

        let scoped = try execute(allowGroupLookup: false)
        let tools = try XCTUnwrap(scoped.first?["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "list_roles" })
        XCTAssertFalse(tools.contains { ["search_group_chat", "search_group_memory"].contains($0["name"] as? String ?? "") })
        XCTAssertEqual(scoped.last?["isError"] as? Bool, true)
        let ordinary = try execute(allowGroupLookup: true)
        let openTools = try XCTUnwrap(ordinary.first?["tools"] as? [[String: Any]])
        XCTAssertTrue(openTools.contains { $0["name"] as? String == "search_group_chat" })
        let result = try XCTUnwrap(ordinary.last?["content"] as? [[String: String]])
        XCTAssertTrue(result.first?["text"]?.contains("只能从群聊查到的内容") == true)
    }

    func testLiveHermesCanCallTheRoleDirectory() async throws {
        guard let path = ProcessInfo.processInfo.environment["HERMES_STUDIO_ROLE_DIRECTORY_TEST"] else {
            throw XCTSkip("设置 HERMES_STUDIO_ROLE_DIRECTORY_TEST 指向目录工具，联调本机 Hermes。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let caller = Role(name: "协作请求方", summary: "", template: .blank)
        let collaborator = Role(name: "回归搭档", summary: "负责回归测试，联调代号 ROSTER-3917", template: .blank)
        try store.create(caller, instructions: "")
        try store.create(collaborator, instructions: "")
        let home = store.runtime(for: caller.id)
        defer {
            runtime.reset(home: home)
            stopRoleGateway(home)
        }
        let connection = store.roleDirectoryConnection(for: caller.id, executable: URL(fileURLWithPath: path))
        let probe = try await runtime.testMCPConnection(connection)
        XCTAssertEqual(Set(probe.toolNames), ["list_roles", "propose_group", "search_group_chat", "list_my_groups", "search_group_memory"])
        let result = try await ask("请调用名称含 list_roles 的工具，读取可用助手，原样报告返回的名称和联调代号。",
            in: Conversation(roleID: caller.id), runtime: runtime, home: home, servers: [connection])
        XCTAssertTrue(result.toolOutput.contains("ROSTER-3917"), result.diagnostic)
        XCTAssertTrue(result.reply.contains("ROSTER-3917"), result.diagnostic)
        let proposalTest = try await ask("""
            本次是群聊联调。我明确请你保存一份提案。先调用 list_roles 获取回归搭档的角色 ID，
            然后实际调用名称含 propose_group 的工具，群名填「回归讨论」，目标填「验证群聊工具」，
            成员选回归搭档，理由为复查用例，首条任务填「请先提出验收步骤」。
            """, in: Conversation(roleID: caller.id), runtime: runtime, home: home, servers: [connection])
        let groups = GroupDiscussionStore(root: root)
        let proposal = try XCTUnwrap(groups.proposals().first, proposalTest.diagnostic)
        XCTAssertEqual(proposal.authorID, caller.id)
        XCTAssertEqual(proposal.members.map(\.roleID), [collaborator.id])
        XCTAssertEqual(proposal.title, "回归讨论")
        XCTAssertTrue(try groups.discussions().isEmpty)

        var discussion = GroupDiscussion(title: "内置群聊检索", goal: "", memberIDs: [caller.id, collaborator.id])
        discussion.turns.append(GroupTurn(role: collaborator, question: "MCP-SCOPE-OTHER 群内未参与的话题"))
        discussion.recordReply("这是另一条讨论。", at: 0, activeMembers: [caller, collaborator])
        discussion.turns.append(GroupTurn(role: caller, question: "MCP-SCOPE-OWN 群内已参与的话题"))
        discussion.recordReply("已确认这条话题。", at: 1, activeMembers: [caller, collaborator])
        try groups.save(discussion)
        let search = try await ask("""
            请实际调用名称含 search_group_chat 的工具，参数 query 填 MCP-SCOPE，原样报告返回记录中的联调标记。
            """, in: Conversation(roleID: caller.id), runtime: runtime, home: home, servers: [connection])
        XCTAssertTrue(search.toolOutput.contains("MCP-SCOPE-OWN"), search.diagnostic)
        XCTAssertFalse(search.toolOutput.contains("MCP-SCOPE-OTHER"), search.diagnostic)
        XCTAssertTrue(search.reply.contains("MCP-SCOPE-OWN"), search.diagnostic)
    }

    func testCatalogKeepsRoleAssignmentsAndRejectsCollidingToolNamespaces() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = MCPStore(root: root)
        XCTAssertEqual(try catalog.load(), [])

        let roleA = UUID()
        let roleB = UUID()
        var stdio = server("local-tools", .stdio, "/bin/example", for: roleA)
        stdio.connection.arguments = ["one argument with spaces", "--flag"]
        stdio.connection.variables = ["API_KEY": "$" + "{LOCAL_TOKEN}"]
        var http = server("remote", .http, "https://example.com/mcp", for: roleB)
        http.enabled = false
        try catalog.save([stdio, http])
        XCTAssertEqual(try catalog.load(), [stdio, http])
        XCTAssertEqual(MCPStore.connections(in: try catalog.load(), for: roleA), [stdio.connection])
        XCTAssertTrue(MCPStore.connections(in: try catalog.load(), for: roleB).isEmpty)
        XCTAssertTrue(MCPStore.connections(in: try catalog.load(), for: UUID()).isEmpty)

        var collision = server("LOCAL_tools", .http, "https://example.com/mcp", for: roleB)
        XCTAssertThrowsError(try catalog.save([stdio, collision]))
        collision.connection.name = "another"
        collision.connection.endpoint = "file:///tmp/mcp"
        XCTAssertThrowsError(try catalog.save([stdio, collision]))
        XCTAssertEqual(try catalog.load(), [stdio, http])

        http.enabled = true
        try catalog.save([stdio, http])
        XCTAssertEqual(MCPStore.connections(in: try catalog.load(), for: roleB), [http.connection])
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("mcp.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLiveMCPTransportsKeepToolsIsolatedAndResumeTheOriginalConversation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HERMES_STUDIO_LIVE_MCP_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_MCP_TEST=1 联调真实 MCP 与本机 Hermes。")
        }
        let python = try XCTUnwrap(environment["HERMES_STUDIO_MCP_TEST_PYTHON"],
            "需要指定安装了 MCP SDK 和 uvicorn 的 Python。")
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let roleStore = RoleStore(root: root)
        let catalog = MCPStore(root: root)
        let roleA = Role(name: "测试角色 A", summary: "", template: .blank)
        let roleB = Role(name: "测试角色 B", summary: "", template: .blank)
        try roleStore.create(roleA, instructions: "")
        try roleStore.create(roleB, instructions: "")
        let homeA = roleStore.runtime(for: roleA.id)
        let homeB = roleStore.runtime(for: roleB.id)
        let fixture = try startHTTP(python: python, root: root)
        defer { stop(fixture.process) }
        defer {
            for home in [homeA, homeB] {
                runtime.reset(home: home)
                stopRoleGateway(home)
            }
        }
        var stdio = server("scope_stdio", .stdio, python, for: roleA.id)
        stdio.connection.arguments = ["-B", "-c", Self.mcpFixture, "stdio"]
        stdio.connection.variables = ["STUDIO_TEST_MARKER": "STDIO-MARKER-682"]
        var http = server("scope_http", .http, fixture.url, for: roleB.id)
        http.connection.variables = ["X-MCP-Test": "fixture-token"]
        try catalog.save([stdio, http])

        let stdioProbe = try await runtime.testMCPConnection(stdio.connection)
        let httpProbe = try await runtime.testMCPConnection(http.connection)
        XCTAssertEqual(stdioProbe.toolNames, ["read_stdio_marker"])
        XCTAssertEqual(httpProbe.toolNames, ["read_http_marker"])
        var unauthorized = http.connection
        unauthorized.variables = [:]
        do {
            _ = try await runtime.testMCPConnection(unauthorized)
            XCTFail("HTTP 服务应拒绝缺少请求头的连接。")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("拒绝访问"), error.localizedDescription)
        }

        func connections(_ role: Role) throws -> [MCPServer.Connection] {
            MCPStore.connections(in: try catalog.load(), for: role.id)
        }
        var thread = Conversation(roleID: roleA.id)
        let first = try await ask("我的会话标记是 THREAD-4317。必须调用名称含 read_stdio_marker 的工具并原样报告返回值。如果工具列表里没有 read_http_marker，再写 HTTP_HIDDEN。",
            in: thread, runtime: runtime, home: homeA, servers: connections(roleA))
        XCTAssertTrue(first.toolOutput.contains("STDIO-MARKER-682"), first.diagnostic)
        XCTAssertFalse(first.toolOutput.contains("HTTP-MARKER-974"), first.diagnostic)
        XCTAssertTrue(first.reply.contains("HTTP_HIDDEN"), first.diagnostic)
        thread.sessionID = try XCTUnwrap(first.sessionID)
        try roleStore.save(thread)

        let other = try await ask("必须调用名称含 read_http_marker 的工具并原样报告返回值。如果工具列表里没有 read_stdio_marker，再写 STDIO_HIDDEN。",
            in: Conversation(roleID: roleB.id), runtime: runtime, home: homeB, servers: connections(roleB))
        XCTAssertTrue(other.toolOutput.contains("HTTP-MARKER-974"), other.diagnostic)
        XCTAssertFalse(other.toolOutput.contains("STDIO-MARKER-682"), other.diagnostic)
        XCTAssertTrue(other.reply.contains("STDIO_HIDDEN"), other.diagnostic)

        stdio.enabled = false
        http.roleIDs.insert(roleA.id)
        try catalog.save([stdio, http])
        let before = try XCTUnwrap(thread.sessionID)
        let loaded = try await runtime.runSettings(home: homeA, sessionID: before, skillIDs: [], mcpServers: connections(roleA))
        XCTAssertEqual(loaded.id, before)
        let resumed = try await ask("先复述我本对话第一条消息的会话标记，再实际调用名称含 read_http_marker 的工具，原样报告返回值。如果现在没有 read_stdio_marker，写 STDIO_HIDDEN。",
            in: thread, runtime: runtime, home: homeA, servers: connections(roleA))
        XCTAssertNil(resumed.sessionID, "续聊应使用原会话编号。")
        XCTAssertTrue(resumed.reply.contains("THREAD-4317"), resumed.diagnostic)
        XCTAssertTrue(resumed.reply.contains("STDIO_HIDDEN"), resumed.diagnostic)
        XCTAssertTrue(resumed.toolOutput.contains("HTTP-MARKER-974"), resumed.diagnostic)
        XCTAssertFalse(resumed.toolOutput.contains("STDIO-MARKER-682"), resumed.diagnostic)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: homeA.appendingPathComponent("config.yaml")))
        let entries = (config as? [String: Any])?["mcp_servers"] as? [String: Any]
        XCTAssertEqual(entries?.keys.sorted(), ["scope_http"])

        http.roleIDs.remove(roleA.id)
        try catalog.save([stdio, http])
        let revoked = try await runtime.runSettings(home: homeA, sessionID: before, skillIDs: [],
            mcpServers: connections(roleA))
        XCTAssertEqual(revoked.id, before)
        XCTAssertEqual(try connections(roleB), [http.connection])
        let revokedConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: homeA.appendingPathComponent("config.yaml")))
        let revokedEntries = (revokedConfig as? [String: Any])?["mcp_servers"] as? [String: Any]
        XCTAssertEqual(revokedEntries?.count, 0)
    }

    private func server(_ name: String, _ transport: MCPServer.Transport, _ endpoint: String, for role: UUID) -> MCPServer {
        var server = MCPServer()
        server.connection.name = name
        server.connection.transport = transport
        server.connection.endpoint = endpoint
        server.roleIDs = [role]
        return server
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("studio-mcp-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private struct Reply {
        var sessionID: String?
        var reply = ""
        var toolOutput = ""
        var diagnostic: String { "模型回复 \(reply)\n工具输出 \(toolOutput)" }
    }

    private func ask(_ text: String, in thread: Conversation, runtime: HermesRuntime, home: URL,
        servers: [MCPServer.Connection]) async throws -> Reply {
        let control = TurnControl()
        let timeout = Task {
            try await Task.sleep(for: .seconds(65))
            control.cancel()
        }
        defer { timeout.cancel() }
        var reply = Reply()
        var finished = false
        for await event in runtime.turn(home: home, conversation: thread, text: text, skillIDs: [], mcpServers: servers,
            interactive: true, control: control) {
            switch event {
            case .session(let id): reply.sessionID = id
            case .text(let fragment, _): reply.reply += fragment
            case .tool(let tool):
                if tool.status == "completed", let details = tool.details { reply.toolOutput += details }
            case .failed(let message): throw StudioError.message(message)
            case .finished(let reason):
                XCTAssertEqual(reason, "end_turn", reply.diagnostic)
                finished = true
            default: break
            }
        }
        XCTAssertTrue(finished, reply.diagnostic)
        return reply
    }

    private func startHTTP(python: String, root: URL) throws -> (process: Process, url: String) {
        let portFile = root.appendingPathComponent("mcp-port")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", "-c", Self.mcpFixture, "http", portFile.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if let port = try? String(contentsOf: portFile, encoding: .utf8), let number = UInt16(port) {
                return (process, "http://127.0.0.1:\(number)/mcp")
            }
            guard process.isRunning else { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stop(process)
        throw StudioError.message("测试 HTTP MCP 服务未能启动。")
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private func stopRoleGateway(_ home: URL) {
        let marker = home.appendingPathComponent("gateway.pid")
        guard let data = try? Data(contentsOf: marker),
            let owner = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let path = owner["hermes_home"] as? String,
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().path,
            let pid = owner["pid"] as? Int32, pid > 1, Darwin.kill(pid, SIGTERM) == 0 else { return }
        for _ in 0..<40 {
            guard FileManager.default.fileExists(atPath: marker.path) else { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static let mcpFixture = """
        import os
        import socket
        import sys
        from pathlib import Path

        from mcp.types import ToolAnnotations
        try:
            from mcp.server.mcpserver import MCPServer
        except ImportError:
            from mcp.server.fastmcp import FastMCP as MCPServer

        server = MCPServer("Studio MCP test")
        read_only = ToolAnnotations(readOnlyHint=True, destructiveHint=False)

        if sys.argv[1] == "stdio":
            @server.tool(annotations=read_only)
            def read_stdio_marker() -> str:
                \"\"\"读取本地测试标记。\"\"\"
                return os.environ["STUDIO_TEST_MARKER"]

            server.run(transport="stdio")
        else:
            import uvicorn
            from starlette.responses import PlainTextResponse

            @server.tool(annotations=read_only)
            def read_http_marker() -> str:
                \"\"\"读取 HTTP 测试标记。\"\"\"
                return "HTTP-MARKER-974"

            app = server.streamable_http_app()

            async def authenticated(scope, receive, send):
                if scope["type"] == "http" and dict(scope["headers"]).get(b"x-mcp-test") != b"fixture-token":
                    await PlainTextResponse("Unauthorized", status_code=401)(scope, receive, send)
                    return
                await app(scope, receive, send)

            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            Path(sys.argv[2]).write_text(str(listener.getsockname()[1]))
            uvicorn.Server(uvicorn.Config(authenticated, log_level="error")).run(sockets=[listener])
        """
}
