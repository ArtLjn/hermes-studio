import Foundation

public struct HermesSkill: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    var sourceDirectory: URL?

    public init(id: String, name: String, summary: String) {
        self.id = id
        self.name = name
        self.summary = summary
    }

    public static func matching(_ query: String, in skills: [Self]) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return skills }
        return skills.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
            || $0.summary.localizedCaseInsensitiveContains(query) }
            .sorted { left, right in
                let lhs = left.name.lowercased().hasPrefix(query.lowercased())
                let rhs = right.name.lowercased().hasPrefix(query.lowercased())
                return lhs != rhs ? lhs : left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }
}

extension HermesRuntime {
    public func installedSkills() -> [HermesSkill] {
        let config = skillConfiguration()
        return installedSkills(directories: config.directories, disabled: config.disabled)
    }

    func installedSkills(directories: [URL], disabled: Set<String>) -> [HermesSkill] {
        var installed: [String: HermesSkill] = [:]
        for directory in directories {
            let root = directory.resolvingSymlinksInPath()
            guard let entries = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in entries where url.lastPathComponent == "SKILL.md" {
                let folder = url.deletingLastPathComponent()
                let identifier = folder.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                guard !identifier.isEmpty, installed[identifier] == nil else { continue }
                let header = readHeader(url)
                let name = header["name"] ?? folder.lastPathComponent
                guard !disabled.contains(name), !disabled.contains(identifier) else { continue }
                var skill = HermesSkill(id: identifier, name: name, summary: header["description"] ?? "")
                skill.sourceDirectory = folder
                installed[identifier] = skill
            }
        }
        return installed.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func exposeSelectedSkills(_ skills: [HermesSkill], in home: URL) throws -> [URL] {
        let files = FileManager.default
        let root = home.appendingPathComponent(".selected-skills", isDirectory: true)
        let stage = home.appendingPathComponent(".selected-skills-\(UUID())", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: stage) }
        for skill in skills {
            guard let source = skill.sourceDirectory else { continue }
            let link = stage.appendingPathComponent(skill.id, isDirectory: true)
            try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createSymbolicLink(at: link, withDestinationURL: source)
        }
        do { try files.removeItem(at: root) } catch CocoaError.fileNoSuchFile {}
        try files.moveItem(at: stage, to: root)
        return [root]
    }

    private func readHeader(_ url: URL) -> [String: String] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 8_192) else { return [:] }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard lines.first == "---" else { return [:] }
        var fields: [String: String] = [:]
        for line in lines.dropFirst().prefix(while: { $0.trimmingCharacters(in: .whitespaces) != "---" }) {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2, ["name", "description"].contains(pieces[0]) else { continue }
            let value = pieces[1].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'")))
            if !value.isEmpty, !value.hasPrefix(">"), !value.hasPrefix("|") {
                fields[String(pieces[0])] = String(value.prefix(240))
            }
        }
        return fields
    }
}
