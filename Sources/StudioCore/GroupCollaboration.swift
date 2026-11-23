import Foundation

public struct GroupMembershipSummary: Encodable, Sendable {
    public struct Member: Encodable, Sendable {
        public let id: UUID
        public let name: String
    }

    public let id: UUID
    public let name: String
    public let members: [Member]
}

public struct GroupToolScope: Sendable {
    public let threadID: UUID
    public let turnID: UUID

    public init(threadID: UUID, turnID: UUID) {
        self.threadID = threadID
        self.turnID = turnID
    }
}

public struct GroupMemoryNote: Codable, Sendable {
    public let id: UUID
    public let groupID: UUID
    public let group: String
    public let title: String
    public let text: String
    public let author: String
    public let conversation: String
    public let created: Date
}

public struct GroupCollaboration: Sendable {
    private let roles: RoleStore
    private let groups: GroupDiscussionStore

    public init(roles: RoleStore) {
        self.roles = roles
        groups = GroupDiscussionStore(root: roles.root)
    }

    public static func inviteTargets(in text: String, roles: [Role]) throws -> [Role] {
        guard !text.hasPrefix("/"),
            !["不要", "别", "不必", "不用", "不需要", "禁止", "取消", "如果", "假如", "示例", "例子", "如何", "怎么邀请"]
                .contains(where: text.contains) else { return [] }
        let byName = Dictionary(grouping: roles.filter { !$0.name.isEmpty }, by: \.name)
        let matches = try byName.compactMap { name, candidates -> Role? in
            let literal = NSRegularExpression.escapedPattern(for: name)
            let pattern = #"(?:把|让|请)\s*@?\#(literal)\s*(?:也|一起)?\s*(?:邀请进来|拉进群|拉进来|加入群聊|加入这个群|加入我们群|加入群|进群|入群)|(?:邀请|拉|添加|加|叫)\s*@?\#(literal)\s*(?:也|一起)?\s*(?:进群|进来|入群|加入群聊|加入这个群|加入我们群|来群里)|^(?:请|帮我|谁|谁来|你们谁|你们谁来)?\s*邀请(?:一下|下)?\s*@?\#(literal)\s*(?:进群|进来|加入群聊)?\s*[。！!]*$"#
            guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
            guard candidates.count == 1 else { throw StudioError.message("存在多个名为「\(name)」的角色，请从成员设置中选择。") }
            return candidates.first
        }
        return roles.filter { role in matches.contains { $0.id == role.id } }
    }

    public static func requestsMemory(_ text: String) -> Bool {
        guard !text.hasPrefix("/"),
            !["不要", "别记", "不用记", "怎么", "如何", "能不能", "能否", "可以吗", "吗？"].contains(where: text.contains)
        else { return false }
        return text.hasPrefix("记住") || text.hasPrefix("请记住")
            || ["记到群记忆", "存到群记忆", "记入群记忆", "保存到群记忆", "帮我们记住", "帮我记住", "写入群记忆"].contains(where: text.contains)
    }

    public func memberships(for caller: UUID, scope: GroupToolScope? = nil, threadID: UUID? = nil) throws -> [GroupMembershipSummary] {
        let available = try roles.list()
        guard available.contains(where: { $0.id == caller }) else { throw StudioError.message("当前助手已不可用。") }
        let roots = try visibleDiscussions(for: caller, threadID: scope?.threadID ?? threadID)
            .filter { $0.parentGroupID == nil }
        return roots.map { group in
            GroupMembershipSummary(id: group.id, name: group.title, members: group.memberIDs.compactMap { id in
                available.first { $0.id == id }.map { GroupMembershipSummary.Member(id: $0.id, name: $0.name) }
            })
        }
    }

    public func searchHistory(for caller: UUID, threadID: UUID?, query: String, limit: Int) throws -> [GroupChatExcerpt] {
        try GroupDiscussionStore.searchChat(in: visibleDiscussions(for: caller, threadID: threadID), for: caller,
            matching: query, limit: limit)
    }

