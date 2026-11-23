import Foundation

public struct MCPServer: Codable, Equatable, Identifiable, Sendable {
    public enum Transport: String, CaseIterable, Codable, Sendable {
        case stdio, http
    }

    public struct Connection: Codable, Equatable, Sendable {
        public var name = ""
        public var transport: Transport = .stdio
        public var endpoint = ""
        public var arguments: [String] = []
        public var variables: [String: String] = [:]

        public init() {}

        fileprivate var toolNamespace: String { name.lowercased().replacingOccurrences(of: "-", with: "_") }

        func validate() throws {
            guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else {
                throw StudioError.message("服务名称须以英文字母或数字开头，可使用英文字母、数字、短横线和下划线。")
            }
            guard !endpoint.isEmpty, !endpoint.contains(where: \.isNewline), !endpoint.utf8.contains(0) else {
                throw StudioError.message(transport == .stdio ? "请输入可执行命令。" : "请输入 HTTP 服务地址。")
            }
            switch transport {
            case .stdio:
                guard arguments.allSatisfy({ !$0.utf8.contains(0) }),
                    variables.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=")
                        && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
                    throw StudioError.message("命令参数或环境变量格式无效。")
                }
            case .http:
                guard let url = URLComponents(string: endpoint), let scheme = url.scheme?.lowercased(),
                    ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
                    url.user == nil, url.password == nil, url.fragment == nil else {
                    throw StudioError.message("请输入有效的 HTTP 或 HTTPS 服务地址。")
                }
                guard variables.allSatisfy({ key, value in
                    key.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil
                        && !value.contains(where: \.isNewline) && !value.utf8.contains(0)
                }), Set(variables.keys.map { $0.lowercased() }).count == variables.count else {
                    throw StudioError.message("HTTP 请求头名称格式无效、重复或包含换行。")
                }
            }
        }

        var hermesConfig: [String: Any] {
            switch transport {
            case .stdio: ["command": endpoint, "args": arguments, "env": variables]
            case .http: ["url": endpoint, "headers": variables, "strict_redirect_headers": true]
            }
        }
    }

    public var id = UUID()
    public var connection = Connection()
    public var enabled = true
    public var roleIDs: Set<UUID> = []

    public init() {}
}

public struct MCPStore: Sendable {
    private let url: URL

    public init(root: URL) { url = root.appendingPathComponent("mcp.json") }

    public func load() throws -> [MCPServer] {
        do {
            let servers = try JSONDecoder().decode([MCPServer].self, from: Data(contentsOf: url))
            try Self.validate(servers)
            return servers
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }

    public func save(_ servers: [MCPServer]) throws {
        try Self.validate(servers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.writePrivate(encoder.encode(servers), to: url)
    }

    public static func connections(in servers: [MCPServer], for roleID: UUID) -> [MCPServer.Connection] {
        servers.filter { $0.enabled && $0.roleIDs.contains(roleID) }
            .map(\.connection).sorted { $0.name < $1.name }
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        let file = url.deletingLastPathComponent().appendingPathComponent(".mcp-\(UUID().uuidString)")
        let files = FileManager.default
        guard files.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StudioError.message("无法保存 MCP 配置。")
        }
        defer { try? files.removeItem(at: file) }
        if files.fileExists(atPath: url.path) {
            _ = try files.replaceItemAt(url, withItemAt: file, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: file, to: url)
        }
    }

    private static func validate(_ servers: [MCPServer]) throws {
        for server in servers { try server.connection.validate() }
        guard Set(servers.map(\.id)).count == servers.count,
            Set(servers.map(\.connection.toolNamespace)).count == servers.count else {
            throw StudioError.message("MCP 服务名称重复。名称中的大小写和短横线、下划线不用于区分服务。")
        }
    }
}
