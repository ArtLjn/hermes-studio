import Foundation

public struct GroupAttachment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public let name: String
    public let text: String
    public var image: ChatImage?

    public init(image: ChatImage) {
        self.image = image
        name = image.name
        text = ""
    }

    public init(file: URL) throws {
        let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true, let size = metadata.fileSize, size <= 64 * 1024 else {
            throw StudioError.message("群聊附件需为 64 KB 以内的 UTF-8 文本。")
        }
        let data = try Data(contentsOf: file)
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw StudioError.message("无法按 UTF-8 文本读取 \(file.lastPathComponent)。")
        }
        name = file.lastPathComponent
        self.text = text
    }
}

public struct GroupRelay: Codable, Equatable, Sendable {
    public let roleID: UUID
    public let question: String
    public var enqueued = false
    public var reviewed = false

    public static func extract(from reply: String) -> (String, GroupRelay?) {
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lineStart = reply.lastIndex(where: \.isNewline) else { return (reply, nil) }
        let line = reply[reply.index(after: lineStart)...].trimmingCharacters(in: .whitespaces)
        let marker = "[[接力 "
        guard line.hasPrefix(marker), let end = line.range(of: "]]"),
            let id = UUID(uuidString: String(line.dropFirst(marker.count).prefix(upTo: end.lowerBound))) else {
            return (reply, nil)
        }
        let question = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return (reply, nil) }
        return (String(reply[..<lineStart]).trimmingCharacters(in: .whitespacesAndNewlines),
            GroupRelay(roleID: id, question: question))
    }

    fileprivate static func namedMention(in reply: String, members: [Role]) -> GroupRelay? {
        guard let line = reply.split(whereSeparator: \.isNewline).last else { return nil }
        let matches: [GroupRelay] = members.compactMap { role in
            guard let question = namedMentionQuestion(in: line, recipientName: role.name) else { return nil }
            return GroupRelay(roleID: role.id, question: question)
        }
        return matches.count == 1 ? matches.first : nil
    }

    public func removingNamedMention(from answer: String, recipientName: String) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineStart = trimmed.lastIndex(where: \.isNewline).map { trimmed.index(after: $0) } ?? trimmed.startIndex
        guard Self.namedMentionQuestion(in: trimmed[lineStart...], recipientName: recipientName) == question else { return answer }
        return trimmed[..<lineStart].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func namedMentionQuestion(in line: Substring, recipientName: String) -> String? {
        let line = line.trimmingCharacters(in: .whitespaces)
        let mention = "@\(recipientName)"
        guard line.hasPrefix(mention) else { return nil }
        let text = line.dropFirst(mention.count)
        let separators = ":：,，"
        guard let separator = text.first, separator.isWhitespace || separators.contains(separator) else { return nil }
        let question = text.drop(while: { $0.isWhitespace || separators.contains($0) })
        return question.isEmpty ? nil : String(question)
    }
}

public struct GroupTurn: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case queued, running, completed, failed, cancelled }
    public enum Kind: String, Codable, Sendable {
        case topic, reaction, parallelTopic, parallelReply, proactiveTopic, everyoneTopic, everyoneReply
        case multiMention, multiMentionReply
    }

    public let id: UUID
    public let taskID: UUID
    public let roleID: UUID
    public let roleName: String
    public let requesterID: UUID?
    public let requesterName: String
    public let question: String
    public let attachments: [GroupAttachment]
    public let kind: Kind?
    public var created = Date()
    public var state: State = .queued
    public var answer: String?
    public var relay: GroupRelay?
    public var hidToolCall: Bool?
    public var mayPass: Bool?
    public var invitationTargets: [UUID]?
    public var joinedMemberNames: [String]?
    public var sharedLink: String?
    public var groupMemoryRequest: Bool?
    public var savedGroupMemory: Bool?
    fileprivate static let passMarker = "[[略过]]"
    public var startsTopic: Bool { kind == .topic || kind == .parallelTopic || kind == .proactiveTopic || kind == .everyoneTopic }
    public var addressesEveryone: Bool { kind == .everyoneTopic || kind == .everyoneReply }
    fileprivate var isGroupMention: Bool { addressesEveryone || kind == .multiMention || kind == .multiMentionReply }
    public var answersTopicIndependently: Bool { kind == .parallelTopic || kind == .parallelReply || isGroupMention }
    public var initiatedByUser: Bool {
        requesterID == nil && kind != .parallelReply && kind != .proactiveTopic && kind != .everyoneReply && kind != .multiMentionReply
    }

    public func visibleStreamedReply(_ reply: String) -> String {
        let text = TextOnlyReply.parse(reply, streaming: true).text
        if mayPass == true && Self.passMarker.hasPrefix(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return ""
        }
        return text
    }

    public init(role: Role, question: String, attachments: [GroupAttachment] = [],
        requesterID: UUID? = nil, requesterName: String = "你", taskID: UUID? = nil, kind: Kind? = nil) {
        let id = UUID()
        self.id = id
        self.taskID = taskID ?? id
        roleID = role.id
        roleName = role.name
        self.requesterID = requesterID
        self.requesterName = requesterName
        self.question = question
        self.attachments = attachments
        self.kind = kind
    }
}

