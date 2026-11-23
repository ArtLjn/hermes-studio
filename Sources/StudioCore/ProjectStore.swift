import Foundation

public struct StudioProject: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public let roleID: UUID
    public let name: String
    public let path: String
    public var created = Date()

    public var directory: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

private struct ProjectCatalog: Codable {
    var projects: [StudioProject] = []
}

private struct LegacyProject: Decodable {
    let id: UUID
    let name: String
    let path: String
    let created: Date
}

extension RoleStore {
    public func moveConversation(_ id: UUID, for roleID: UUID, to projectID: UUID?) throws -> Conversation {
        var threads = try conversations(for: roleID)
        guard let index = threads.firstIndex(where: { $0.id == id }) else {
            throw StudioError.message("找不到这条对话。")
        }
        if let projectID {
            let project = try requireProject(projectID, for: roleID)
            guard (try? project.directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw StudioError.message("项目目录已移动或不可访问。")
            }
        }
        if threads[index].projectID != projectID {
            threads[index].projectID = projectID
            try saveConversations(threads, for: roleID)
        }
        return threads[index]
    }

    public func projectsByRole() throws -> [UUID: [StudioProject]] {
        Dictionary(grouping: try readProjectCatalog().projects, by: \.roleID)
    }

    public func projects(for roleID: UUID) throws -> [StudioProject] {
        try readProjectCatalog().projects.filter { $0.roleID == roleID }
    }

    @discardableResult
    public func removeProject(_ id: UUID, for roleID: UUID) throws -> [Conversation] {
        var catalog = try readProjectCatalog()
        guard let index = catalog.projects.firstIndex(where: { $0.id == id && $0.roleID == roleID }) else {
            throw StudioError.message("找不到此助手的项目。")
        }
        let original = try conversations(for: roleID)
        var threads = original
        for index in threads.indices where threads[index].projectID == id {
            threads[index].projectID = nil
        }
        let detached = threads != original
        if detached { try saveConversations(threads, for: roleID) }
        catalog.projects.remove(at: index)
        do {
            try writeProjectCatalog(catalog)
        } catch {
            if detached { try saveConversations(original, for: roleID) }
            throw error
        }
        return threads
    }

    func requireProject(_ id: UUID, for roleID: UUID) throws -> StudioProject {
        guard let project = try projects(for: roleID).first(where: { $0.id == id }) else {
            throw StudioError.message("找不到此助手的项目。")
        }
        return project
    }

    public func createProject(name: String, directory: URL?, for roleID: UUID) throws -> StudioProject {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64, !name.contains("/"), !name.contains(":"), !name.contains("\\"),
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            name != ".", name != ".." else {
            throw StudioError.message("请输入有效的项目名称，最多 64 个字符。")
        }
        guard try list().contains(where: { $0.id == roleID }) else {
            throw StudioError.message("请选择一个可用的助手。")
        }
        var catalog = try readProjectCatalog()
        let files = FileManager.default
        let projectsRoot = roleDirectory(roleID).appendingPathComponent("Projects", isDirectory: true)
        let target = (directory ?? projectsRoot.appendingPathComponent(name, isDirectory: true)).standardizedFileURL
            .resolvingSymlinksInPath()
        guard !catalog.projects.contains(where: {
            $0.roleID == roleID && $0.directory.resolvingSymlinksInPath().path == target.path
        }) else {
            throw StudioError.message("这个项目目录已经关联。")
        }
        if directory != nil {
            guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw StudioError.message("请选择一个可以访问的文件夹。")
            }
        } else {
            try files.createDirectory(at: projectsRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard !files.fileExists(atPath: target.path) else {
                throw StudioError.message("已有同名目录。请选择该目录，或给新项目换一个名称。")
            }
            try files.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let project = StudioProject(roleID: roleID, name: name, path: target.path)
        catalog.projects.insert(project, at: 0)
        do {
            try writeProjectCatalog(catalog)
        } catch {
            if directory == nil, (try? files.contentsOfDirectory(atPath: target.path).isEmpty) == true {
                try? files.removeItem(at: target)
            }
            throw error
        }
        return project
    }

    private var projectCatalogURL: URL { root.appendingPathComponent("projects.json") }

    private func readProjectCatalog() throws -> ProjectCatalog {
        let data: Data
        do {
            data = try Data(contentsOf: projectCatalogURL)
        } catch CocoaError.fileReadNoSuchFile {
            return ProjectCatalog()
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(ProjectCatalog.self, from: data)
        } catch DecodingError.typeMismatch {
            return try migrateProjects(decoder.decode([LegacyProject].self, from: data))
        }
    }

    private func migrateProjects(_ legacy: [LegacyProject]) throws -> ProjectCatalog {
        let roles = try list() + archivedRoles()
        guard let defaultOwner = roles.first?.id else { return ProjectCatalog() }
        var owners: [UUID: [UUID]] = [:]
        for role in roles {
            for projectID in Set(try conversations(for: role.id).compactMap(\.projectID)) {
                owners[projectID, default: []].append(role.id)
            }
        }
        // 同一旧项目可能有多个助手使用，保留各自对话中的项目 ID 和原目录。
        let catalog = ProjectCatalog(projects: legacy.flatMap { project in
            owners[project.id, default: [defaultOwner]].map { roleID in
                StudioProject(id: project.id, roleID: roleID, name: project.name, path: project.path, created: project.created)
            }
        })
        try writeProjectCatalog(catalog)
        return catalog
    }

    private func writeProjectCatalog(_ catalog: ProjectCatalog) throws {
        try JSONEncoder().encode(catalog).write(to: projectCatalogURL, options: .atomic)
    }

    func relocateProjectPaths(from previousRoot: URL, to newRoot: URL) throws {
        let previousPath = previousRoot.resolvingSymlinksInPath().path
        var catalog = try readProjectCatalog()
        var changed = false
        for index in catalog.projects.indices {
            let project = catalog.projects[index]
            let path = project.directory.resolvingSymlinksInPath().path
            guard path.hasPrefix(previousPath + "/") else { continue }
            let relativePath = String(path.dropFirst(previousPath.count + 1))
            catalog.projects[index] = StudioProject(id: project.id, roleID: project.roleID, name: project.name,
                path: newRoot.appendingPathComponent(relativePath).path, created: project.created)
            changed = true
        }
        if changed { try writeProjectCatalog(catalog) }
    }
}
