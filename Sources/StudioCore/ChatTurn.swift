import Foundation

public struct ChatTurn: Identifiable {
    public let request: Message?
    public let messages: [Message]
    public var id: UUID { request?.id ?? messages[0].id }

    public var canContinue: Bool {
        guard let request, request.handoff == nil, request.consultation == nil else { return false }
        if let interrupted = request.interrupted { return interrupted }
        // 旧版没有保存停止状态，只识别以已停止工具结束的回合。
        return messages.last?.tool?.status == "cancelled"
    }

    public var canRestoreRequest: Bool {
        guard let request, request.handoff == nil, request.consultation == nil else { return false }
        return messages.isEmpty
    }

    public struct Activity: Identifiable {
        public let messages: [Message]
        public let tools: [ToolRun]
        public var id: UUID { messages[0].id }
    }

    public static func collect(_ messages: [Message]) -> [ChatTurn] {
        var result: [ChatTurn] = []
        var request: Message?
        var output: [Message] = []
        for message in messages {
            if message.author == .user && message.isGuidance != true {
                if request != nil || !output.isEmpty { result.append(ChatTurn(request: request, messages: output)) }
                request = message
                output = []
            } else {
                output.append(message)
            }
        }
        if request != nil || !output.isEmpty { result.append(ChatTurn(request: request, messages: output)) }
        return result
    }

    public func presentation(running: Bool) -> (process: [Activity], reply: ArraySlice<Message>) {
        let lastAction = messages.lastIndex { $0.tool != nil || $0.isGuidance == true }
        let replyStart: Int
        if let lastAction {
            // ACP 的文本块没有回复阶段，最后一次操作之后的正文与图片属于回复。
            replyStart = running ? messages.endIndex : lastAction + 1
        } else {
            replyStart = messages.startIndex
        }
        var process: [Activity] = []
        var toolMessages: [Message] = []
        var tools: [ToolRun] = []
        for message in messages[..<replyStart] {
            if let tool = message.tool {
                toolMessages.append(message)
                tools.append(tool)
            } else {
                if !tools.isEmpty { process.append(Activity(messages: toolMessages, tools: tools)) }
                toolMessages = []
                tools = []
                process.append(Activity(messages: [message], tools: []))
            }
        }
        if !tools.isEmpty { process.append(Activity(messages: toolMessages, tools: tools)) }
        return (process, messages[replyStart...])
    }
}