public struct GroupDiscussion: Codable, Equatable, Identifiable, Sendable {
    public enum ReplyMode: String, CaseIterable, Codable, Sendable {
        case natural, sequential, parallel

        public var title: String {
            switch self {
            case .natural: "自然接话"
            case .sequential: "依次接话"
            case .parallel: "同时回应"
            }
        }

        public var explanation: String {
            switch self {
            case .natural: "先请一位回应，其他人有内容再补充。"
            case .sequential: "按顺序接话，每位都能看到前一位说了什么。"
            case .parallel: "两位独立回应同一个话题，适合收集不同观点。"
            }
        }
    }

    public var id = UUID()
    public var title: String
    public var goal: String
    public var memberIDs: [UUID]
    public var memberDuties: [UUID: String]?
    public var parentGroupID: UUID?
    public var conversationTitle: String?
    public var proposalID: UUID?
    public var updated = Date()
    public var pinnedAt: Date?
    public var archivedAt: Date?
    public var relayLimit = 0
    public var replyMode: ReplyMode?
    public var casualReplyLimit: Int?
    public var idleChatMinutes: Int?
    public var idleDailyLimit: Int?
    public var allowsFullAccess: Bool?
    public var toolPermissions: GroupToolPermissions?
    public var effectiveIdleDailyLimit: Int { min(max(idleDailyLimit ?? 1, 0), 3) }
    public func usesFullAccess(global: Bool) -> Bool { global && allowsFullAccess != false }
    public var chatActivity: GroupChatActivity?
    public var chatFocus: GroupChatFocus?
    public var effectiveChatFocus: GroupChatFocus { chatFocus ?? .userCentered }
    private var isUserCentered: Bool { effectiveReplyMode == .natural && effectiveChatFocus == .userCentered }
    public var continuesAfterMention: Bool?
    public var memberChatPreferences: [UUID: GroupMemberChatPreferences]?
    public var paused = false
    public var turns: [GroupTurn] = []
    public var sessions: [UUID: String] = [:]
    public var fullAccessSessions: [UUID: String]?
    // 新运行池与旧的逐会话运行目录分开，保留旧会话编号和原始数据。
    public var pooledSessions: [UUID: String]?
    public var pooledFullAccessSessions: [UUID: String]?
    public var pooledRuntimeKeys: [UUID: String]?
    public var effectiveReplyMode: ReplyMode { replyMode ?? .natural }
    public var simultaneousReplyLimit: Int { effectiveReplyMode == .parallel ? 2 : 1 }
    public static let casualReplyRange = 1...30
    public var casualMessagesPerTopic: Int {
        min(max(casualReplyLimit ?? (chatActivity == .lively ? 5 : effectiveReplyMode == .natural ? 3 : 4), Self.casualReplyRange.lowerBound),
            Self.casualReplyRange.upperBound)
    }
    public var effectiveChatActivity: GroupChatActivity { chatActivity ?? (casualMessagesPerTopic > 4 ? .lively : .natural) }
    public var groupID: UUID { parentGroupID ?? id }
    public func permissions(for roleID: UUID) -> GroupToolPermissions {
        (toolPermissions ?? GroupToolPermissions()).restricted(by: memberChatPreferences?[roleID]?.toolPermissions)
    }

    public func canRequestRelay(_ roleID: UUID) -> Bool {
        memberIDs.contains(roleID) && memberChatPreferences?[roleID]?.canRequestRelay != false
    }

