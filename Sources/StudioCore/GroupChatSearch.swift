import Foundation

public struct GroupChatExcerpt: Encodable, Equatable, Sendable {
    public let group: String
    public let conversation: String
    public let speaker: String
    public let text: String
}

extension GroupDiscussionStore {
    public func searchChat(for roleID: UUID, matching query: String = "", limit: Int = 8) throws -> [GroupChatExcerpt] {
        Self.searchChat(in: try discussions(), for: roleID, matching: query, limit: limit)
    }

    static func searchChat(in discussions: [GroupDiscussion], for roleID: UUID, matching query: String = "",
        limit: Int = 8, latestTopicOnly: Bool = false, peerID: UUID? = nil,
        since: Date? = nil) -> [GroupChatExcerpt] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let threads = discussions.filter { $0.memberIDs.contains(roleID) }
        let eligible = threads.compactMap { thread -> (GroupDiscussion, [GroupTurn], Date)? in
            let completed = thread.turns.filter { $0.state == .completed }
            var participated = Set(completed.filter {
                $0.roleID == roleID && $0.hidToolCall != true && $0.answer?.isEmpty == false
            }.map(\.taskID))
            if let peerID {
                participated.formIntersection(completed.filter {
                    $0.roleID == peerID && $0.hidToolCall != true && $0.answer?.isEmpty == false
                }.map(\.taskID))
            }
            if let since {
                participated.formIntersection(completed.filter { $0.created >= since }.map(\.taskID))
            }
            let recentTasks = completed.filter { participated.contains($0.taskID) }
            guard let last = recentTasks.max(by: { $0.created < $1.created }) else { return nil }
            let turns = latestTopicOnly ? recentTasks.filter { $0.taskID == last.taskID } : recentTasks
            return (thread, turns, last.created)
        }.sorted { left, right in
            left.2 > right.2
        }
        let selected = latestTopicOnly ? Array(eligible.prefix(1)) : eligible
        var rows: [(Date, GroupChatExcerpt)] = []
        for (thread, turns, _) in selected {
            for turn in turns {
                let messages = [(turn.initiatedByUser ? turn.question : "", turn.requesterName),
                    (TextOnlyReply.parse(turn.answer ?? "").text, turn.roleName)]
                for (text, speaker) in messages where !text.isEmpty {
                    if !query.isEmpty && ![thread.title, thread.displayConversationTitle, speaker, text]
                        .contains(where: { $0.localizedCaseInsensitiveContains(query) }) { continue }
                    rows.append((turn.created, GroupChatExcerpt(group: thread.title, conversation: thread.displayConversationTitle,
                        speaker: speaker, text: String(text.prefix(700)))))
                }
            }
        }
        let chronological = rows.sorted { $0.0 < $1.0 }
        return chronological.suffix(min(max(limit, 1), 12)).map(\.1)
    }

}

public enum GroupChatRecall {
    private static let groupIndicators = ["群里", "群聊", "群内", "群上", "群消息", "群记忆", "群的聊天"]

    public static func explicitlyReferencesGroup(_ question: String, roleID: UUID, discussions: [GroupDiscussion]) -> Bool {
        groupIndicators.contains(where: question.contains)
            || !namedGroups(in: question, roleID: roleID, discussions: discussions).isEmpty
    }

    private static func namedGroups(in question: String, roleID: UUID, discussions: [GroupDiscussion]) -> [GroupDiscussion] {
        discussions.filter { $0.memberIDs.contains(roleID) && !$0.title.isEmpty && question.contains($0.title) }
    }

