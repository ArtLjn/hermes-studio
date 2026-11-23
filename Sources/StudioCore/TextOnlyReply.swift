import Foundation

public struct TextOnlyReply {
    public let text: String
    public let attemptedToolCall: Bool

    public static func parse(_ reply: String, streaming: Bool = false) -> Self {
        let marker = #"<\s*/?\s*[|｜]\s*[|｜]\s*DSML\b"#
        if let range = reply.range(of: marker, options: [.regularExpression, .caseInsensitive]) {
            let prefix = reply[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let notice = "> 暖光提示：当前对话支持文字回复。可以把要讨论的文字内容发到这里。"
            return Self(text: streaming ? prefix : [prefix, notice].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                attemptedToolCall: true)
        }
        if streaming, let start = reply.lastIndex(of: "<") {
            let suffix = reply[start...].filter { !$0.isWhitespace }.uppercased().replacingOccurrences(of: "｜", with: "|")
            if "<||DSML".hasPrefix(suffix) || "</||DSML".hasPrefix(suffix) {
                return Self(text: String(reply[..<start]), attemptedToolCall: false)
            }
        }
        return Self(text: reply, attemptedToolCall: false)
    }
}