    public func permitsScopedTools(for roleID: UUID, invitation: Bool, sharedLink: Bool) -> Bool {
        let permissions = permissions(for: roleID)
        return (!invitation || permissions.invitations) && (!sharedLink || permissions.sharedLinks)
    }
    public func attachments(for turn: GroupTurn) -> [GroupAttachment] {
        turn.attachments.isEmpty ? (turns.first { $0.id == turn.taskID }?.attachments ?? []) : turn.attachments
    }
    public var displayConversationTitle: String {
        if let conversationTitle, !conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return conversationTitle
        }
        let opening = turns.first(where: \.initiatedByUser)?.question
            ?? turns.first(where: { $0.kind == .proactiveTopic && $0.state == .completed })?.answer
        let text = opening?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = text?.prefix(while: { !$0.isNewline }), !firstLine.isEmpty {
            return String(firstLine.prefix(32))
        }
        return parentGroupID == nil ? "主对话" : "未命名对话"
    }

    public init(title: String, goal: String, memberIDs: [UUID], proposalID: UUID? = nil) {
        self.title = title
        self.goal = goal
        self.memberIDs = memberIDs
        self.proposalID = proposalID
    }

    public mutating func inheritGroupSettings(from group: GroupDiscussion) {
        title = group.title
        goal = group.goal
        memberIDs = group.memberIDs
        memberDuties = group.memberDuties
        relayLimit = group.relayLimit
        replyMode = group.replyMode
        casualReplyLimit = group.casualReplyLimit
        idleChatMinutes = group.idleChatMinutes
        idleDailyLimit = group.idleDailyLimit
        allowsFullAccess = group.allowsFullAccess
        toolPermissions = group.toolPermissions
        chatActivity = group.chatActivity
        chatFocus = group.chatFocus
        continuesAfterMention = group.continuesAfterMention
        memberChatPreferences = group.memberChatPreferences
    }

    @discardableResult
    public mutating func addTopic(_ text: String, attachments: [GroupAttachment], activeMembers: [Role],
        invitationTargets: [UUID] = [], sharedLink: URL? = nil, remembers: Bool = false, toEveryone: Bool = false) -> Bool {
        let available = orderedMembers(in: activeMembers)
        let active = topicSpeakers(available, invitation: !invitationTargets.isEmpty, sharedLink: sharedLink != nil,
            toEveryone: toEveryone)
        guard !active.isEmpty else { return false }
        let next = toEveryone ? 0 : nextOpenerIndex(in: active)
        let parallel = !toEveryone && effectiveReplyMode == .parallel && active.count >= 2
            && casualMessagesPerTopic >= 2 && invitationTargets.isEmpty && sharedLink == nil && !remembers
        let kind: GroupTurn.Kind = toEveryone ? .everyoneTopic : (parallel ? .parallelTopic : .topic)
        var opener = GroupTurn(role: active[next], question: text, attachments: attachments, kind: kind)
        opener.invitationTargets = invitationTargets.isEmpty ? nil : invitationTargets
        opener.sharedLink = sharedLink?.absoluteString
        opener.groupMemoryRequest = remembers ? true : nil
        turns.append(opener)
        if toEveryone {
            turns += available.filter { $0.id != opener.roleID }.map { role in
                GroupTurn(role: role, question: text, taskID: opener.id, kind: .everyoneReply)
            }
        } else if parallel {
            turns.append(GroupTurn(role: active[(next + 1) % active.count], question: text,
                taskID: opener.id, kind: .parallelReply))
        }
        return true
    }

    public func nextOrdinaryTopicSpeaker(activeMembers: [Role]) -> Role? {
        let active = topicSpeakers(orderedMembers(in: activeMembers), invitation: false, sharedLink: false, toEveryone: false)
        guard !active.isEmpty else { return nil }
        return active[nextOpenerIndex(in: active)]
    }

    public func predictedReaction(to topic: GroupTurn, activeMembers: [Role]) -> Role? {
        guard effectiveChatActivity.automaticReplyLimit(topicReplyLimit) > 1,
            !Self.isBareLink(topic.question), permitsNaturalContinuation(topic: topic, source: topic, chain: [topic]) else { return nil }
        return nextMember(after: topic.roleID, in: activeMembers, chain: [topic])
    }

    private var topicReplyLimit: Int { isUserCentered ? min(casualMessagesPerTopic, 2) : casualMessagesPerTopic }

    private func topicSpeakers(_ available: [Role], invitation: Bool, sharedLink: Bool, toEveryone: Bool) -> [Role] {
        let eligible = available.filter {
            (toEveryone || initiative(for: $0.id) != .mentionedOnly)
                && permitsScopedTools(for: $0.id, invitation: invitation, sharedLink: sharedLink)
        }
        if toEveryone { return eligible }
        let willing = eligible.filter { initiative(for: $0.id) != .reserved }
        return willing.isEmpty ? Array(eligible.prefix(1)) : willing
    }

    @discardableResult
    public mutating func addDirectedMessage(_ text: String, attachments: [GroupAttachment], to roleIDs: [UUID],
        activeMembers: [Role], invitationTargets: [UUID] = [], sharedLink: URL? = nil, remembers: Bool = false) -> Bool {
        let available = orderedMembers(in: activeMembers)
        var seen: Set<UUID> = []
        let ids = roleIDs.filter { seen.insert($0).inserted }
        let recipients = ids.compactMap { id in available.first { $0.id == id } }
        guard let first = recipients.first, recipients.count == ids.count,
            permitsScopedTools(for: first.id, invitation: !invitationTargets.isEmpty, sharedLink: sharedLink != nil) else { return false }
        var opener = GroupTurn(role: first, question: text, attachments: attachments,
            kind: recipients.count > 1 ? .multiMention : nil)
        opener.invitationTargets = invitationTargets.isEmpty ? nil : invitationTargets
        opener.sharedLink = sharedLink?.absoluteString
        opener.groupMemoryRequest = remembers ? true : nil
        turns.append(opener)
        turns += recipients.dropFirst().map { role in
            GroupTurn(role: role, question: text, taskID: opener.id, kind: .multiMentionReply)
        }
        return true
    }

    @discardableResult
    public mutating func addIdleTopic(now: Date, activeMembers: [Role]) -> Bool {
        guard let delay = idleChatMinutes, delay > 0, !paused,
            now.timeIntervalSince(updated) >= TimeInterval(delay) * 60,
            !turns.contains(where: { $0.state == .running || $0.state == .queued }) else { return false }
        let willing = orderedMembers(in: activeMembers).filter {
            initiative(for: $0.id) != .reserved && initiative(for: $0.id) != .mentionedOnly
                && memberChatPreferences?[$0.id]?.canOpenIdleTopic != false
        }
        let proactive = willing.filter { initiative(for: $0.id) == .proactive }
        let active = proactive.isEmpty ? willing : proactive
        guard !active.isEmpty else { return false }
        let role = active[nextOpenerIndex(in: active)]
        var turn = GroupTurn(role: role, question: "主动聊一个轻松的话题。", kind: .proactiveTopic)
        turn.mayPass = true
        turn.created = now
        turns.append(turn)
        return true
    }

    public func canStartIdleTopic(now: Date, groupTurns: [GroupTurn], allTurns: [GroupTurn],
        calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        guard (idleChatMinutes ?? 0) > 0, !paused, hour >= 9, hour < 22, effectiveIdleDailyLimit > 0,
            let lastUser = groupTurns.filter(\.initiatedByUser).map(\.created).max(),
            now.timeIntervalSince(lastUser) <= 3600,
            now.timeIntervalSince(updated) >= TimeInterval(max(idleChatMinutes ?? 0, 15)) * 60 else { return false }
        let own = groupTurns.filter { $0.kind == .proactiveTopic }
        guard own.filter({ calendar.isDate($0.created, inSameDayAs: now) }).count < effectiveIdleDailyLimit,
            allTurns.filter({ $0.kind == .proactiveTopic && calendar.isDate($0.created, inSameDayAs: now) }).count < 3
        else { return false }
        return own.map(\.created).max().map { lastUser > $0 } ?? true
    }

    private func nextOpenerIndex(in members: [Role]) -> Int {
        let previous = turns.last(where: \.startsTopic)?.roleID
        return members.firstIndex { $0.id == previous }.map { ($0 + 1) % members.count } ?? 0
    }

    public mutating func supersedeAutomaticReplies() {
        for index in turns.indices where turns[index].state == .queued
            && (turns[index].kind == .reaction || turns[index].kind == .proactiveTopic) {
            turns[index].state = .cancelled
        }
    }

    public func queuedTurnIndex() -> Int? {
        let running = turns.filter { $0.state == .running }
        guard running.count < simultaneousReplyLimit else { return nil }
        return turns.firstIndex { next in
            next.state == .queued && running.allSatisfy { active in
                active.roleID != next.roleID &&
                    (active.taskID != next.taskID || (active.answersTopicIndependently && next.answersTopicIndependently))
            }
        }
    }

    public mutating func recordReply(_ reply: String, at index: Int, activeMembers: [Role]) {
        let parsed = TextOnlyReply.parse(reply)
        if turns[index].mayPass == true, !parsed.attemptedToolCall,
            parsed.text.trimmingCharacters(in: .whitespacesAndNewlines) == GroupTurn.passMarker {
            turns[index].state = .completed
            turns[index].answer = nil
            turns[index].relay = nil
            return
        }
        let (answer, marker) = GroupRelay.extract(from: parsed.text)
        guard !answer.isEmpty else { turns[index].state = .failed; return }
        turns[index].state = .completed
        turns[index].answer = answer
        turns[index].relay = nil
        turns[index].hidToolCall = parsed.attemptedToolCall ? true : nil
        guard turns[index].kind != .proactiveTopic, !turns[index].isGroupMention, !parsed.attemptedToolCall, turns[index].invitationTargets?.isEmpty != false,
            turns[index].sharedLink == nil, turns[index].groupMemoryRequest != true else { return }
        let source = turns[index]
        let chain = turns.filter { $0.taskID == source.taskID }
        guard !chain.contains(where: { $0.hidToolCall == true }) else { return }
        let root = chain.first { $0.id == source.taskID }
        let continuesDirectReply = continuesAfterMention == true && root?.kind == nil && root?.initiatedByUser == true
        let topic = chain.first(where: \.startsTopic) ?? (continuesDirectReply ? root : nil)
        let linkOnly = topic.map { Self.isBareLink($0.question) } ?? false
        let automaticLimit = topicReplyLimit
        let topicHasRoom = topic == nil || chain.count < automaticLimit
        let spontaneousLimit = effectiveChatActivity.automaticReplyLimit(automaticLimit)
        let superseded = topic.map { topic in
            guard let rootIndex = turns.firstIndex(where: { $0.id == topic.id }) else { return false }
            return turns.dropFirst(rootIndex + 1).contains { $0.initiatedByUser && $0.state != .cancelled }
        } ?? false
        let peers = activeMembers.filter { memberIDs.contains($0.id) && $0.id != source.roleID }
        let candidate = canRequestRelay(source.roleID) ? (marker ?? GroupRelay.namedMention(in: answer, members: peers)) : nil
        let directed = candidate.flatMap { relay in
            peers.first { $0.id == relay.roleID }
        }
        if var relay = candidate, let recipient = directed {
            let limit = source.startsTopic && chain.count == 1 ? max(1, relayLimit) : max(0, relayLimit)
            if topicHasRoom, !linkOnly, !superseded, chain.count <= min(limit, 3), !chain.contains(where: { $0.roleID == recipient.id }) {
                enqueueReply(to: recipient, question: relay.question, source: source, after: index)
                relay.enqueued = true
            }
            turns[index].relay = relay
        } else if let topic, !linkOnly, chain.count < spontaneousLimit,
            permitsNaturalContinuation(topic: topic, source: source, chain: chain),
            !chain.contains(where: { $0.state != .completed }),
            !superseded,
            let next = nextMember(after: source.roleID, in: activeMembers, chain: chain) {
            enqueueReply(to: next, question: topic.question, source: source, after: index, kind: .reaction,
                allowsPass: continuesDirectReply || effectiveReplyMode == .natural)
        }
    }

    private func permitsNaturalContinuation(topic: GroupTurn, source: GroupTurn, chain: [GroupTurn]) -> Bool {
        guard effectiveReplyMode == .natural else { return true }
        let message = topic.question.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        let closing = ["谢谢", "谢谢大家", "好的", "好", "嗯", "收到", "晚安", "先不聊了", "别聊了", "停止", "停"]
        guard !closing.contains(message) else { return false }
        if isUserCentered {
            // 已向用户提问就让出发言权，避免其他成员继续聊自己的话题。
            let answer = source.answer ?? ""
            return chain.count == 1 && !answer.contains("？") && !answer.contains("?")
        }
        if effectiveChatActivity == .lively || chain.count == 1 { return true }
        // 普通成员也能接话；后续只有具体问题或主动成员才延长，避免逐人附和。
        let answer = source.answer ?? ""
        return answer.contains("？") || answer.contains("?")
            || memberIDs.contains { initiative(for: $0) == .proactive && $0 != source.roleID }
    }

    private static func isBareLink(_ question: String) -> Bool {
        let words = question.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.allSatisfy { word in
            guard let url = URLComponents(string: String(word)), let scheme = url.scheme?.lowercased() else { return false }
            return (scheme == "https" || scheme == "http") && url.host?.isEmpty == false
        }
    }

    private func orderedMembers(in activeMembers: [Role]) -> [Role] {
        memberIDs.compactMap { id in activeMembers.first { $0.id == id } }
    }

    private func initiative(for id: UUID) -> GroupMemberChatPreferences.Initiative {
        memberChatPreferences?[id]?.initiative ?? .inherit
    }

    private func nextMember(after roleID: UUID, in activeMembers: [Role], chain: [GroupTurn]) -> Role? {
        let active = orderedMembers(in: activeMembers)
        guard let index = active.firstIndex(where: { $0.id == roleID }) else { return nil }
        let rotated = active.suffix(from: index + 1) + active.prefix(index)
        let willing = rotated.filter {
            let preference = initiative(for: $0.id)
            return preference != .reserved && preference != .mentionedOnly
        }
        let counts = Dictionary(grouping: chain, by: \.roleID).mapValues(\.count)
        let least = willing.map { counts[$0.id, default: 0] }.min()
        let eligible = willing.filter { counts[$0.id, default: 0] == least }
        return eligible.first { initiative(for: $0.id) == .proactive } ?? eligible.first
    }

    private mutating func enqueueReply(to role: Role, question: String, source: GroupTurn, after index: Int,
        kind: GroupTurn.Kind? = nil, allowsPass: Bool = false) {
        var next = GroupTurn(role: role, question: question, requesterID: source.roleID,
            requesterName: source.roleName, taskID: source.taskID, kind: kind)
        if allowsPass { next.mayPass = true }
        if source.startsTopic, let waiting = turns.indices.dropFirst(index + 1).first(where: {
            turns[$0].state == .queued && turns[$0].taskID != source.taskID
        }) {
            turns.insert(next, at: waiting)
        } else {
            turns.append(next)
        }
    }

    public func prompt(for index: Int, members: [Role], fullAccess: Bool = false, groupMemoryAvailable: Bool = false) -> String {
        let turn = turns[index]
        let peers = members.filter { memberIDs.contains($0.id) && $0.id != turn.roleID }
            .map { role in
                let expertise = memberDuties?[role.id] ?? role.summary
                let detail = expertise.isEmpty ? "" : " · \(expertise.prefix(220))"
                return "\(role.name)（\(role.id.uuidString)）\(detail)"
            }.joined(separator: "\n")
        let history = turns[..<index].filter {
            $0.state == .completed && $0.answer?.isEmpty == false
                && (!turn.answersTopicIndependently || $0.taskID != turn.taskID)
        }.suffix(4).map {
            "\($0.requesterName)向\($0.roleName)提问：\($0.question.prefix(350))\n\($0.roleName)回复：\(TextOnlyReply.parse($0.answer ?? "").text.prefix(600))"
        }.joined(separator: "\n\n")
        let root = turns.first { $0.id == turn.taskID }
        let behavior = memberChatPreferences?[turn.roleID]?.promptInstructions ?? ""
        let tools = fullAccess ? "本群使用完全访问。可按用户当前需求使用角色的 Hermes 工具。" : "本群主要进行文字协作。"
        let memory = groupMemoryAvailable
            ? "可用 list_roles 查询其他助手，用 list_my_groups 核对群成员。涉及以前的约定时按需调用 search_group_memory，回看原话用 search_group_chat。可用工具以当前工具列表为准，需要操作时先实际调用，根据返回结果答复。"
            : ""
        let pace: String = switch effectiveChatActivity {
        case .quiet: "简洁回应当前消息，让对话自然停下来。"
        case .natural: "按平常聊天的节奏交流。"
        case .lively: "适合自然接梗，也可以分享一条新想法或问成员一个简短的问题。"
        }
        let materials = attachments(for: turn).filter { $0.image == nil }.map {
            "附件 \($0.name)：\n\($0.text)"
        }.joined(separator: "\n\n")
        let request: String
        switch turn.kind {
        case .topic, .parallelTopic:
            request = "用户在群里发起了话题，请自然、简短地回应。\n\(turn.question)"
        case .everyoneTopic, .everyoneReply:
            request = "用户点名了群里的所有成员。请从你的角色出发，补充一个具体角度。\n\(turn.question)"
        case .multiMention, .multiMentionReply:
            request = "用户邀请了你和另外几位成员回答。请从你的角色出发，直接回应用户。\n\(turn.question)"
        case .parallelReply:
            request = "你和另一位成员正在分别回应用户。请从自己的角色出发补一个具体角度，避免泛泛复述。无需替其他成员转述。\n\(turn.question)"
        case .proactiveTopic:
            request = "看看最近的群聊，有值得自然接着聊的一件小事就说一句，最多 80 字。无需调用工具、点名或接力。如果没有合适的话题，只输出 \(GroupTurn.passMarker)。避免假设用户现在做了什么。"
        case .reaction:
            let preceding = turns[..<index].last { $0.taskID == turn.taskID && $0.roleID == turn.requesterID }
            request = """
            \(root?.kind == .proactiveTopic ? "这是群成员主动开启的话题。" : "用户刚刚聊到：\(turn.question)")
            \(turn.requesterName)刚才说：\(TextOnlyReply.parse(preceding?.answer ?? "").text)
            \(effectiveChatFocus == .userCentered
                ? "这次直接对用户说话，优先回应用户最后一句和感受。上一位的话仅作参考，不要转而调侃或盘问其他成员。可补一个与用户有关的细节，一两句即可；已有人问用户问题就等用户回答。"
                : "这次主要接\(turn.requesterName)的话，不要重新回答一遍用户的问题。可接一个细节、玩笑、不同意见或具体问题，一两句即可。")
            不必附和、劝慰或轮流表态；不要描述「我来补充」「她已经说全了」这类发言流程。
            \(turn.mayPass == true ? "如果已经答清，而且没有新信息或自然的回应，只输出 \(GroupTurn.passMarker)。" : "")
            """
        case nil:
            let topic = root?.startsTopic == true ? "用户发起的话题：\(root?.question ?? "")\n" : ""
            request = "\(topic)\(turn.requesterName)给你的当前任务：\n\(turn.question)"
        }
        let relayInstructions: String
        if turn.isGroupMention {
            relayInstructions = "被点名的成员都会收到同一条消息，请直接回答用户。"
        } else if !canRequestRelay(turn.roleID) {
            relayInstructions = "请直接发言或接话，本群未给你开启发起接力的权限。"
        } else {
            relayInstructions = """
            有确实需要对方回答的具体问题时，才在最后一行写「@完整成员名 具体问题」。
            成员同名时，用「[[接力 成员的实际UUID]] 具体问题」指定。每次只点名一位。
            自然聊天可以直接回复前一个人或用户。没有具体接力请求时省略这行。
            """
        }
        return """
        你作为「\(turn.roleName)」在群聊「\(title)」发言。共同目标：\(goal)
        你在本群的分工：\(memberDuties?[turn.roleID] ?? "按当前任务协作")
        本群聊天节奏：\(pace)
        按角色自己的语气聊天，通常一两句就够。直接说这次想说的内容。
        \(effectiveChatFocus == .userCentered ? "聊天重心是用户。关心用户正在表达的具体事情，回应他的感受与需要；不要把他留在一旁，围绕成员之间的玩笑越聊越远。关心不是轮流安慰、夸奖或附和，不要求用户不断证明自己，保持各自性格。向用户提问后把话权交还给他。" : "成员可以自然互动，同时给用户留下参与对话的空间。")
        避免每次夸用户、复述前一个人的观点、用列表分析闲聊、或结尾固定追问。
        可以有不同看法，也可以让话题停下来。只根据可见记录说话，保留角色性格，勿编造亲身经历。
        \(behavior)
        可接力的其他成员和擅长事项：
        \(peers)
        \(relayInstructions)
        仅依据本轮材料和群聊可见内容，区分事实和推断。
        \(tools)
        \(memory)

        群聊近期记录：
        \(history)

        \(request)

        本任务明确附加的群聊材料：
        \(materials)
        """
    }
}

