import Foundation

public enum RoleTemplate: String, CaseIterable, Codable, Identifiable, Sendable {
    case general, engineering, writing, blank

    public var id: Self { self }

    public var name: String {
        switch self {
        case .general: "通用协作"
        case .engineering: "研发搭档"
        case .writing: "写作编辑"
        case .blank: "从空白创建"
        }
    }

    public var symbol: String {
        switch self {
        case .general: "sparkle"
        case .engineering: "chevron.left.forwardslash.chevron.right"
        case .writing: "pencil.line"
        case .blank: "plus"
        }
    }

    public var description: String {
        switch self {
        case .general: "整理信息、拆解任务、推进日常工作"
        case .engineering: "分析代码、定位问题、整理实施方案"
        case .writing: "梳理表达、起草文稿、润色段落"
        case .blank: ""
        }
    }

    public var instructions: String {
        switch self {
        case .general: "你是我的日常工作搭档。先给出可以直接使用的结果，再用清楚简短的中文说明依据。遇到信息缺口时，说清你的假设。"
        case .engineering: "你是我的研发搭档。用证据定位问题，给出可落地的最小改动。明确待验证的行为，优先用中文解释技术取舍。"
        case .writing: "你是我的中文写作编辑。根据读者和场景调整语气，保留原意与事实。优先交付可以直接使用的文稿。"
        case .blank: ""
        }
    }
}

public struct Role: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var summary: String
    public var template: RoleTemplate
    public var created = Date()
    public var pinned: Bool?
    public var skillIDs: Set<String>?
    public var terminalSource: String?
    public var avatar: RoleAvatar?
    public var archivedAt: Date?

    public var archiveDeadline: Date? { archivedAt?.addingTimeInterval(30 * 86_400) }

    public init(name: String, summary: String, template: RoleTemplate) {
        self.name = name
        self.summary = summary
        self.template = template
    }
}

public struct Message: Codable, Identifiable, Equatable, Sendable {
    public enum Author: String, Codable, Sendable { case user, assistant, tool }

    public var id = UUID()
    public var author: Author
    public var text: String
    public var remoteID: String?
    public var images: [ChatImage]?
    public var skill: String?
    public var tool: ToolRun?
    public var isGuidance: Bool?
    public var workDuration: TimeInterval?

    public init(_ author: Author, _ text: String, remoteID: String? = nil) {
        self.author = author
        self.text = text
        self.remoteID = remoteID
    }
}

public struct Conversation: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var roleID: UUID
    public var title = "新对话"
    public var updated = Date()
    public var sessionID: String?
    public var projectID: UUID?
    public var messages: [Message] = []

    public init(roleID: UUID) { self.roleID = roleID }
}

public enum RoleFile: String, CaseIterable, Identifiable, Sendable {
    case soul = "SOUL.md"
    case memory = "memories/MEMORY.md"
    case user = "memories/USER.md"

    public var id: Self { self }
    public var label: String {
        switch self {
        case .soul: "角色指令"
        case .memory: "长期记忆"
        case .user: "用户偏好"
        }
    }

    public var hint: String {
        switch self {
        case .soul: "定义这个角色的职责和回复方式。"
        case .memory: "这个角色需要跨对话记住的事实和经验。"
        case .user: "这个角色需要考虑的个人偏好和背景。"
        }
    }
}

public enum StudioError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

