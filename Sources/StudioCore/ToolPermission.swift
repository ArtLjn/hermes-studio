import Foundation

public struct ToolPermission: Identifiable, Sendable {
    public struct Option: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let kind: String
    }

    public struct Edit: Sendable {
        public let path: String
        public let before: String?
        public let after: String?
    }

    public let id = UUID()
    public let toolID: String
    public let title: String
    public let kind: String
    public let details: String?
    public let edit: Edit?
    public let options: [Option]

    init?(_ parameters: [String: Any]) {
        guard let call = parameters["toolCall"] as? [String: Any],
            let toolID = call["toolCallId"] as? String else { return nil }
        let options = (parameters["options"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
            guard let id = option["optionId"] as? String, let name = option["name"] as? String,
                let kind = option["kind"] as? String else { return nil }
            return Option(id: id, name: name, kind: kind)
        }
        guard !options.isEmpty else { return nil }
        let input = call["rawInput"] as? [String: Any]
        let content = call["content"] as? [[String: Any]] ?? []
        let diff = content.first { $0["type"] as? String == "diff" }
        self.toolID = toolID
        self.kind = toolID.hasPrefix("clarify-") ? "clarify" : (call["kind"] as? String ?? "other")
        self.title = input?["description"] as? String ?? call["title"] as? String ?? "Hermes 请求权限"
        let text = content.compactMap { ($0["content"] as? [String: Any])?["text"] as? String }
            .joined(separator: "\n\n")
        self.details = input?["command"] as? String ?? (text.isEmpty ? nil : text)
        self.options = options
        self.edit = (diff?["path"] as? String).map {
            Edit(path: $0, before: diff?["oldText"] as? String, after: diff?["newText"] as? String)
        }
    }
}
