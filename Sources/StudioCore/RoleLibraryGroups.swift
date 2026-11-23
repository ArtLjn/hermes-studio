import Darwin
import Foundation

struct RoleLibraryGroup: Codable, Equatable {
    var id = UUID()
    let name: String
}

struct RoleLibraryCatalog: Codable, Equatable {
    var groups: [RoleLibraryGroup]
    let legacyIDs: [String: UUID]

    init(roles: [Role]) {
        groups = Role.libraryGroupNames(in: roles).map { RoleLibraryGroup(name: $0) }
        legacyIDs = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0.id) })
    }

    func resolve(_ role: Role) -> Role {
        var value = role
        let id = role.libraryGroupID ?? role.libraryGroup.flatMap { legacyIDs[$0] }
        let group = groups.first { $0.id == id }
        value.libraryGroupID = group?.id
        value.libraryGroup = group?.name
        return value
    }
}

extension RoleStore {
    private var libraryCatalogURL: URL { root.appendingPathComponent("role-groups.json") }

    func storedLibraryCatalog() throws -> RoleLibraryCatalog? {
        do { return try JSONDecoder().decode(RoleLibraryCatalog.self, from: Data(contentsOf: libraryCatalogURL)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    public func libraryGroups() throws -> [String] {
        if let catalog = try storedLibraryCatalog() { return catalog.groups.map(\.name) }
        return Role.libraryGroupNames(in: try readRoleRecords())
    }

    public func libraryGroupName(_ input: String) throws -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard name.count <= 24, !name.contains(where: \.isNewline), !["未分组", "全部分组"].contains(name) else {
            throw StudioError.message("分组名应为 24 字以内的单行文字，「未分组」和「全部分组」是系统选项。")
        }
        return name
    }

    @discardableResult
    public func createLibraryGroup(_ input: String) throws -> String {
        try ensureLibraryGroup(input, createIfMissing: true).name
    }

    func ensureLibraryGroup(_ input: String, createIfMissing: Bool) throws -> RoleLibraryGroup {
        guard let name = try libraryGroupName(input) else { throw StudioError.message("请输入分组名。") }
        return try editLibraryCatalog { catalog in
            if let existing = catalog.groups.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return existing
            }
            guard createIfMissing else { throw StudioError.message("这个分组已解散，请选择其他分组。") }
            let group = RoleLibraryGroup(name: name)
            catalog.groups.append(group)
            return group
        }
    }

    public func dissolveLibraryGroup(_ name: String) throws {
        try editLibraryCatalog { catalog in
            // 保留旧分组的标识，防止尚未改写的旧角色在同名重建后重新加入。
            catalog.groups.removeAll { $0.name == name }
        }
    }

    @discardableResult
    public func reorderLibraryGroup(_ name: String, to target: String) throws -> Bool {
        try editLibraryCatalog { catalog in
            guard name != target, let source = catalog.groups.firstIndex(where: { $0.name == name }),
                let destination = catalog.groups.firstIndex(where: { $0.name == target }) else { return false }
            let group = catalog.groups.remove(at: source)
            catalog.groups.insert(group, at: destination)
            return true
        }
    }

    private func editLibraryCatalog<Result>(_ edit: (inout RoleLibraryCatalog) throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = root.appendingPathComponent(".role-groups.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        let stored = try storedLibraryCatalog()
        var catalog = try stored ?? RoleLibraryCatalog(roles: readRoleRecords())
        let result = try edit(&catalog)
        if catalog != stored { try JSONEncoder().encode(catalog).write(to: libraryCatalogURL, options: .atomic) }
        return result
    }
}
