import Foundation

public enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case code(String, String)
    case quote(String)
    case list([ListItem])
    case table([[String]])
    case rule

    public struct ListItem: Equatable {
        public let marker: String
        public let text: String
    }

    public static func parse(_ markdown: String) -> [Self] {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var blocks: [Self] = []
        var index = 0
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll(keepingCapacity: true)
            }
        }
        while index < lines.count {
            let line = lines[index]
            let text = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if text.isEmpty {
                flush()
            } else if let fence = openingFence(text) {
                flush()
                var code: [String] = []
                while index < lines.count {
                    let next = lines[index]
                    index += 1
                    let stripped = next.trimmingCharacters(in: .whitespaces)
                    if stripped.hasPrefix(fence.marker), stripped.allSatisfy({ $0 == fence.marker.first }) { break }
                    code.append(next)
                }
                blocks.append(.code(fence.language, code.joined(separator: "\n")))
            } else if let header = heading(text) {
                flush()
                blocks.append(header)
            } else if text.count >= 3, let marker = text.first, "-*_".contains(marker),
                text.allSatisfy({ $0 == marker || $0.isWhitespace }) {
                flush()
                blocks.append(.rule)
            } else if text.hasPrefix(">") {
                flush()
                var quote = [String(text.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    quote.append(String(next.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
            } else if text.contains("|"), index < lines.count, isTableRule(lines[index]) {
                flush()
                var rows = [cells(text)]
                index += 1
                while index < lines.count, lines[index].contains("|") {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                blocks.append(.table(rows))
            } else if let item = listItem(text) {
                flush()
                var items = [item]
                while index < lines.count, let next = listItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.list(items))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func openingFence(_ line: String) -> (marker: String, language: String)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let marker = line.prefix(while: { $0 == first })
        guard marker.count >= 3 else { return nil }
        let language = line.dropFirst(marker.count).split(whereSeparator: \.isWhitespace).first ?? ""
        return (String(marker), String(language))
    }

    private static func heading(_ text: String) -> Self? {
        let hashes = text.prefix(while: { $0 == "#" })
        let rest = text.dropFirst(hashes.count)
        guard (1...6).contains(hashes.count), rest.first?.isWhitespace == true else { return nil }
        return .heading(hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ text: String) -> ListItem? {
        let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return nil }
        let bullet = parts[0]
        let ordered = bullet.count > 1 && (bullet.last == "." || bullet.last == ")")
            && bullet.dropLast().allSatisfy(\.isNumber)
        guard ordered || ["-", "*", "+"].contains(bullet) else { return nil }
        let content = String(parts[1])
        if content.hasPrefix("[ ] ") { return ListItem(marker: "☐", text: String(content.dropFirst(4))) }
        if content.lowercased().hasPrefix("[x] ") { return ListItem(marker: "☑", text: String(content.dropFirst(4))) }
        return ListItem(marker: ordered ? String(bullet) : "•", text: content)
    }

    private static func isTableRule(_ line: String) -> Bool {
        let columns = cells(line)
        return columns.count >= 2 && columns.allSatisfy {
            let rule = $0.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return rule.count >= 3 && rule.allSatisfy { $0 == "-" }
        }
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        var values: [String] = []
        var field = ""
        var escaped = false
        for character in row {
            if escaped {
                if character != "|" { field.append("\\") }
                field.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                values.append(field.trimmingCharacters(in: .whitespaces))
                field = ""
            } else {
                field.append(character)
            }
        }
        if escaped { field.append("\\") }
        values.append(field.trimmingCharacters(in: .whitespaces))
        return values
    }
}
