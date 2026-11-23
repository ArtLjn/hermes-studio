import StudioCore
import SwiftUI

@MainActor
final class MCPManagement: ObservableObject {
    enum TestState {
        case testing(UUID)
        case passed(MCPConnectionTest)
        case failed(String)
    }

    @Published private(set) var servers: [MCPServer] = []
    @Published private(set) var tests: [UUID: TestState] = [:]
    let loadError: String?
    private let store: MCPStore
    private let roleStore: RoleStore

    init(root: URL) {
        store = MCPStore(root: root)
        roleStore = RoleStore(root: root)
        do {
            servers = try store.load()
            loadError = nil
        } catch {
            loadError = "无法读取 MCP 配置。请检查暖光数据目录中的 mcp.json。"
        }
    }

    var builtInExecutable: URL? {
        RoleStore.bundledCollaborationExecutable
    }

    func configuredConnections(for roleID: UUID) -> [MCPServer.Connection] {
        MCPStore.connections(in: servers, for: roleID)
    }

    func connections(for roleID: UUID, allowGroupLookup: Bool = true) -> [MCPServer.Connection] {
        let configured = configuredConnections(for: roleID)
        guard let helper = builtInExecutable else { return configured }
        return configured + [roleStore.roleDirectoryConnection(for: roleID, executable: helper, alongside: configured,
            allowGroupLookup: allowGroupLookup)]
    }

    func saveConnection(_ server: MCPServer, editing: Bool) throws {
        if editing {
            try update(server.id) { $0.connection = server.connection }
        } else {
            try persist(servers + [server])
        }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) throws {
        try update(id) { $0.enabled = enabled }
    }

    func assign(_ assigned: Bool, roleID: UUID, to id: UUID) throws {
        try update(id) { server in
            if assigned { server.roleIDs.insert(roleID) } else { server.roleIDs.remove(roleID) }
        }
    }

    func remove(_ id: UUID) throws {
        try persist(servers.filter { $0.id != id })
        tests.removeValue(forKey: id)
    }

    func test(_ server: MCPServer, runtime: HermesRuntime?) async {
        guard servers.contains(where: { $0.id == server.id && $0.connection == server.connection }) else { return }
        let id = UUID()
        tests[server.id] = .testing(id)
        let result: TestState
        do {
            guard let runtime else { throw StudioError.message("请先连接本机 Hermes。") }
            result = .passed(try await runtime.testMCPConnection(server.connection))
        } catch {
            result = .failed(error.localizedDescription)
        }
        guard case .testing(id) = tests[server.id] else { return }
        tests[server.id] = result
    }

    private func update(_ id: UUID, apply: (inout MCPServer) -> Void) throws {
        var updated = servers
        guard let index = updated.firstIndex(where: { $0.id == id }) else {
            throw StudioError.message("该 MCP 服务已移除。")
        }
        apply(&updated[index])
        try persist(updated)
    }

    private func persist(_ updated: [MCPServer]) throws {
        if let loadError { throw StudioError.message(loadError) }
        try store.save(updated)
        let connections = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.connection) })
        for server in updated where connections[server.id] != server.connection {
            tests.removeValue(forKey: server.id)
        }
        servers = updated
    }
}