public struct GroupProposal: Codable, Equatable, Identifiable, Sendable {
    public struct Member: Codable, Equatable, Sendable {
        public let roleID: UUID
        public let reason: String
    }

    public var id = UUID()
    public let authorID: UUID
    public let title: String
    public let goal: String
    public let members: [Member]
    public let firstTask: String
    public var created = Date()
}

public struct GroupDiscussionStore: Sendable {
    let root: URL

    public init(root: URL) { self.root = root.appendingPathComponent("groups", isDirectory: true) }

    public func discussions() throws -> [GroupDiscussion] {
        let records = try readAll(GroupDiscussion.self, from: root.appendingPathComponent("discussions"))
        let groups = Dictionary(uniqueKeysWithValues: records.filter { $0.parentGroupID == nil }.map { ($0.id, $0) })
        return records.map { record in
            var thread = record
            if let parent = record.parentGroupID, let group = groups[parent] {
                thread.inheritGroupSettings(from: group)
            }
            return thread
        }.sorted { $0.updated > $1.updated }
    }

    public func proposals() throws -> [GroupProposal] {
        try readAll(GroupProposal.self, from: root.appendingPathComponent("proposals")).sorted { $0.created > $1.created }
    }

    public func save(_ discussion: GroupDiscussion) throws {
        try write(discussion, at: discussionDirectory(discussion.id).appendingPathComponent("record.json"))
    }

