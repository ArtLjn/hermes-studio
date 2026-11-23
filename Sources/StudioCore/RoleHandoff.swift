import Foundation

public struct RoleHandoff: Codable, Equatable, Sendable {
    public let targetRoleID: UUID
    public let targetName: String
    public var isQuestion: Bool?
    public var brief: String?

    public init(target: Role, isQuestion: Bool = false) {
        targetRoleID = target.id
        targetName = target.name
        self.isQuestion = isQuestion ? true : nil
    }

    public static func candidates(for word: String, in roles: [Role], excluding sourceID: UUID) -> [Role] {
        guard word.hasPrefix("@"), !word.hasPrefix("@file:"), !word.hasPrefix("@folder:") else { return [] }
        let query = String(word.dropFirst())
        let matches = roles.filter {
            $0.id != sourceID && $0.archivedAt == nil &&
                (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
        let isExact = { (role: Role) in role.name.localizedCaseInsensitiveCompare(query) == .orderedSame }
        return matches.filter(isExact) + matches.filter { !isExact($0) }
    }

    public func preparationPrompt(task: String) -> String {
        if isQuestion == true {
            return """
            用户请你向助手「\(targetName)」请教。请结合当前会话和用户给出的目标，拟一条可以独立理解的协作问题。只补充对方解答所需的背景，省略密钥、隐私信息和无关记录。请输出可直接发送的问题正文，供用户审阅。

            用户希望请教的事项：
            \(task)
            """
        }
        return """
        用户请你为助手「\(targetName)」准备交接摘要。请根据当前会话和下面的任务说明，写出目标、已经完成的工作、可以交接的结果、待办事项和已知阻碍。未知信息请明确标注。只整理本次任务需要的内容，省略密钥、隐私信息和无关记录，无需继续执行原任务。

        用户的任务说明：
        \(task)
        """
    }

    public func deliveryText(task: String, sourceName: String) -> String? {
        guard let brief else { return nil }
        if isQuestion == true { return brief }
        return """
        来自助手「\(sourceName)」的交接

        用户的任务说明：
        \(task)

        助手的交接摘要：
        \(brief)
        """
    }
}

public struct RoleHandoffOrigin: Codable, Equatable, Sendable {
    public let roleID: UUID
    public let conversationID: UUID
    public let roleName: String

    public init(roleID: UUID, conversationID: UUID, roleName: String) {
        self.roleID = roleID
        self.conversationID = conversationID
        self.roleName = roleName
    }
}