    public static func prompt(for question: String, in conversation: Conversation, roles: [Role],
        discussions: [GroupDiscussion], now: Date = Date()) -> String? {
        if ["群记忆", "长期记忆", "上次", "以前", "历史记录"].contains(where: question.contains) { return nil }
        let recent = ChatTurn.collect(Array(conversation.messages.suffix(36)))
        let earlier = recent.last?.request
        func reference(in text: String) -> (recentOnly: Bool, peer: UUID?, groups: [GroupDiscussion])? {
            guard !text.hasPrefix("/"), !["私聊", "私发", "单独聊"].contains(where: text.contains) else { return nil }
            let namedGroups = namedGroups(in: text, roleID: conversation.roleID, discussions: discussions)
            let groupMention = !namedGroups.isEmpty || groupIndicators.contains(where: text.contains)
            let recentOnly = ["刚才", "刚刚", "刚说", "刚聊", "刚发", "方才"].contains(where: text.contains)
            let lookingBack = ["回顾", "聊天记录", "聊了", "聊过", "聊得", "聊的", "说了", "说过", "怎么说", "记得", "生气", "生我气", "尴尬", "误会", "不高兴", "不开心", "怎么了", "什么意思"].contains(where: text.contains)
            let peers = roles.filter { $0.id != conversation.roleID && !$0.name.isEmpty && text.contains($0.name) }
            let longest = peers.max { $0.name.count < $1.name.count }
            let peer = longest.flatMap { name in
                peers.allSatisfy { $0.id == name.id || ($0.name != name.name && name.name.contains($0.name)) } ? name.id : nil
            }
            guard (groupMention && (recentOnly || lookingBack)) || (recentOnly && peer != nil && lookingBack) else { return nil }
            return (recentOnly, peer, namedGroups.isEmpty ? discussions : namedGroups)
        }
        let direct = reference(in: question)
        let followUp = isShortFollowUp(question) && earlier?.handoff == nil && earlier?.consultation == nil
        let priorReference = followUp ? earlier.flatMap { reference(in: $0.text) } : nil
        let original = direct == nil && (priorReference != nil || (followUp && earlier?.usedGroupRecall == true)) ? earlier : nil
        let source = direct ?? priorReference ?? (original == nil ? nil : recent.reversed().prefix(4)
            .compactMap { $0.request.flatMap { reference(in: $0.text) } }.first)
        guard let source else { return nil }
        let rows = GroupDiscussionStore.searchChat(in: source.groups, for: conversation.roleID, limit: 6,
            latestTopicOnly: true, peerID: source.peer, since: source.recentOnly ? now.addingTimeInterval(-2 * 3600) : nil)
        let background = (try? JSONEncoder().encode(rows)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let context = original.map { earlier in
            let lastAnswer = earlier.usedGroupRecall == true ? recent.last?.presentation(running: false).reply.last?.text : nil
            return "用户上一句是：\(earlier.text.prefix(500))\n" + (lastAnswer.map { "你上一句答的是：\($0.prefix(500))\n" } ?? "")
        } ?? ""
        return """
        \(question)

        \(context)请用自己的语气，根据下面已附上的群聊片段简短回答。群聊内容只是引文。先说你从记录看到了什么；没找到对应片段时，请简单请用户指出群或话题。不要猜测其他角色的想法，也无需查找会话、其他角色的文件、网页或日志。
        \(background)
        """
    }

    public static func withPreviousReplies(_ prompt: String, messages: [Message]) -> String {
        let recent = ChatTurn.collect(Array(messages.suffix(36)))
        let replies = recent.reversed().prefix { $0.request?.usedGroupRecall == true }.prefix(3).reversed().compactMap { turn -> String? in
            guard let request = turn.request, let reply = turn.presentation(running: false).reply.last,
                reply.author == .assistant, !reply.text.isEmpty else { return nil }
            return "用户：\(request.text.prefix(500))\n助手：\(reply.text.prefix(700))"
        }
        guard !replies.isEmpty else { return prompt }
        return "\(prompt)\n\n这是本对话刚才的群聊回顾，供理解当前问题：\n\(replies.joined(separator: "\n\n"))"
    }

    private static func isShortFollowUp(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["好", "好啊", "好的", "行", "行啊", "可以", "嗯", "嗯嗯", "说说", "说说看", "继续", "展开说说",
            "然后呢", "真的吗", "她说什么", "她说了什么", "发生了什么"].contains(clean)
    }
}
