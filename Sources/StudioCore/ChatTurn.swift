import Foundation

public struct ChatTurn: Identifiable {
    public let request: Message?
    public let messages: [Message]
    public var id: UUID { request?.id ?? messages[0].id }

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
