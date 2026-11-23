import Foundation

public enum GroupChatFocus: String, CaseIterable, Codable, Sendable {
    case userCentered, free

    public var title: String { self == .userCentered ? "围绕你" : "自由互动" }
    public var explanation: String {
        self == .userCentered
            ? "优先回应你的话和感受；通常一两位说话，问到你就等你回答。"
            : "成员可以互相接梗和讨论，仍受每轮发言上限约束。"
    }
}

public enum GroupChatActivity: String, CaseIterable, Codable, Sendable {
    case quiet, natural, lively

    public var title: String {
        switch self {
        case .quiet: "安静"
        case .natural: "自然"
        case .lively: "热络"
        }
    }

    public var explanation: String {
        switch self {
        case .quiet: "首轮回答后，等你发新消息或有人明确点名。"
        case .natural: "一位先回应，另一位可接梗或补充；有具体话头再继续，不必人人表态。"
        case .lively: "成员更愿意互相接话、开玩笑和提问；没有新内容可略过，达到上限就停。"
        }
    }

    func automaticReplyLimit(_ limit: Int) -> Int {
        switch self {
        case .quiet: 0
        case .natural, .lively: limit
        }
    }
}

public struct GroupMemberChatPreferences: Codable, Equatable, Sendable {
    public enum Initiative: String, CaseIterable, Codable, Sendable {
        case inherit, reserved, proactive, mentionedOnly

        public var title: String {
            switch self {
            case .inherit: "跟随群聊"
            case .reserved: "少接话"
            case .proactive: "主动接话"
            case .mentionedOnly: "仅被点名时发言"
            }
        }
    }

    public enum Tone: String, CaseIterable, Codable, Sendable {
        case inherit, cool, warm, playful, custom

        public var title: String {
            switch self {
            case .inherit: "沿用角色"
            case .cool: "清冷沉稳"
            case .warm: "热情亲切"
            case .playful: "活泼俏皮"
            case .custom: "自定义"
            }
        }

        var instruction: String {
            switch self {
            case .inherit, .custom: ""
            case .cool: "语气清冷沉稳，措辞利落，有分寸，偶尔带一点淡淡的幽默。"
            case .warm: "语气热情亲切，多回应别人的感受和细节。"
            case .playful: "语气活泼俏皮，可以轻松接梗，措辞自然。"
            }
        }
    }

    public enum Intensity: String, CaseIterable, Codable, Sendable {
        case subtle, natural, vivid

        public var title: String {
            switch self {
            case .subtle: "轻微"
            case .natural: "自然"
            case .vivid: "鲜明"
            }
        }
    }

    public var initiative: Initiative = .inherit
    public var tone: Tone = .inherit
    public var intensity: Intensity = .natural
    public var customTone = ""
    public var canOpenIdleTopic: Bool?
    public var canRequestRelay: Bool?
    public var toolPermissions: GroupToolPermissions?

    public init() {}

    public var normalized: Self {
        var result = self
        result.customTone = tone == .custom ? String(customTone.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)) : ""
        if result.tone == .custom && result.customTone.isEmpty { result.tone = .inherit }
        if result.tone == .inherit { result.intensity = .natural }
        if result.canOpenIdleTopic == true { result.canOpenIdleTopic = nil }
        if result.canRequestRelay == true { result.canRequestRelay = nil }
        if result.toolPermissions == GroupToolPermissions() { result.toolPermissions = nil }
        return result
    }

    public var summary: String {
        let value = normalized
        return [value.initiative == .inherit ? nil : value.initiative.title, value.tone == .inherit ? nil : value.tone.title]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var promptInstructions: String {
        let value = normalized
        var instructions: [String] = []
        switch value.initiative {
        case .inherit: break
        case .reserved: instructions.append("你在本群偏寡言。被点名时直接回答，少主动邀请别人接力。")
        case .proactive: instructions.append("你愿意在本群主动接话。可以回应其他成员刚说的细节，有具体问题时再邀请对方。")
        case .mentionedOnly: instructions.append("你只在被点名时发言。直接回应当前问题。")
        }
        if value.tone != .inherit {
            let note = value.tone == .custom ? value.customTone : value.tone.instruction
            instructions.append("本群的说话风格（\(value.intensity.title)）是「\(note)」。把它体现在措辞和语气上，继续用自己的角色身份发言。")
        }
        return instructions.joined(separator: "\n")
    }
}
