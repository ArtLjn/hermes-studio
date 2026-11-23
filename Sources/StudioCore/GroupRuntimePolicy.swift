import CryptoKit
import Foundation

struct HermesGenerationBudget: Codable, Equatable, Sendable {
    let outputTokens: Int
    let iterations: Int

    static let chat = Self(outputTokens: 512, iterations: 3)
    static let tools = Self(outputTokens: 1536, iterations: 8)
    static let idle = Self(outputTokens: 128, iterations: 1)
}

extension GroupDiscussionStore {
    public func pooledRuntimeStore(for group: GroupDiscussion, role: Role, fullAccess: Bool,
        idle: Bool = false) -> RoleStore {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let permissions = (try? encoder.encode(group.permissions(for: role.id))) ?? Data()
        let skills = role.skillIDs?.sorted().joined(separator: ",") ?? "default"
        let policy = "\(fullAccess):\(idle):\(skills)"
        let digest = SHA256.hash(data: permissions + Data(policy.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        // 同一群的不同会话共享角色运行环境；权限变化另开环境，不修改旧会话的权限。
        return RoleStore(root: root.appendingPathComponent("runtime-pool/\(group.groupID)/\(digest)", isDirectory: true))
    }
}

extension MCPServer.Connection {
    var acpSpecification: [String: Any] {
        let fields = variables.sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value] }
        switch transport {
        case .stdio:
            return ["name": name, "command": endpoint, "args": arguments, "env": fields]
        case .http:
            return ["type": "http", "name": name, "url": endpoint, "headers": fields]
        }
    }
}