    public func searchMemory(for caller: UUID, threadID: UUID?, query: String, limit: Int) throws -> [GroupMemoryNote] {
        let visible = try visibleDiscussions(for: caller, threadID: threadID).filter { $0.parentGroupID == nil }
        let keywords = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes: [GroupMemoryNote] = visible.flatMap { group -> [GroupMemoryNote] in
            let directory = memoryURL(groupID: group.id, noteID: group.id).deletingLastPathComponent()
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(GroupMemoryNote.self, from: Data(contentsOf: $0)) }
                .filter { $0.groupID == group.id }
        }.filter { note in
            keywords.isEmpty || [note.title, note.text, note.group, note.conversation, note.author]
                .contains { $0.localizedCaseInsensitiveContains(keywords) }
        }
        return Array(notes.sorted { $0.created > $1.created }.prefix(min(max(limit, 1), 8)))
    }

    public func saveMemory(title: String, text: String, from caller: UUID, scope: GroupToolScope) throws -> GroupMemoryNote {
        guard let role = try roles.list().first(where: { $0.id == caller }),
            let thread = try groups.discussions().first(where: { $0.id == scope.threadID }),
            thread.memberIDs.contains(caller),
            let turn = thread.turns.first(where: { $0.id == scope.turnID && $0.roleID == caller }),
            turn.state == .running, turn.initiatedByUser, turn.groupMemoryRequest == true else {
            throw StudioError.message("当前回合需要用户明确要求写入群记忆。")
        }
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
        guard !title.isEmpty, !text.isEmpty else { throw StudioError.message("群记忆需要标题和正文。") }
        let file = memoryURL(groupID: thread.groupID, noteID: turn.id)
        if let data = try? Data(contentsOf: file) { return try JSONDecoder().decode(GroupMemoryNote.self, from: data) }
        let note = GroupMemoryNote(id: turn.id, groupID: thread.groupID, group: thread.title, title: title, text: text,
            author: role.name, conversation: thread.displayConversationTitle, created: Date())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(note).write(to: file, options: .atomic)
        return note
    }

    public func hasSavedMemory(groupID: UUID, turnID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: memoryURL(groupID: groupID, noteID: turnID).path)
    }

    private func visibleDiscussions(for caller: UUID, threadID: UUID?) throws -> [GroupDiscussion] {
        guard try roles.list().contains(where: { $0.id == caller }) else { throw StudioError.message("当前助手已不可用。") }
        let discussions = try groups.discussions().filter { $0.memberIDs.contains(caller) }
        guard let threadID else { return discussions }
        guard let thread = discussions.first(where: { $0.id == threadID }) else {
            throw StudioError.message("当前助手不在这个群聊中。")
        }
        return discussions.filter { $0.groupID == thread.groupID }
    }

    private func memoryURL(groupID: UUID, noteID: UUID) -> URL {
        roles.root.appendingPathComponent("groups/memories/\(groupID)/\(noteID).json")
    }

    public func stageInvitation(_ target: UUID, from caller: UUID, scope: GroupToolScope) throws -> String {
        let available = try roles.list()
        guard available.contains(where: { $0.id == caller }),
            let invitee = available.first(where: { $0.id == target }),
            let thread = try groups.discussions().first(where: { $0.id == scope.threadID }),
            thread.memberIDs.contains(caller), thread.permissions(for: caller).invitations,
            let turn = thread.turns.first(where: { $0.id == scope.turnID }),
            turn.roleID == caller, turn.state == .running, turn.initiatedByUser,
            turn.invitationTargets?.contains(target) == true else {
            throw StudioError.message("只能邀请用户在当前回合明确点名的可用助手。")
        }
        if thread.memberIDs.contains(target) { return "\(invitee.name)已在当前群聊。" }
        let marker = invitationMarker(target, scope: scope)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data().write(to: marker, options: .atomic)
        return "\(invitee.name)的邀请已提交，暖光会把成员加入当前群聊。"
    }

    public func sharedPageURL(for caller: UUID, scope: GroupToolScope) throws -> URL {
        guard try roles.list().contains(where: { $0.id == caller }),
            let thread = try groups.discussions().first(where: { $0.id == scope.threadID }),
            thread.memberIDs.contains(caller), thread.permissions(for: caller).sharedLinks,
            let turn = thread.turns.first(where: { $0.id == scope.turnID }),
            turn.roleID == caller, turn.state == .running, turn.initiatedByUser,
            let url = turn.sharedLink.flatMap(GroupSharedPage.authorizedURL) else {
            throw StudioError.message("当前回合没有可读取的用户链接。")
        }
        return url
    }

    public func requestedInvitations(_ targets: [UUID], scope: GroupToolScope) -> [UUID] {
        targets.filter { FileManager.default.fileExists(atPath: invitationMarker($0, scope: scope).path) }
    }

    public func finishInvitations(scope: GroupToolScope) {
        let directory = invitationMarker(scope.turnID, scope: scope).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
    }

    private func invitationMarker(_ target: UUID, scope: GroupToolScope) -> URL {
        roles.root.appendingPathComponent("groups/invitations/\(scope.threadID)/\(scope.turnID)/\(target)")
    }
}
