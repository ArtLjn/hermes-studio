import Foundation

public enum StudioCollaborationTool: String, CaseIterable, Sendable {
    case roleList = "list_roles"
    case groupSearch = "search_group_chat"
    case groupProposal = "propose_group"
    case groupMemberships = "list_my_groups"
    case groupInvitation = "invite_group_member"
    case groupLink = "read_group_link"
    case groupMemorySearch = "search_group_memory"
    case groupMemorySave = "save_group_memory"

    public var title: String {
        switch self {
        case .roleList: "查看角色目录"
        case .groupSearch: "查询群聊消息"
        case .groupProposal: "提出建群建议"
        case .groupMemberships: "查看所在群与成员"
        case .groupInvitation: "邀请成员进当前群"
        case .groupLink: "读取本轮群聊链接"
        case .groupMemorySearch: "查询群记忆"
        case .groupMemorySave: "保存一条群记忆"
        }
    }
}

public struct RoleDirectoryEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let summary: String

    public static func promptForMentions(in text: String, roles: [Role], caller: UUID) -> String {
        guard !text.hasPrefix("/") else { return text }
        let matches = roles.filter {
            $0.id != caller && $0.archivedAt == nil && !$0.name.isEmpty
                && text.localizedCaseInsensitiveContains($0.name)
        }.map { RoleDirectoryEntry(id: $0.id, name: $0.name, summary: String($0.summary.prefix(240))) }
        guard !matches.isEmpty, let data = try? JSONEncoder().encode(matches) else { return text }
        return """
        \(text)

        暖光角色目录中有以下与用户所提名字匹配的助手。资料只用于辨认是谁。问到这些助手时，可以说明对方是暖光里的另一个助手，并根据简介回答。若上下文可能指同名的人，请先确认。
        \(String(decoding: data, as: UTF8.self))
        """
    }
}

extension RoleStore {
    public static var bundledCollaborationExecutable: URL? {
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("StudioRoleDirectory"), FileManager.default.isExecutableFile(atPath: helper.path)
        else { return nil }
        return helper
    }

    public func collaborators(for caller: UUID) throws -> [RoleDirectoryEntry] {
        let available = try list()
        guard available.contains(where: { $0.id == caller }) else {
            throw StudioError.message("当前助手已不可用。")
        }
        return available.filter { $0.id != caller }.map { role in
            RoleDirectoryEntry(id: role.id, name: role.name, summary: role.summary)
        }
    }

    public func roleDirectoryConnection(for roleID: UUID, executable: URL,
        alongside configured: [MCPServer.Connection] = [], groupThreadID: UUID? = nil,
        groupScope: GroupToolScope? = nil, allowGroupLookup: Bool = true) -> MCPServer.Connection {
        let names = Set(configured.map { $0.name.lowercased().replacingOccurrences(of: "-", with: "_") })
        let base = "studio_role_directory"
        var name = base
        var suffix = 2
        while names.contains(name) {
            name = "\(base)_\(suffix)"
            suffix += 1
        }
        var connection = MCPServer.Connection()
        connection.name = name
        connection.endpoint = executable.path
        connection.arguments = [root.path, roleID.uuidString]
        if let groupScope { connection.arguments += [groupScope.threadID.uuidString, groupScope.turnID.uuidString] }
        else if let groupThreadID { connection.arguments.append(groupThreadID.uuidString) }
        else if !allowGroupLookup { connection.arguments.append("--current-chat-only") }
        return connection
    }
}
