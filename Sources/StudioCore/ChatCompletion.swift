import Foundation

public enum ChatCompletion {
    public static func suffix(for prefix: String, in threads: [Conversation], roleID: UUID, projectID: UUID?) -> String? {
        guard let currentLine = currentLine(in: prefix) else { return nil }
        for thread in threads where thread.roleID == roleID && thread.projectID == projectID {
            for message in thread.messages.reversed() where message.author == .user {
                for line in message.text.split(whereSeparator: \.isNewline).reversed() {
                    guard let suffix = remainder(after: currentLine, in: line) else { continue }
                    return suffix.isEmpty ? nil : suffix
                }
            }
        }
        return nil
    }

    fileprivate static func currentLine(in draft: String) -> Substring? {
        let line = draft.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, !draft.hasPrefix("/") else { return nil }
        return line
    }

    fileprivate static func remainder(after prefix: Substring, in line: Substring) -> String? {
        guard let match = line.range(of: prefix, options: [.anchored, .literal]) else { return nil }
        return String(line[match.upperBound...])
    }
}

public actor HermesInputHistory {
    private struct Revision: Equatable {
        let file: URL
        let modified: Date
        let size: NSNumber
        let inode: NSNumber
    }

    private var snapshot: (revision: Revision, lines: [Substring])?

    public init() {}

    public func suffix(for draft: String, in home: URL) -> String? {
        guard !Task.isCancelled, let prefix = ChatCompletion.currentLine(in: draft) else { return nil }
        let file = home.appendingPathComponent(".hermes_history").resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let modified = attributes[.modificationDate] as? Date,
            let size = attributes[.size] as? NSNumber,
            let inode = attributes[.systemFileNumber] as? NSNumber else {
            snapshot = nil
            return nil
        }
        let revision = Revision(file: file, modified: modified, size: size, inode: inode)
        if snapshot?.revision != revision {
            snapshot = nil
            guard let data = try? Data(contentsOf: file) else { return nil }
            // Hermes 的两种终端都会在每一行历史输入前写入一个加号。
            let lines = data.split(separator: 0x0A).flatMap { line -> [Substring] in
                guard line.first == 0x2B else { return [] }
                return String(decoding: line.dropFirst(), as: UTF8.self).split(whereSeparator: \.isNewline)
            }
            snapshot = (revision, lines)
        }
        let match = snapshot?.lines.reversed().lazy.compactMap { ChatCompletion.remainder(after: prefix, in: $0) }.first
        return match.flatMap { $0.isEmpty ? nil : $0 }
    }
}
