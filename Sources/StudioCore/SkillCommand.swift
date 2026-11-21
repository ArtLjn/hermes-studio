import Foundation

public struct SkillCommand: Equatable, Sendable {
    public let range: NSRange
    public let query: String

    public static func atCaret(_ caret: Int, in text: String) -> Self? {
        let source = text as NSString
        guard caret != NSNotFound, caret > 0, caret <= source.length else { return nil }
        let prefix = source.substring(to: caret)
        let line = prefix.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let leading = line.trimmingCharacters(in: .whitespaces)
        if leading.lowercased() == "/skill" || leading.lowercased().hasPrefix("/skill ") {
            let offset = (line as NSString).range(of: "/").location
            let start = caret - (line as NSString).length + offset
            return Self(range: NSRange(location: start, length: caret - start),
                query: String(leading.dropFirst(6)).trimmingCharacters(in: .whitespaces))
        }
        let token = line.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace).last ?? ""
        guard token.hasPrefix("/"), token.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }) else { return nil }
        let length = (token as NSString).length
        return Self(range: NSRange(location: caret - length, length: length), query: String(token.dropFirst()))
    }
}