public struct RoleStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func list() throws -> [Role] { try allRoles().filter { $0.archivedAt == nil } }

    public func archivedRoles() throws -> [Role] {
        try allRoles().filter { $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    private func allRoles() throws -> [Role] {
        let directory = root.appendingPathComponent("roles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try read(Role.self, at: $0.appendingPathComponent("role.json")) }
            .sorted { $0.created == $1.created ? $0.id.uuidString < $1.id.uuidString : $0.created < $1.created }
    }

    public func create(_ role: Role, instructions: String, initialMemory: [RoleFile: String] = [:],
        avatarImage: ImagePayload? = nil) throws {
        let directory = roleDirectory(role.id)
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".creating-\(role.id)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let runtime = staging.appendingPathComponent("runtime", isDirectory: true)
        for folder in ["memories", "workspace"] {
            try FileManager.default.createDirectory(at: runtime.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(instructions.utf8).write(to: runtime.appendingPathComponent(RoleFile.soul.rawValue), options: .atomic)
        for file in [RoleFile.memory, .user] {
            if let contents = initialMemory[file], !contents.isEmpty {
                try Data(contents.utf8).write(to: runtime.appendingPathComponent(file.rawValue), options: .atomic)
            }
        }
        if let avatarImage {
            let url = imageURL(avatarImage.image, in: staging)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try avatarImage.data.write(to: url, options: .atomic)
        }
        try write(role, at: staging.appendingPathComponent("role.json"))
        try FileManager.default.moveItem(at: staging, to: directory)
    }

    public func terminalChatRole(from home: URL) throws -> Role {
        let source = home.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = try list().first(where: { $0.terminalSource == source.path }) {
            return existing
        }
        var role = Role(name: "终端 Hermes", summary: "使用终端配置和记忆创建的桌面会话。", template: .blank)
        role.terminalSource = source.path
        try createFromTerminal(role, home: source)
        return role
    }

    public func createFromTerminal(_ role: Role, home: URL) throws {
        let instructions = try Self.readFile(.soul, in: home)
        let memory = try Self.readFile(.memory, in: home)
        let preferences = try Self.readFile(.user, in: home)
        try create(role, instructions: instructions, initialMemory: [.memory: memory, .user: preferences])
    }

    public func update(_ role: Role) throws {
        try write(role, at: roleDirectory(role.id).appendingPathComponent("role.json"))
    }

    public func archive(_ id: UUID, now: Date = Date()) throws -> Role {
        var role = try read(Role.self, at: roleDirectory(id).appendingPathComponent("role.json"))
        guard role.terminalSource == nil else { throw StudioError.message("终端 Hermes 的入口由本机 Hermes 管理。") }
        if role.archivedAt == nil {
            role.archivedAt = now
            try update(role)
        }
        return role
    }

    public func restore(_ id: UUID, now: Date = Date()) throws -> Role {
        var role = try read(Role.self, at: roleDirectory(id).appendingPathComponent("role.json"))
        if let deadline = role.archiveDeadline {
            guard now < deadline else { throw StudioError.message("这个角色的 30 天恢复期限已结束。") }
            role.archivedAt = nil
            try update(role)
        }
        return role
    }

    public func purgeExpiredRoles(now: Date = Date()) throws {
        for role in try archivedRoles() {
            if let deadline = role.archiveDeadline, deadline <= now {
                try FileManager.default.removeItem(at: roleDirectory(role.id))
            }
        }
    }

    public func runtime(for id: UUID) -> URL {
        roleDirectory(id).appendingPathComponent("runtime", isDirectory: true)
    }

    public func file(_ file: RoleFile, for id: UUID) throws -> String {
        try Self.readFile(file, in: runtime(for: id))
    }

    public static func readFile(_ file: RoleFile, in home: URL) throws -> String {
        let url = home.appendingPathComponent(file.rawValue)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return ""
        }
    }

    public func writeFile(_ file: RoleFile, for id: UUID, text: String) throws {
        let url = runtime(for: id).appendingPathComponent(file.rawValue)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public func conversations(for id: UUID) throws -> [Conversation] {
        let url = roleDirectory(id).appendingPathComponent("conversations.json")
        do {
            return try read([Conversation].self, at: url)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }

    public func save(_ conversation: Conversation) throws {
        if let projectID = conversation.projectID {
            _ = try requireProject(projectID, for: conversation.roleID)
        }
        var conversations = try conversations(for: conversation.roleID)
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        try saveConversations(conversations, for: conversation.roleID)
    }

    func saveConversations(_ conversations: [Conversation], for roleID: UUID) throws {
        try write(conversations, at: roleDirectory(roleID).appendingPathComponent("conversations.json"))
    }

    public func saveImage(_ input: ImagePayload, for roleID: UUID) throws -> ChatImage {
        let image = input.image
        let url = imageURL(image, for: roleID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try input.data.write(to: url, options: .atomic)
        return image
    }

    public func imageURL(_ image: ChatImage, for roleID: UUID) -> URL {
        imageURL(image, in: roleDirectory(roleID))
    }

    private func imageURL(_ image: ChatImage, in directory: URL) -> URL {
        directory.appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(image.id.uuidString).appendingPathExtension(image.fileExtension)
    }

    func roleDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("roles", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, at url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
