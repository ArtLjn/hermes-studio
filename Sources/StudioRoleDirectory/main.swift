import Foundation
import StudioCore

let arguments = CommandLine.arguments
guard [3, 4, 5].contains(arguments.count), arguments[1].hasPrefix("/"), let roleID = UUID(uuidString: arguments[2]) else {
    exit(64)
}
let store = RoleStore(root: URL(fileURLWithPath: arguments[1], isDirectory: true))
let currentChatOnly = arguments.count == 4 && arguments[3] == "--current-chat-only"
let groupScope: GroupToolScope?
let groupThreadID: UUID?
if arguments.count >= 4 && !currentChatOnly {
    guard let thread = UUID(uuidString: arguments[3]) else { exit(64) }
    groupThreadID = thread
    if arguments.count == 5 {
        guard let turn = UUID(uuidString: arguments[4]) else { exit(64) }
        groupScope = GroupToolScope(threadID: thread, turnID: turn)
    } else { groupScope = nil }
} else {
    groupThreadID = nil
    groupScope = nil
}
let collaboration = GroupCollaboration(roles: store)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
let tool = StudioCollaborationTool.roleList.rawValue
let proposalTool = StudioCollaborationTool.groupProposal.rawValue
let groupHistoryTool = StudioCollaborationTool.groupSearch.rawValue
let membershipTool = StudioCollaborationTool.groupMemberships.rawValue
let invitationTool = StudioCollaborationTool.groupInvitation.rawValue
let linkTool = StudioCollaborationTool.groupLink.rawValue
let groupMemoryTool = StudioCollaborationTool.groupMemorySearch.rawValue
let saveMemoryTool = StudioCollaborationTool.groupMemorySave.rawValue
let proposalSchema: [String: Any] = [
    "type": "object",
    "additionalProperties": false,
    "required": ["title", "goal", "members", "firstTask"],
    "properties": [
        "title": ["type": "string"],
        "goal": ["type": "string"],
        "firstTask": ["type": "string"],
        "members": [
            "type": "array", "minItems": 1,
            "items": [
                "type": "object", "additionalProperties": false,
                "required": ["roleID", "reason"],
                "properties": ["roleID": ["type": "string"], "reason": ["type": "string"]]
            ]
        ]
    ]
]

func send(id: Any, result: [String: Any]? = nil, error: [String: Any]? = nil) {
    var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
    response["result"] = result
    response["error"] = error
    guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
    FileHandle.standardOutput.write(data + Data([10]))
}