    public func propose(authorID: UUID, title: String, goal: String,
        members: [(id: UUID, reason: String)], firstTask: String, using roles: RoleStore) throws -> GroupProposal {
        let peers = try roles.collaborators(for: authorID)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstTask = firstTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !goal.isEmpty, !firstTask.isEmpty, !members.isEmpty,
            Set(members.map(\.id)).count == members.count,
            members.allSatisfy({ member in peers.contains(where: { $0.id == member.id }) }) else {
            throw StudioError.message("请提供群名、目标、首条任务，并通过角色目录选择互不重复的可用助手。")
        }
        let selected = members.map { GroupProposal.Member(roleID: $0.id, reason: $0.reason) }
        let proposal = GroupProposal(authorID: authorID, title: title, goal: goal, members: selected, firstTask: firstTask)
        if let existing = try proposals().first(where: {
            $0.authorID == authorID && $0.title == title && $0.goal == goal && $0.members == selected && $0.firstTask == firstTask
        }) { return existing }
        try write(proposal, at: root.appendingPathComponent("proposals/\(proposal.id.uuidString)/record.json"))
        return proposal
    }

    public func runtimeStore(for id: UUID, toolTurn: UUID? = nil, fullAccess: Bool = false) -> RoleStore {
        let base = fullAccess ? "full-access-profiles" : "profiles"
        let directory = toolTurn.map { "\(base)-by-turn/\($0)" } ?? base
        return RoleStore(root: discussionDirectory(id).appendingPathComponent(directory, isDirectory: true))
    }

