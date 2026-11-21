import AppKit
import StudioCore
import SwiftUI

@MainActor
final class StudioModel: ObservableObject {
    @Published private(set) var roles: [Role] = []
    @Published private(set) var archivedRoles: [Role] = []
    @Published private(set) var roleID: UUID?
    @Published private var projectsByRole: [UUID: [StudioProject]] = [:]
    @Published private(set) var projectID: UUID?
    @Published private(set) var conversationID: UUID?
    @Published private(set) var conversations: [UUID: [Conversation]] = [:]
    @Published private(set) var roleFiles: [RoleFile: String] = [:]
    @Published private(set) var showManagement = true
    @Published private(set) var available = false
    @Published private(set) var modelName = ""
    @Published private(set) var hermesUpdate: HermesUpdateCheck?
    @Published private(set) var checkingHermesUpdate = false
    @Published private(set) var terminalHome: URL?
    @Published private(set) var runningConversation: UUID?
    @Published private(set) var insertingMessage: UUID?
    @Published private var permissions: [ToolPermission] = []
    @Published private(set) var activity = ""
    @Published private(set) var skills: [HermesSkill] = []
    @Published private(set) var images: [ImagePayload] = []
    @Published private(set) var pendingImages = 0
    @Published var selectedSkill: HermesSkill?
    @Published var error: String?
    @Published var draft = ""
    @Published var workbenchDraft = ""
    @Published private(set) var loadingRunSettings = false
    @Published private var runSettingsBySession: [String: HermesRunSettings] = [:]
    @Published private var preparedRun: (context: UUID, sessionID: String)?
    @Published private var runSettingsFailure: (context: UUID, message: String)?

    let store: RoleStore
    let inputHistory = HermesInputHistory()
    private var backend: HermesRuntime?
    private var runtimeRevision = UUID()
    private var draftContext = UUID()
    private var turnControl: TurnControl?
    private var drafts: [UUID: String] = [:]
    private var imageDrafts: [UUID: [ImagePayload]] = [:]
    private var skillDrafts: [UUID: HermesSkill] = [:]
    private var draftProjects: [UUID: UUID] = [:]
    private var selectedThreads: [UUID: UUID] = [:]

    init() {
        let files = FileManager.default
        let legacy = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hermes Studio", isDirectory: true)
        let defaultRoot = files.homeDirectoryForCurrentUser.appendingPathComponent("hermesgroup", isDirectory: true)
        let migrationError: String?
        if let override = ProcessInfo.processInfo.environment["HERMES_STUDIO_DATA_DIR"], !override.isEmpty {
            store = RoleStore(root: URL(fileURLWithPath: override, isDirectory: true))
            migrationError = nil
        } else {
            let destination = RoleStore(root: defaultRoot)
            do {
                try destination.migrateDataIfNeeded(from: legacy)
                store = destination
                migrationError = nil
            } catch {
                store = RoleStore(root: legacy)
                migrationError = "迁移到 ~/hermesgroup 失败，正在使用原数据目录。\(error.localizedDescription)"
            }
        }
        do {
            roles = try store.list()
            archivedRoles = try store.archivedRoles()
            let seeded = store.root.appendingPathComponent(".default-roles-initialized")
            if roles.isEmpty && archivedRoles.isEmpty && !FileManager.default.fileExists(atPath: seeded.path) {
                for template in [RoleTemplate.general, .engineering, .writing] {
                    let role = Role(name: template.name, summary: template.description, template: template)
                    try store.create(role, instructions: template.instructions)
                    roles.append(role)
                }
            }
            if !FileManager.default.fileExists(atPath: seeded.path) {
                try Data().write(to: seeded, options: .atomic)
            }
            for role in roles {
                conversations[role.id] = try store.conversations(for: role.id)
            }
            projectsByRole = try store.projectsByRole()
        } catch {
            report(error)
        }
        refreshArchive()
        refreshRuntime()
        if let migrationError { error = migrationError }
    }