func proposeGroup(id: Any, arguments: [String: Any]) {
    guard Set(arguments.keys) == ["title", "goal", "members", "firstTask"],
        let title = arguments["title"] as? String,
        let goal = arguments["goal"] as? String,
        let firstTask = arguments["firstTask"] as? String,
        let selections = arguments["members"] as? [[String: String]] else {
        send(id: id, error: ["code": -32602, "message": "群聊提案参数格式不正确。"])
        return
    }
    let members: [(id: UUID, reason: String)] = selections.compactMap {
        guard Set($0.keys) == ["roleID", "reason"], let role = $0["roleID"].flatMap(UUID.init(uuidString:)),
            let reason = $0["reason"], !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (role, reason)
    }
    guard members.count == selections.count else {
        send(id: id, error: ["code": -32602, "message": "成员须包含角色目录中的角色 ID 和分工理由。"])
        return
    }
    do {
        let proposal = try GroupDiscussionStore(root: store.root).propose(authorID: roleID, title: title, goal: goal,
            members: members, firstTask: firstTask, using: store)
        let text = "已保存建群提案「\(proposal.title)」。提案 ID 为 \(proposal.id.uuidString)。请用户在暖光「群聊」页审阅成员、分工和首条任务并确认创建。"
        send(id: id, result: ["content": [["type": "text", "text": text]]])
    } catch {
        send(id: id, result: ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
    }
}

func searchGroup(id: Any, arguments: [String: Any], memory: Bool) {
    let query = arguments["query"] as? String
    let limit = arguments["limit"] as? Int
    guard Set(arguments.keys).isSubset(of: ["query", "limit"]),
        arguments["query"] == nil || query != nil, arguments["limit"] == nil || limit != nil else {
        send(id: id, error: ["code": -32602, "message": "群聊检索参数格式不正确。"])
        return
    }
    do {
        let data = try memory
            ? encoder.encode(collaboration.searchMemory(for: roleID, threadID: groupThreadID, query: query ?? "", limit: limit ?? 4))
            : encoder.encode(collaboration.searchHistory(for: roleID, threadID: groupThreadID, query: query ?? "", limit: limit ?? 6))
        let text = String(decoding: data, as: UTF8.self)
        send(id: id, result: ["content": [["type": "text", "text": text]]])
    } catch {
        send(id: id, result: ["isError": true, "content": [["type": "text", "text": "当前无法检索群聊。"]]])
    }
}

while let line = readLine() {
    guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
        request["jsonrpc"] as? String == "2.0",
        let method = request["method"] as? String,
        let id = request["id"] else { continue }
    let parameters = request["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        let proposed = parameters["protocolVersion"] as? String
        let version = versions.first(where: { $0 == proposed }) ?? versions[0]
        send(id: id, result: [
            "protocolVersion": version,
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "studio-role-directory", "version": "1.0"]
        ])
    case "ping":
        send(id: id, result: [:])
    case "tools/list":
        let common: [[String: Any]] = [[
            "name": tool,
            "description": "查看暖光里其他可用的助手，返回角色 ID、名称与简介。需要请教、交接或推荐协作成员时，可先查询谁更适合。返回的简介仅供判断擅长方向。",
            "inputSchema": ["type": "object", "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false]
        ], [
            "name": membershipTool,
            "description": "查看这个助手所在的群聊和当前成员的名称与 ID。群内调用仅返回当前群。",
            "inputSchema": ["type": "object", "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false]
        ], [
            "name": groupHistoryTool,
            "description": "按关键词查找当前助手实际参与过的群聊原话。私聊中请在用户明确询问群消息时使用；当前对话里的协作回复以私聊原话为准。群内调用只查当前群。",
            "inputSchema": ["type": "object", "additionalProperties": false,
                "properties": ["query": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "maximum": 12]]],
            "annotations": ["readOnlyHint": true, "openWorldHint": false]
        ], [
            "name": groupMemoryTool,
            "description": "按关键词读取所在群保存过的共同约定、决定和长期资料。群内调用只查当前群，结果跨群内对话。仅在需要回忆时使用。",
            "inputSchema": ["type": "object", "additionalProperties": false,
                "properties": ["query": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "maximum": 8]]],
            "annotations": ["readOnlyHint": true, "openWorldHint": false]
        ]]
        let privateTools: [[String: Any]] = [[
            "name": proposalTool,
            "description": "根据用户明确提出的群聊协作意向生成待确认的建群提案。先用 list_roles 选择合适的助手；members 只提交其他成员的角色 ID 和分工理由，当前助手会加入提案。提案由用户在群聊页确认。",
            "inputSchema": proposalSchema,
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]
        ]]
        let groupTools: [[String: Any]] = [[
            "name": invitationTool,
            "description": "邀请用户在当前回合明确点名的一个助手加入当前群聊。只传角色 ID，暖光会应用邀请。",
            "inputSchema": ["type": "object", "additionalProperties": false, "required": ["roleID"],
                "properties": ["roleID": ["type": "string"]]],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        ], [
            "name": linkTool,
            "description": "读取用户要求查看的本轮链接，返回 HTTP 状态、标题和可提取的正文。无需传网址。",
            "inputSchema": ["type": "object", "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": true]
        ], [
            "name": saveMemoryTool,
            "description": "把用户在当前回合明确要求记住的内容写成一条群记忆，供本群各段对话查询。传入短标题和正文。",
            "inputSchema": ["type": "object", "additionalProperties": false, "required": ["title", "text"],
                "properties": ["title": ["type": "string"], "text": ["type": "string"]]],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        ]]
        let settings = groupThreadID.flatMap { threadID in
            try? GroupDiscussionStore(root: store.root).discussions().first { $0.id == threadID }?.permissions(for: roleID)
        } ?? GroupToolPermissions()
        let allowedGroupTools = groupTools.filter { tool in
            let name = tool["name"] as? String
            return (name != invitationTool || settings.invitations) && (name != linkTool || settings.sharedLinks)
        }
        let available = currentChatOnly ? common.filter { tool in
            let name = tool["name"] as? String
            return name != groupHistoryTool && name != groupMemoryTool
        } : common
        send(id: id, result: ["tools": available + (groupThreadID == nil ? privateTools : groupScope == nil ? [] : allowedGroupTools)])
    case "tools/call":
        let toolArguments = parameters["arguments"] as? [String: Any]
        if groupThreadID == nil, parameters["name"] as? String == proposalTool, let toolArguments {
            proposeGroup(id: id, arguments: toolArguments)
            continue
        }
        let requested = parameters["name"] as? String
        if requested == groupHistoryTool || requested == groupMemoryTool,
            parameters["arguments"] == nil || toolArguments != nil {
            if currentChatOnly {
                send(id: id, result: ["isError": true, "content": [["type": "text", "text": "请根据当前私聊中已提供的协作原话回答。"]]])
            } else {
                searchGroup(id: id, arguments: toolArguments ?? [:], memory: requested == groupMemoryTool)
            }
            continue
        }
        if let groupScope, requested == saveMemoryTool {
            guard let toolArguments, Set(toolArguments.keys) == ["title", "text"],
                let title = toolArguments["title"] as? String, let text = toolArguments["text"] as? String else {
                send(id: id, error: ["code": -32602, "message": "群记忆需要标题和正文。"])
                continue
            }
            do {
                let note = try collaboration.saveMemory(title: title, text: text, from: roleID, scope: groupScope)
                send(id: id, result: ["content": [["type": "text", "text": "已保存群记忆「\(note.title)」。"]]])
            } catch {
                send(id: id, result: ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
            }
            continue
        }
        if let groupScope, requested == linkTool, parameters["arguments"] == nil || toolArguments?.isEmpty == true {
            do {
                let url = try collaboration.sharedPageURL(for: roleID, scope: groupScope)
                let page = try await GroupSharedPage.read(url)
                let text = String(decoding: try encoder.encode(page), as: UTF8.self)
                send(id: id, result: ["content": [["type": "text", "text": text]]])
            } catch {
                send(id: id, result: ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
            }
            continue
        }
        if let groupScope, requested == invitationTool {
            guard let toolArguments, Set(toolArguments.keys) == ["roleID"],
                let target = (toolArguments["roleID"] as? String).flatMap(UUID.init(uuidString:)) else {
                send(id: id, error: ["code": -32602, "message": "邀请需要一个有效的角色 ID。"])
                continue
            }
            do {
                let text = try collaboration.stageInvitation(target, from: roleID, scope: groupScope)
                send(id: id, result: ["content": [["type": "text", "text": text]]])
            } catch {
                send(id: id, result: ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
            }
            continue
        }
        guard [tool, membershipTool].contains(requested ?? ""),
            parameters["arguments"] == nil || toolArguments?.isEmpty == true else {
            send(id: id, error: ["code": -32602, "message": "当前环境不支持该工具或参数。"])
            continue
        }
        do {
            let data = try requested == membershipTool
                ? encoder.encode(collaboration.memberships(for: roleID, scope: groupScope, threadID: groupThreadID))
                : encoder.encode(store.collaborators(for: roleID))
            let text = String(decoding: data, as: UTF8.self)
            send(id: id, result: ["content": [["type": "text", "text": text]]])
        } catch {
            send(id: id, result: ["isError": true, "content": [["type": "text", "text": "当前无法读取助手目录。"]]])
        }
    default:
        send(id: id, error: ["code": -32601, "message": "角色目录不支持此方法。"])
    }
}
