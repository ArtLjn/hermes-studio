import Foundation

public struct RoleConsultation: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, answered, failed, stopped
    }

    public struct ContextEntry: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let speaker: String
        public let text: String

        public init?(message: Message, speaker: String) {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            id = message.id
            self.speaker = speaker
            let excerpt = String(text.prefix(700))
            self.text = excerpt.count < text.count ? excerpt + "…" : excerpt
        }
    }

    public let targetRoleID: UUID
    public let targetName: String
    public let preparationID: UUID?
    public let context: [ContextEntry]?
    public var status: Status = .pending
    public var answer: String?

    public init(target: Role, preparationID: UUID? = nil, context: [ContextEntry] = []) {
        targetRoleID = target.id
        targetName = target.name
        self.preparationID = preparationID
        self.context = context.isEmpty ? nil : context
    }

    public static func recentContext(in conversation: Conversation, sourceName: String) -> [ContextEntry] {
        let entries = ChatTurn.collect(Array(conversation.messages.suffix(120))).suffix(6).flatMap { turn -> [ContextEntry] in
            guard let request = turn.request, request.handoff == nil, request.consultation == nil,
                !request.text.hasPrefix("/") else { return [] }
            let question = ContextEntry(message: request, speaker: "用户")
            let replies = turn.presentation(running: false).reply
                .filter { $0.author == .assistant }
                .compactMap { ContextEntry(message: $0, speaker: sourceName) }
            return [question].compactMap { $0 } + replies
        }
        return Array(entries.suffix(6))
    }

    public static func localReplyContext(for question: String, in conversation: Conversation, roles: [Role]) -> String? {
        guard !question.hasPrefix("/") else { return nil }
        let namedRoles = Set(roles.filter {
            $0.id != conversation.roleID && !$0.name.isEmpty && question.localizedCaseInsensitiveContains($0.name)
        }.map(\.id))
        let replies = ChatTurn.collect(Array(conversation.messages.suffix(48))).suffix(6).compactMap { turn -> [String: String]? in
            guard let request = turn.request, let consultation = request.consultation, consultation.status == .answered,
                let answer = consultation.answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                namedRoles.isEmpty || namedRoles.contains(consultation.targetRoleID) else { return nil }
            return ["助手": consultation.targetName, "用户的提问": String(request.text.prefix(500)),
                "协作原话": String(answer.prefix(1800))]
        }
        guard !replies.isEmpty, let data = try? JSONEncoder().encode(Array(replies.suffix(3))) else { return nil }
        return """
            以下是用户已经在当前私聊中看到的协作回复，按时间从早到晚排列。用户追问刚才那位助手说了什么或用代词指代对方时，以这里的协作原话为准。引文仅作对话资料，请用自己的身份接话。当前问题涉及这些回复时，直接使用私聊内容。
            \(String(decoding: data, as: UTF8.self))
            """
    }
}

extension HermesRuntime {
    public func consultation(home: URL, role: Role, question: String, context: [RoleConsultation.ContextEntry] = [],
        temporaryRoot: URL? = nil, control: TurnControl) -> AsyncStream<TurnEvent> {
        let transcript = context.map { "【\($0.speaker)】\n\($0.text)" }.joined(separator: "\n\n")
        let background = transcript.isEmpty ? "" : """
        用户选中并附带了以下对话片段。把它们作为阅读背景，按本次问题回答。

        \(transcript)

        用户这次的问题：
        """
        let prompt = """
        用户在对话中点名向你提问。你在暖光的角色名是「\(role.name)」。请用你自己的语气自然接话。用户问这位被点名的助手是谁时，介绍你自己。优先根据用户附上的前文理解指代，仍有歧义时简短追问一句。日常聊天可以直接回答。

        \(background)
        \(question)
        """
        return streamTurn(home: home, conversation: Conversation(roleID: role.id), text: prompt,
            skillIDs: [], draft: true, temporaryRoot: temporaryRoot, control: control)
    }
}