    var role: Role? { roles.first { $0.id == roleID } }
    var inputHistoryHome: URL? {
        guard projectID == nil, let source = role?.terminalSource else { return nil }
        return URL(fileURLWithPath: source, isDirectory: true)
    }
    var projects: [StudioProject] { roleID.map { projects(for: $0) } ?? [] }
    var project: StudioProject? { projects.first { $0.id == projectID } }
    var threads: [Conversation] { roleID.map { activeThreads(for: $0) } ?? [] }
    var pinnedThreads: [Conversation] {
        threads.filter { $0.pinnedAt != nil }
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
    }
    var archivedThreads: [Conversation] {
        conversations.values.flatMap { $0 }.filter { $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }
    var conversation: Conversation? { threads.first { $0.id == conversationID } }
    var isGeneratingHere: Bool { runningConversation != nil && runningConversation == conversationID }
    var activePermission: ToolPermission? { isGeneratingHere ? permissions.first : nil }
    var canSend: Bool {
        !loadingRunSettings && insertingMessage == nil && pendingImages == 0
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }
    var runSettingsContext: UUID { draftContext }
    var runSettings: HermesRunSettings? { composerSessionID.flatMap { runSettingsBySession[$0] } }
    var composerModelName: String {
        if let model = runSettings?.model { return model.name }
        if conversation?.sessionID != nil { return "会话模型" }
        return modelName.isEmpty ? "默认模型" : modelName
    }
    var runSettingsError: String? { runSettingsFailure?.context == draftContext ? runSettingsFailure?.message : nil }
    private var composerSessionID: String? {
        conversation?.sessionID ?? (preparedRun?.context == draftContext ? preparedRun?.sessionID : nil)
    }
    var availableSkills: [HermesSkill] {
        guard let allowed = role?.skillIDs else { return skills }
        return skills.filter { allowed.contains($0.id) }
    }
    var recentThreads: [Conversation] {
        conversations.values.flatMap { $0 }.filter { $0.archivedAt == nil }.sorted { $0.updated > $1.updated }
    }

    func activeThreads(for roleID: UUID) -> [Conversation] {
        conversations[roleID, default: []].filter { $0.archivedAt == nil }
    }

    func toggleConversationPin(_ thread: Conversation) {
        guard thread.id != runningConversation else { return }
        do {
            let updated = try store.setConversationPinned(thread.pinnedAt == nil, id: thread.id, for: thread.roleID)
            refreshConversationMetadata(updated)
        } catch { report(error) }
    }

    func setConversationArchived(_ thread: Conversation, archived: Bool) {
        guard thread.id != runningConversation else { return }
        do {
            let updated = try store.setConversationArchived(archived, id: thread.id, for: thread.roleID)
            refreshConversationMetadata(updated)
            if archived, selectedThreads[thread.roleID] == thread.id {
                selectedThreads.removeValue(forKey: thread.roleID)
            }
            if archived, conversationID == thread.id {
                conversationID = nil
                draftContext = UUID()
                prewarm()
            }
        } catch { report(error) }
    }

    private func refreshConversationMetadata(_ thread: Conversation) {
        error = nil
        if let index = conversations[thread.roleID]?.firstIndex(where: { $0.id == thread.id }) {
            conversations[thread.roleID]?[index] = thread
        }
    }

    func projects(for roleID: UUID) -> [StudioProject] { projectsByRole[roleID, default: []] }

    func goHome() {
        showManagement = true
        error = nil
    }

    func updateRunSettings(field: HermesRunSettings.Field? = nil, value: String? = nil) async {
        guard let role, let backend, runningConversation == nil, !loadingRunSettings else { return }
        let context = draftContext
        let revision = runtimeRevision
        let change = field.flatMap { field in value.map { (field: field, value: $0) } }
        loadingRunSettings = true
        runSettingsFailure = nil
        defer { loadingRunSettings = false }
        do {
            if projectID != nil, project == nil { throw StudioError.message("找不到当前对话的项目。") }
            let result = try await backend.runSettings(home: store.runtime(for: role.id), sessionID: composerSessionID,
                workspace: project?.directory, skillIDs: role.skillIDs, change: change)
            guard context == draftContext, revision == runtimeRevision else { return }
            if conversation?.sessionID == nil { preparedRun = (context, result.id) }
            runSettingsBySession[result.id] = result.settings
        } catch {
            guard context == draftContext, revision == runtimeRevision else { return }
            runSettingsFailure = (context, error.localizedDescription)
        }
    }

    var canRefreshRuntime: Bool { runningConversation == nil && !loadingRunSettings }

    func checkForHermesUpdates() {
        guard let backend, !checkingHermesUpdate else { return }
        let revision = runtimeRevision
        checkingHermesUpdate = true
        Task {
            let result = await backend.checkForUpdates()
            checkingHermesUpdate = false
            if runtimeRevision == revision { hermesUpdate = result }
        }
    }

    func refreshRuntime() {
        guard canRefreshRuntime else { return }
        let revision = UUID()
        runtimeRevision = revision
        let runtime = HermesRuntime.discover()
        backend = runtime
        available = runtime != nil
        modelName = ""
        hermesUpdate = nil
        guard let runtime else {
            skills = []
            terminalHome = nil
            return
        }
        prewarm()
        Task {
            let discovered = await Task.detached { (try? runtime.currentModel(), runtime.installedSkills(), runtime.terminalHome()) }.value
            if runtimeRevision == revision {
                modelName = discovered.0 ?? ""
                skills = discovered.1
                terminalHome = discovered.2
            }
        }
    }

    func select(_ role: Role) {
        draftContext = UUID()
        if let roleID {
            drafts[roleID] = draft
            imageDrafts[roleID] = images
            skillDrafts[roleID] = selectedSkill
            draftProjects[roleID] = conversationID == nil ? projectID : nil
        }
        roleID = role.id
        showManagement = false
        draft = drafts[role.id, default: ""]
        images = imageDrafts[role.id, default: []]
        selectedSkill = skillDrafts[role.id]
        error = nil
        roleFiles = [:]
        do {
            if conversations[role.id] == nil {
                conversations[role.id] = try store.conversations(for: role.id)
            }
            try reloadFiles(for: role.id)
        } catch {
            report(error)
        }
        let thread = threads.first { $0.id == selectedThreads[role.id] }
        conversationID = thread?.id
        projectID = thread == nil ? draftProjects[role.id] : thread?.projectID
        prewarm()
    }

    func select(_ conversation: Conversation) {
        guard conversation.roleID == roleID, let conversation = threads.first(where: { $0.id == conversation.id }) else { return }
        if conversationID != conversation.id { draftContext = UUID() }
        conversationID = conversation.id
        projectID = conversation.projectID
        selectedThreads[conversation.roleID] = conversation.id
        if runningConversation == nil { prewarm() }
    }

    func newConversation() {
        draftContext = UUID()
        if project == nil { projectID = nil }
        conversationID = nil
        if let roleID { selectedThreads.removeValue(forKey: roleID) }
        draft = ""
        images = []
        selectedSkill = nil
    }

    func newConversation(in project: StudioProject) {
        guard projects.contains(project) else { return }
        projectID = project.id
        newConversation()
    }

    func chooseProject(_ project: StudioProject?) {
        guard conversationID == nil else { return }
        if let project, !projects.contains(project) { return }
        if projectID != project?.id { draftContext = UUID() }
        projectID = project?.id
    }

    func startConversation(in project: StudioProject) {
        guard let role = roles.first(where: { $0.id == project.roleID }),
            projects(for: role.id).contains(project) else { return }
        select(role)
        newConversation(in: project)
    }

    func createProject(name: String, directory: URL?, for roleID: UUID) throws {
        let project = try store.createProject(name: name, directory: directory, for: roleID)
        projectsByRole[roleID, default: []].insert(project, at: 0)
    }

    @discardableResult
    func moveConversation(_ id: UUID, to project: StudioProject?) -> Bool {
        guard let roleID, threads.contains(where: { $0.id == id }) else { return false }
        if let project, !projects.contains(project) { return false }
        guard id != runningConversation else {
            error = "这条对话正在回复，结束后可以移动。"
            return false
        }
        do {
            let moved = try store.moveConversation(id, for: roleID, to: project?.id)
            refreshConversationMetadata(moved)
            if conversationID == id { projectID = moved.projectID }
            return true
        } catch {
            report(error)
            return false
        }
    }

    func suggestConversationStarters(role: Role, memory: String, user: String,
        projectName: String?) async throws -> [String] {
        guard role.terminalSource == nil, let backend else { return [] }
        return try await backend.suggestConversationStarters(role: role, memory: memory, user: user, projectName: projectName)
    }

    func complete(_ query: HermesCompletion.Query) async -> [HermesCompletion] {
        guard let backend else { return [] }
        return await backend.complete(query)
    }

    func openFolder(_ project: StudioProject) {
        if !NSWorkspace.shared.open(project.directory) {
            error = "无法打开项目目录。"
        }
    }

    func importImages(_ urls: [URL]) {
        let capacity = ImagePayload.maxCount - images.count
        guard capacity > 0, roleID != nil else {
            error = "每条消息最多附带 4 张图片。"
            return
        }
        let context = draftContext
        pendingImages += 1
        Task {
            defer { pendingImages -= 1 }
            let results = await Task.detached {
                urls.prefix(capacity).map { url in Result { try ImagePayload.load(url) } }
            }.value
            guard draftContext == context else { return }
            for result in results {
                switch result {
                case .success(let image): appendImage(image)
                case .failure(let error): report(error)
                }
            }
            if urls.count > capacity { error = "每条消息最多附带 4 张图片。" }
        }
    }

    func pasteImage() {
        if !pasteClipboardImages() { error = "剪贴板里没有可粘贴的图片。" }
    }

    func pasteClipboardImages() -> Bool {
        guard let source = ClipboardImages.read(from: .general) else { return false }
        switch source {
        case .files(let files): importImages(files)
        case .pixels(let images): appendClipboardPixels(images)
        }
        return true
    }

    private func appendClipboardPixels(_ pixels: [Data]) {
        let capacity = ImagePayload.maxCount - images.count
        guard capacity > 0 else {
            error = "每条消息最多附带 4 张图片。"
            return
        }
        let context = draftContext
        pendingImages += 1
        Task {
            defer { pendingImages -= 1 }
            let results = await Task.detached {
                pixels.prefix(capacity).map { data in Result { try ImagePayload.prepare(name: "剪贴板图片", data: data) } }
            }.value
            guard draftContext == context else { return }
            for result in results {
                do { appendImage(try result.get()) } catch { report(error) }
            }
            if pixels.count > capacity { error = "每条消息最多附带 4 张图片。" }
        }
    }

    private func appendImage(_ image: ImagePayload) {
        guard images.count < ImagePayload.maxCount else {
            error = "每条消息最多附带 4 张图片。"
            return
        }
        images.append(image)
    }

    func removeImage(_ id: UUID) { images.removeAll { $0.id == id } }

    func createRole(name: String, summary: String, instructions: String, template: RoleTemplate, skillIDs: Set<String>?,
        avatar: RoleAvatar?, avatarImage: ImagePayload?) throws {
        var role = Role(name: name, summary: summary, template: template)
        role.skillIDs = skillIDs
        role.avatar = avatarImage.map { .custom($0.image) } ?? avatar
        try store.create(role, instructions: instructions, avatarImage: avatarImage)
        roles.append(role)
    }

    func suggestRole(_ description: String) async throws -> RoleSuggestion {
        guard let backend else { throw StudioError.message("需要本机 Hermes 才能生成角色草稿。") }
        return try await HermesRuntime(executable: backend.executable).suggestRole(for: description, skills: skills)
    }

    func copyTerminalRole(from home: URL) throws -> Role {
        let role = Role(name: "终端 Hermes 副本", summary: "由终端 Hermes 的角色指令和记忆创建。", template: .blank)
        try store.createFromTerminal(role, home: home)
        roles.append(role)
        return role
    }

    func linkedTerminalRole(for home: URL) -> Role? {
        let source = home.standardizedFileURL.resolvingSymlinksInPath().path
        return roles.first { $0.terminalSource == source }
    }

    func terminalChatRole(from home: URL) throws -> Role {
        if let role = linkedTerminalRole(for: home) { return role }
        let role = try store.terminalChatRole(from: home)
        roles.append(role)
        return role
    }

    func withTerminalRole(from home: URL, perform: (Role) -> Void) {
        do { perform(try terminalChatRole(from: home)) } catch { report(error) }
    }

    func updateRole(_ role: Role) throws {
        try store.update(role)
        if let index = roles.firstIndex(where: { $0.id == role.id }) {
            let scopeChanged = roles[index].skillIDs != role.skillIDs
            roles[index] = role
            if scopeChanged {
                backend?.reset(home: store.runtime(for: role.id))
                if roleID == role.id {
                    if let selectedSkill, !availableSkills.contains(selectedSkill) { self.selectedSkill = nil }
                    prewarm()
                }
            }
        }
    }

    func togglePin(_ role: Role) {
        var updated = role
        updated.pinned = role.pinned != true
        do { try updateRole(updated) } catch { report(error) }
    }

    func archiveRole(_ role: Role) {
        do {
            guard !(conversations[role.id] ?? []).contains(where: { $0.id == runningConversation }) else {
                throw StudioError.message("这个角色正在回复，结束后可移入草稿箱。")
            }
            _ = try store.archive(role.id)
            backend?.reset(home: store.runtime(for: role.id))
            roles.removeAll { $0.id == role.id }
            conversations.removeValue(forKey: role.id)
            selectedThreads.removeValue(forKey: role.id)
            if roleID == role.id { goHome() }
            refreshArchive()
        } catch { report(error) }
    }

    func restoreRole(_ id: UUID) throws {
        let threads = try store.conversations(for: id)
        let role = try store.restore(id)
        if !roles.contains(where: { $0.id == id }) { roles.append(role) }
        conversations[id] = threads
        archivedRoles.removeAll { $0.id == id }
    }

    func deleteArchivedRole(_ id: UUID) throws {
        try store.trashArchivedRole(id)
        archivedRoles.removeAll { $0.id == id }
    }

    func refreshArchive() {
        do {
            try store.purgeExpiredRoles()
            archivedRoles = try store.archivedRoles()
        } catch { report(error) }
    }

    func save(_ file: RoleFile, text: String, role: Role) throws {
        guard !(conversations[role.id] ?? []).contains(where: { $0.id == runningConversation }) else {
            throw StudioError.message("这个角色正在回复，结束后可以保存。")
        }
        try store.writeFile(file, for: role.id, text: text)
        backend?.reset(home: store.runtime(for: role.id))
        if role.id == roleID {
            try reloadFiles(for: role.id)
            prewarm()
        }
    }

    func openData() {
        NSWorkspace.shared.open(roleID.map { store.runtime(for: $0).deletingLastPathComponent() } ?? store.root)
    }

    func stop() {
        activity = "正在停止"
        turnControl?.cancel()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, roleID != nil else { return }
        guard backend != nil else {
            error = "找不到本机 Hermes。安装后，在窗口底部重新检测。"
            return
        }
        if runningConversation != nil {
            guard isGeneratingHere else {
                error = "另一条对话正在回复，等它结束后再发。"
                return
            }
            guard images.isEmpty, selectedSkill == nil, !text.hasPrefix("/") else {
                error = "执行中仅可插入普通文字。图片、技能或命令已留在输入框。"
                return
            }
            let id = UUID()
            guard turnControl?.insert(id: id, text: text) == true else {
                error = "Hermes 还未准备好接收补充，消息仍在输入框。"
                return
            }
            insertingMessage = id
            error = nil
            return
        }
        deliver(text: text, images: images, skill: selectedSkill)
    }

    func respond(to permission: ToolPermission, option: String?) {
        guard isGeneratingHere else { return }
        if turnControl?.respond(to: permission.id, optionID: option) != true {
            error = "这条审核请求已失效。"
        }
        permissions.removeAll { $0.id == permission.id }
    }

    @discardableResult
    private func deliver(text: String, images attachments: [ImagePayload], skill selectedSkill: HermesSkill?) -> Bool {
        guard let targetRoleID = roleID, let backend else { return false }
        let workspace = project?.directory
        if projectID != nil, workspace == nil {
            error = "找不到此助手的项目。可以先将对话移回对话记录。"
            return false
        }
        if let workspace, (try? workspace.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            error = "项目目录已移动或不可访问。"
            return false
        }
        var thread = conversation ?? Conversation(roleID: targetRoleID)
        thread.projectID = projectID
        thread.sessionID = composerSessionID
        if thread.messages.isEmpty {
            thread.title = String(text.split(whereSeparator: \.isNewline).first?.prefix(32) ?? "图片消息")
        }
        let allowedSkills = roles.first(where: { $0.id == targetRoleID })?.skillIDs
        let skillPool = allowedSkills.map { allowed in skills.filter { allowed.contains($0.id) } } ?? skills
        let skill = selectedSkill.flatMap { skillPool.contains($0) ? $0 : nil }
        thread.updated = Date()
        do {
            var message = Message(.user, text)
            if !attachments.isEmpty { message.images = try attachments.map { try store.saveImage($0, for: targetRoleID) } }
            message.skill = skill?.name
            thread.messages.append(message)
            try store.save(thread)
        } catch {
            report(error)
            return false
        }
        let requestIndex = thread.messages.count - 1
        let start = ContinuousClock.now
        publish(thread)
        runningConversation = thread.id
        select(thread)
        draft = ""
        images = []
        self.selectedSkill = nil
        error = nil
        activity = "正在提交消息"
        let control = TurnControl()
        turnControl = control
        let events = backend.turn(home: store.runtime(for: targetRoleID), conversation: thread, text: text,
            images: attachments, skill: skill, workspace: workspace, skillIDs: allowedSkills, interactive: true, control: control)
        Task {
            for await event in events {
                switch event {
                case .session(let id):
                    thread.sessionID = id
                    persist(thread)
                case .runSettings(let settings):
                    if let id = thread.sessionID { runSettingsBySession[id] = settings }
                case .text(let text, let id):
                    activity = "正在回复"
                    if let last = thread.messages.indices.last,
                        thread.messages[last].author == .assistant, thread.messages[last].remoteID == id {
                        thread.messages[last].text += text
                    } else {
                        thread.messages.append(Message(.assistant, text, remoteID: id))
                    }
                    publish(thread)
                case .image(let image):
                    do {
                        var message = Message(.assistant, "")
                        message.images = [try store.saveImage(image, for: targetRoleID)]
                        thread.messages.append(message)
                        publish(thread)
                    } catch { report(error) }
                case .tool(let update):
                    if let index = thread.messages.indices.reversed().first(where: {
                        $0 > requestIndex && thread.messages[$0].tool?.id == update.id
                    }) {
                        thread.messages[index].tool = thread.messages[index].tool?.updating(with: update)
                    } else {
                        var message = Message(.tool, "")
                        message.tool = update
                        thread.messages.append(message)
                    }
                    publish(thread)
                case .permission(let permission):
                    permissions.append(permission)
                case .permissionExpired(let toolID):
                    permissions.removeAll { $0.toolID == toolID }
                case .followUpReady, .followUpStarted, .followUpRejected:
                    break
                case .insertionAccepted(let id, let text):
                    guard id == insertingMessage else { continue }
                    var message = Message(.user, text)
                    message.id = id
                    message.isGuidance = true
                    thread.messages.append(message)
                    if self.roleID == targetRoleID, draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                        draft = ""
                    }
                    if drafts[targetRoleID]?.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                        drafts[targetRoleID] = nil
                    }
                    insertingMessage = nil
                    publish(thread)
                    persist(thread)
                case .insertionFailed(let id, let reason):
                    guard id == insertingMessage else { continue }
                    insertingMessage = nil
                    if self.conversationID == thread.id { error = reason }
                case .activity(let title):
                    activity = title
                case .finished(let reason):
                    if reason == "cancelled" {
                        if self.conversationID == thread.id { error = "回复已停止。" }
                    } else if !thread.messages.dropFirst(requestIndex + 1).contains(where: { $0.author == .assistant }) {
                        error = "Hermes 结束了本轮对话，但没有返回内容。请检查模型配置或再发一条消息。"
                    }
                case .failed(let message):
                    error = message
                }
            }
            finishRequest(in: &thread, at: requestIndex, started: start)
            publish(thread)
            persist(thread)
            runningConversation = nil
            turnControl = nil
            if insertingMessage != nil, self.conversationID == thread.id {
                error = "当前回合已结束，未收到插入确认，消息仍在输入框。"
            }
            insertingMessage = nil
            permissions.removeAll()
            activity = ""
            if self.roleID == targetRoleID {
                do { try reloadFiles(for: targetRoleID) } catch { report(error) }
            }
        }
        return true
    }

    private func finishRequest(in thread: inout Conversation, at requestIndex: Int, started: ContinuousClock.Instant) {
        for index in thread.messages.indices.dropFirst(requestIndex + 1) {
            guard let tool = thread.messages[index].tool, tool.isRunning else { continue }
            thread.messages[index].tool = tool.updating(with: ToolRun(id: tool.id, title: nil, status: "cancelled", details: nil))
        }
        thread.messages[requestIndex].workDuration = Double(started.duration(to: .now).components.seconds)
    }

    private func prewarm() {
        guard !showManagement, let role else { return }
        guard projectID == nil || project != nil else { return }
        let revision = runtimeRevision
        backend?.warm(home: store.runtime(for: role.id), conversation: conversation, workspace: project?.directory,
            skillIDs: role.skillIDs) { [weak self] id, settings in
                Task { @MainActor in
                    guard let self, self.runtimeRevision == revision, self.runSettingsBySession[id] == nil else { return }
                    self.runSettingsBySession[id] = settings
                }
            }
    }

    private func reloadFiles(for roleID: UUID) throws {
        roleFiles = try Dictionary(uniqueKeysWithValues: RoleFile.allCases.map {
            ($0, try store.file($0, for: roleID))
        })
    }

    private func publish(_ thread: Conversation) {
        var threads = conversations[thread.roleID, default: []]
        threads.removeAll { $0.id == thread.id }
        threads.insert(thread, at: 0)
        conversations[thread.roleID] = threads
    }

    private func persist(_ thread: Conversation) {
        do { try store.save(thread) } catch { report(error) }
    }

    private func report(_ error: Error) { self.error = error.localizedDescription }
}