    private func discussionDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("discussions/\(id.uuidString)", isDirectory: true)
    }

    private func readAll<Value: Decodable>(_ type: Value.Type, from directory: URL) throws -> [Value] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try items.filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap { item in
            do {
                return try JSONDecoder().decode(type, from: Data(contentsOf: item.appendingPathComponent("record.json")))
            } catch CocoaError.fileReadNoSuchFile {
                return nil
            }
        }
    }

    private func write<Value: Encodable>(_ value: Value, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

public final class GroupReplyStart: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchGroup()
    private var remaining = 2

    public init() {
        ready.enter()
        ready.enter()
    }

    func arrive() {
        lock.withLock {
            if remaining > 0 {
                remaining -= 1
                ready.leave()
            }
        }
        if ready.wait(timeout: .now() + .seconds(15)) == .timedOut { release() }
    }

    public func release() {
        lock.withLock {
            while remaining > 0 {
                remaining -= 1
                ready.leave()
            }
        }
    }
}

extension HermesRuntime {
    public func groupTurn(home: URL, roleID: UUID, sessionID: String?, prompt: String,
        images: [ImagePayload] = [],
        start: GroupReplyStart? = nil, mcpServers: [MCPServer.Connection] = [], skillIDs: Set<String>? = nil,
        fullAccess: Bool = false, toolsets: [String]? = nil, idle: Bool = false,
        control: TurnControl) -> AsyncStream<TurnEvent> {
        var conversation = Conversation(roleID: roleID)
        conversation.sessionID = sessionID
        var preferences = HermesRunPreferences()
        if fullAccess { preferences.selectApproval(.fullAccess) }
        else { preferences.effort = "low" }
        return streamTurn(home: home, conversation: conversation, text: prompt, images: images,
            skillIDs: fullAccess ? skillIDs : [], draft: !fullAccess,
            reuseDraftWorker: true, preferences: preferences, useModelDefaults: !fullAccess, groupStart: start, toolsets: toolsets,
            prepareVision: !fullAccess, sessionMCPServers: mcpServers,
            budget: idle ? .idle : fullAccess ? .tools : .chat, control: control)
    }
}
