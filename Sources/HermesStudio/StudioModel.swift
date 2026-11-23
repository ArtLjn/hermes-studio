import AppKit
import StudioCore
import SwiftUI

struct RoleHandoffReview: Identifiable {
    let id: UUID
    let origin: RoleHandoffOrigin
    let target: Role
    let text: String
    let isQuestion: Bool
}

struct ConsultationContextReview: Identifiable {
    let id: UUID
    let target: Role
    let entries: [RoleConsultation.ContextEntry]
    let selectedIDs: Set<UUID>
}

enum RoleCollaborationMode: CaseIterable, Identifiable {
    case question, preparedQuestion, handoff

    var id: Self { self }
    var label: String {
        switch self {
        case .handoff: "交接工作"
        case .question: "直接提问"
        case .preparedQuestion: "让当前助手拟问题"
        }
    }
}

@MainActor
final class StudioModel: ObservableObject {
    struct QueuedMessage: Identifiable {
        let id = UUID()
        let text: String
        let images: [ImagePayload]
        let skill: HermesSkill?

        var canInsert: Bool { !text.isEmpty && !text.hasPrefix("/") && images.isEmpty && skill == nil }
    }

    private enum ComposerScope: Hashable {
        case conversation(UUID)
        case new(role: UUID, project: UUID?)
    }

    private struct ComposerDraft {
        var text = ""
        var images: [ImagePayload] = []
        var skill: HermesSkill?
        var handoffTargetID: UUID?
        var collaborationMode: RoleCollaborationMode = .question
        var sharedContext: ConsultationShare?
    }

    private struct ConsultationShare {
        let targetID: UUID
        let entries: [RoleConsultation.ContextEntry]
    }

    private struct RunningTurn {
        let control: TurnControl
        let approval: HermesApprovalMode?
        let preparingHandoff: Bool
        var activity = "正在提交消息"
        var stopping = false
        var insertion: UUID?
        var permissions: [ToolPermission] = []
        var consultationID: UUID?
        var consultationText = ""
        var recallingGroup = false
    }

    @Published private(set) var roles: [Role] = []
    @Published private(set) var libraryGroups: [String] = []
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
    @Published private var runningTurns: [UUID: RunningTurn] = [:]
    @Published private var replyQueues: [UUID: [QueuedMessage]] = [:]
    @Published private var pausedQueues: Set<UUID> = []
    @Published private var conversationErrors: [UUID: String] = [:]
    @Published private(set) var skills: [HermesSkill] = []
    @Published private(set) var images: [ImagePayload] = []
    @Published private var imageImports: [UUID: Int] = [:]
    @Published var selectedSkill: HermesSkill?
    @Published var selectedHandoffTargetID: UUID?
    @Published var collaborationMode: RoleCollaborationMode = .question
    @Published private var consultationShare: ConsultationShare?
    @Published var error: String?
    @Published var draft = ""
    @Published var workbenchDraft = ""
    @Published private var loadingSettingsContexts: Set<UUID> = []
    @Published private(set) var runPreferences: HermesRunPreferences
    @Published private var runSettingsBySession: [String: HermesRunSettings] = [:]
    @Published private var preparedSessions: [UUID: String] = [:]
    @Published private var runSettingsFailures: [UUID: String] = [:]

    let store: RoleStore
    let mcp: MCPManagement
    let groupWorkspace: GroupWorkspaceModel
    let inputHistory = HermesInputHistory()
    private let groupRecallStore = RoleStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("hermes-studio-group-recall-\(UUID())", isDirectory: true))
    private var backend: HermesRuntime?
    private var runtimeRevision = UUID()
    private var draftContext = UUID()
    private var composerContexts: [ComposerScope: UUID] = [:]
    private var drafts: [ComposerScope: ComposerDraft] = [:]
    private var approvalChangeInProgress = false
    private var terminating = false
    private var draftProjects: [UUID: UUID] = [:]
    private var selectedThreads: [UUID: UUID] = [:]

    deinit { try? FileManager.default.removeItem(at: groupRecallStore.root) }

    func prepareForTermination() {
        terminating = true
        groupWorkspace.prepareForTermination()
        for turn in runningTurns.values { turn.control.cancel() }
    }

    init(dataStore: RoleStore? = nil, runtime: HermesRuntime? = nil,
        runPreferences: HermesRunPreferences = .load()) {
        self.runPreferences = runPreferences
        let files = FileManager.default
        let legacy = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hermes Studio", isDirectory: true)
        let defaultRoot = files.homeDirectoryForCurrentUser.appendingPathComponent("hermesgroup", isDirectory: true)
        let migrationError: String?
        if let dataStore {
            store = dataStore
            migrationError = nil
        } else if let override = ProcessInfo.processInfo.environment["HERMES_STUDIO_DATA_DIR"], !override.isEmpty {
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
        let management = MCPManagement(root: store.root)
        mcp = management
        groupWorkspace = GroupWorkspaceModel(roleStore: store, fullAccess: runPreferences.enablesGroupFullAccess,
            roleConnections: { management.configuredConnections(for: $0) })
        do {
            roles = try store.list()
            archivedRoles = try store.archivedRoles()
            libraryGroups = try store.libraryGroups()
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
        refreshRuntime(runtime)
        if let migrationError { error = migrationError }
    }

    var role: Role? { roles.first { $0.id == roleID } }
    var groupRuntime: HermesRuntime? { backend }
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
    private var currentTurn: RunningTurn? { conversationID.flatMap { runningTurns[$0] } }
    func isGenerating(_ id: UUID) -> Bool { runningTurns[id] != nil }
    var isGeneratingHere: Bool { currentTurn != nil }
    var isPreparingHandoff: Bool { currentTurn?.preparingHandoff == true }
    var isConsultingHere: Bool { currentTurn?.consultationID != nil }
    var isStoppingHere: Bool { currentTurn?.stopping == true }
    var activePermission: ToolPermission? { isStoppingHere ? nil : currentTurn?.permissions.first }
    var insertingMessage: UUID? { currentTurn?.insertion }
    var queuedMessages: [QueuedMessage] { conversationID.flatMap { replyQueues[$0] } ?? [] }
    var isReplyQueuePaused: Bool { conversationID.map { pausedQueues.contains($0) } ?? false }
    var canInsertQueuedMessage: Bool {
        guard let turn = currentTurn else { return false }
        return queuedMessages.first?.canInsert == true && !turn.stopping && turn.insertion == nil
            && !turn.preparingHandoff && turn.consultationID == nil && !turn.recallingGroup
    }
    var activity: String? { currentTurn?.activity }
    var pendingImages: Int { imageImports[draftContext, default: 0] }
    var loadingRunSettings: Bool { loadingSettingsContexts.contains(draftContext) }
    var chatError: String? { error ?? conversationID.flatMap { conversationErrors[$0] } }
    private var interruptedTurn: ChatTurn? {
        guard let conversation, !isGeneratingHere, let turn = ChatTurn.collect(conversation.messages).last,
            turn.canContinue else { return nil }
        return turn
    }
    var canContinueReply: Bool {
        backend != nil && !loadingRunSettings && pendingImages == 0 && selectedHandoffTargetID == nil
            && selectedSkill == nil && images.isEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && interruptedTurn != nil
    }
    var canSend: Bool {
        !terminating && !isStoppingHere && (!isGeneratingHere && queuedMessages.isEmpty || selectedHandoffTargetID == nil)
            && !loadingRunSettings && pendingImages == 0
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
                || (!isGeneratingHere && selectedHandoffTargetID == nil
                    && selectedSkill.map { availableSkills.contains($0) } == true)
                || (selectedHandoffTargetID != nil && collaborationMode != .question && conversation?.sessionID != nil))
    }
    var runSettingsContext: UUID { draftContext }
    var runSettings: HermesRunSettings? { composerSessionID.flatMap { runSettingsBySession[$0] } }
    var composerApprovalMode: HermesApprovalMode? {
        let native = runSettings?.editApproval.flatMap { HermesApprovalMode(nativeID: $0.value) }
        if let currentTurn { return currentTurn.approval ?? native }
        return runPreferences.approval ?? native
    }
    var composerEffort: String? {
        runSettings?.effort?.value ?? (conversation?.sessionID == nil ? runPreferences.effort : nil)
    }
    var composerModelName: String {
        if let model = runSettings?.model { return model.name }
        if conversation?.sessionID != nil { return "会话模型" }
        if let preferred = runPreferences.modelName { return preferred }
        return modelName.isEmpty ? "默认模型" : modelName
    }
    var runSettingsError: String? { runSettingsFailures[draftContext] }
    private var composerSessionID: String? {
        conversation?.sessionID ?? preparedSessions[draftContext]
    }
    private var composerScope: ComposerScope? {
        if let conversationID { return .conversation(conversationID) }
        return roleID.map { .new(role: $0, project: projectID) }
    }

    func dismissChatError() {
        if error != nil { error = nil }
        else if let conversationID { conversationErrors[conversationID] = nil }
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
            .sorted { $0.updated > $1.updated }
    }

    func toggleConversationPin(_ thread: Conversation) {
        guard !isGenerating(thread.id) else { return }
        do {
            let updated = try store.setConversationPinned(thread.pinnedAt == nil, id: thread.id, for: thread.roleID)
            refreshConversationMetadata(updated)
        } catch { report(error) }
    }

    func setConversationArchived(_ thread: Conversation, archived: Bool) {
        guard !isGenerating(thread.id) else { return }
        do {
            let updated = try store.setConversationArchived(archived, id: thread.id, for: thread.roleID)
            refreshConversationMetadata(updated)
            if archived, selectedThreads[thread.roleID] == thread.id {
                selectedThreads.removeValue(forKey: thread.roleID)
            }
            if archived, conversationID == thread.id {
                let previous = composerScope
                conversationID = nil
                switchComposer(from: previous)
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

    func updateRunSettings(field: HermesRunSettings.Field? = nil, value: String? = nil,
        approval: HermesApprovalMode? = nil, includeModelChoices: Bool = false) async {
        guard let role, let backend, !isGeneratingHere, !loadingRunSettings else { return }
        guard approval == nil || !approvalChangeInProgress else { return }
        let context = draftContext
        let revision = runtimeRevision
        let newConversation = conversation?.sessionID == nil
        let change = field.flatMap { field in value.map { (field: field, value: $0) } }
        let previous = runPreferences
        var preferences = previous
        loadingSettingsContexts.insert(context)
        if approval != nil { approvalChangeInProgress = true }
        runSettingsFailures[context] = nil
        defer {
            loadingSettingsContexts.remove(context)
            if approval != nil { approvalChangeInProgress = false }
        }
        do {
            if projectID != nil, project == nil { throw StudioError.message("找不到当前对话的项目。") }
            if let approval {
                preferences.selectApproval(approval)
                if approval == .fullAccess, !previous.managesTerminalApproval {
                    // 先记录需要管理终端状态，连接中断后也能在下次发送前撤销未确认的授权。
                    var pending = previous
                    pending.startManagingTerminalApproval()
                    rememberRunPreferences(pending)
                } else if approval != .fullAccess, previous.managesTerminalApproval {
                    rememberRunPreferences(preferences)
                }
            }
            let result = try await backend.runSettings(home: store.runtime(for: role.id), sessionID: composerSessionID,
                workspace: project?.directory, skillIDs: role.skillIDs, mcpServers: mcp.connections(for: role.id),
                preferences: preferences, useModelDefaults: newConversation, change: change, includeModelChoices: includeModelChoices)
            var updatedDefaults = runPreferences
            if let approval { updatedDefaults.selectApproval(approval) }
            if let change, let selection = result.settings?[change.field] {
                switch change.field {
                case .model:
                    updatedDefaults.modelID = selection.value
                    updatedDefaults.modelName = selection.name
                case .effort:
                    updatedDefaults.effort = change.value
                case .editApproval: break
                }
            }
            if approval != nil || change != nil { rememberRunPreferences(updatedDefaults) }
            guard revision == runtimeRevision, composerContexts.values.contains(context) else { return }
            if newConversation { preparedSessions[context] = result.id }
            runSettingsBySession[result.id] = result.settings
        } catch {
            if approval == .fullAccess, !previous.managesTerminalApproval,
                case .unsupported? = error as? HermesTerminalApprovalError {
                var restored = previous
                restored.modelID = runPreferences.modelID
                restored.modelName = runPreferences.modelName
                restored.effort = runPreferences.effort
                rememberRunPreferences(restored)
            }
            guard revision == runtimeRevision, composerContexts.values.contains(context) else { return }
            runSettingsFailures[context] = error.localizedDescription
        }
    }

    private func rememberRunPreferences(_ preferences: HermesRunPreferences) {
        runPreferences = preferences
        groupWorkspace.fullAccess = preferences.enablesGroupFullAccess
        preferences.save()
    }

    func setGroupFullAccess(_ enabled: Bool) {
        var preferences = runPreferences
        preferences.groupFullAccess = enabled
        rememberRunPreferences(preferences)
    }

    var canRefreshRuntime: Bool { runningTurns.isEmpty && loadingSettingsContexts.isEmpty }

    func testMCP(_ server: MCPServer) async {
        await mcp.test(server, runtime: backend)
    }

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

    func refreshRuntime(_ providedRuntime: HermesRuntime? = nil) {
        guard canRefreshRuntime else { return }
        let revision = UUID()
        runtimeRevision = revision
        preparedSessions.removeAll()
        runSettingsFailures.removeAll()
        runSettingsBySession.removeAll()
        let runtime = providedRuntime ?? HermesRuntime.discover()
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
        let previous = composerScope
        if let roleID, roleID != role.id {
            draftProjects[roleID] = conversationID == nil ? projectID : nil
        }
        roleID = role.id
        showManagement = false
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
        projectID = thread == nil ? draftProjects[role.id].flatMap { id in
            projects.contains { $0.id == id } ? id : nil
        } : thread?.projectID
        switchComposer(from: previous)
        prewarm()
    }

    func select(_ conversation: Conversation) {
        guard conversation.roleID == roleID, let conversation = threads.first(where: { $0.id == conversation.id }) else { return }
        let previous = composerScope
        conversationID = conversation.id
        projectID = conversation.projectID
        selectedThreads[conversation.roleID] = conversation.id
        switchComposer(from: previous)
        if !isGeneratingHere { prewarm() }
    }

    func newConversation() {
        showNewConversation(projectID: project?.id)
    }

    private func showNewConversation(projectID: UUID?) {
        let previous = composerScope
        self.projectID = projectID
        conversationID = nil
        if let roleID {
            selectedThreads[roleID] = nil
            draftProjects[roleID] = projectID
        }
        if let scope = composerScope, scope == previous {
            clearComposer(scope)
            draftContext = context(for: scope)
            restoreDraft(ComposerDraft())
            error = nil
        } else {
            switchComposer(from: previous)
        }
    }

    func newConversation(in project: StudioProject) {
        guard projects.contains(project) else { return }
        showNewConversation(projectID: project.id)
    }

    func chooseProject(_ project: StudioProject?) {
        guard conversationID == nil else { return }
        if let project, !projects.contains(project) { return }
        guard let previous = composerScope, projectID != project?.id else { return }
        let input = currentDraft
        clearComposer(previous)
        projectID = project?.id
        if let roleID { draftProjects[roleID] = projectID }
        if let scope = composerScope {
            draftContext = context(for: scope)
            restoreDraft(input.text.isEmpty && input.images.isEmpty && input.skill == nil && input.handoffTargetID == nil
                ? drafts[scope, default: ComposerDraft()] : input)
        }
        error = nil
    }

    private var currentDraft: ComposerDraft {
        ComposerDraft(text: draft, images: images, skill: selectedSkill, handoffTargetID: selectedHandoffTargetID,
            collaborationMode: collaborationMode, sharedContext: consultationShare)
    }

    private func context(for scope: ComposerScope) -> UUID {
        if let context = composerContexts[scope] { return context }
        let context = UUID()
        composerContexts[scope] = context
        return context
    }

    private func clearComposer(_ scope: ComposerScope) {
        drafts[scope] = nil
        if let context = composerContexts.removeValue(forKey: scope) {
            preparedSessions[context] = nil
            runSettingsFailures[context] = nil
        }
    }

    private func restoreDraft(_ value: ComposerDraft) {
        draft = value.text
        images = value.images
        selectedSkill = value.skill
        selectedHandoffTargetID = value.handoffTargetID
        collaborationMode = value.collaborationMode
        consultationShare = value.sharedContext
    }

    private func switchComposer(from previous: ComposerScope?) {
        guard let scope = composerScope, scope != previous else { return }
        if let previous { drafts[previous] = currentDraft }
        draftContext = context(for: scope)
        restoreDraft(drafts[scope, default: ComposerDraft()])
        error = nil
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
    func removeProject(_ project: StudioProject) -> Bool {
        let roleID = project.roleID
        let affected = conversations[roleID, default: []].filter { $0.projectID == project.id }
        guard !affected.contains(where: { isGenerating($0.id) }) else {
            error = "项目中还有对话正在回复，结束后可以删除。"
            return false
        }
        do {
            let saved = try store.removeProject(project.id, for: roleID)
            let affectedIDs = Set(affected.map(\.id))
            for thread in saved where affectedIDs.contains(thread.id) { publish(thread) }
            projectsByRole[roleID]?.removeAll { $0.id == project.id }
            if draftProjects[roleID] == project.id { draftProjects[roleID] = nil }
            if self.roleID == roleID, projectID == project.id {
                if conversationID == nil { chooseProject(nil) }
                else { projectID = nil; prewarm() }
            }
            clearComposer(.new(role: roleID, project: project.id))
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func moveConversation(_ id: UUID, to project: StudioProject?) -> Bool {
        guard let roleID, threads.contains(where: { $0.id == id }) else { return false }
        if let project, !projects.contains(project) { return false }
        guard !isGenerating(id) else {
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
        guard capacity > 0, let scope = composerScope else {
            error = "每条消息最多附带 4 张图片。"
            return
        }
        let context = draftContext
        imageImports[context, default: 0] += 1
        Task {
            let results = await Task.detached {
                urls.prefix(capacity).map { url in Result { try ImagePayload.load(url) } }
            }.value
            finishImageImport(results, scope: scope, context: context, excess: urls.count > capacity)
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
        guard capacity > 0, let scope = composerScope else {
            error = "每条消息最多附带 4 张图片。"
            return
        }
        let context = draftContext
        imageImports[context, default: 0] += 1
        Task {
            let results = await Task.detached {
                pixels.prefix(capacity).map { data in Result { try ImagePayload.prepare(name: "剪贴板图片", data: data) } }
            }.value
            finishImageImport(results, scope: scope, context: context, excess: pixels.count > capacity)
        }
    }

    private func finishImageImport(_ results: [Result<ImagePayload, Error>], scope: ComposerScope,
        context: UUID, excess: Bool) {
        let remaining = imageImports[context, default: 1] - 1
        imageImports[context] = remaining > 0 ? remaining : nil
        guard composerContexts[scope] == context else { return }
        let visible = draftContext == context
        var value = visible ? currentDraft : drafts[scope, default: ComposerDraft()]
        var failure = excess ? "每条消息最多附带 4 张图片。" : nil
        for result in results {
            switch result {
            case .success(let image) where value.images.count < ImagePayload.maxCount: value.images.append(image)
            case .success: failure = "每条消息最多附带 4 张图片。"
            case .failure(let error): failure = error.localizedDescription
            }
        }
        if visible {
            images = value.images
            if let failure { error = failure }
        } else {
            drafts[scope] = value
            if let failure, case .conversation(let id) = scope { conversationErrors[id] = failure }
        }
    }

    func removeImage(_ id: UUID) { images.removeAll { $0.id == id } }

    func createRole(name: String, summary: String, instructions: String, template: RoleTemplate, skillIDs: Set<String>?,
        avatar: RoleAvatar?, avatarImage: ImagePayload?, libraryGroup: String? = nil) throws {
        var role = Role(name: name, summary: summary, template: template)
        role.skillIDs = skillIDs
        role.avatar = avatarImage.map { .custom($0.image) } ?? avatar
        role.libraryGroup = libraryGroup
        let saved = try store.create(role, instructions: instructions, avatarImage: avatarImage)
        roles.append(saved)
        if saved.libraryGroup != nil { libraryGroups = try store.libraryGroups() }
    }

    func suggestRole(_ description: String, matchAvatar: Bool, referenceLibrary: Bool, group: String?,
        selectedReferences: Set<UUID>) async throws -> RoleSuggestion {
        guard let backend else { throw StudioError.message("需要本机 Hermes 才能生成角色草稿。") }
        let references = referenceLibrary ? try store.draftReferences(for: description, group: group, selected: selectedReferences) : []
        return try await HermesRuntime(executable: backend.executable)
            .suggestRole(for: description, skills: skills, matchAvatar: matchAvatar, references: references)
    }

    func suggestRoleUpdate(_ request: String, for role: Role, matchAvatar: Bool, currentInstructions: String,
        referenceLibrary: Bool, selectedReferences: Set<UUID>) async throws -> RoleProfileSuggestion {
        guard let backend else { throw StudioError.message("需要本机 Hermes 才能更新角色资料。") }
        let references = referenceLibrary ? try store.draftReferences(for: request, excluding: role.id, group: role.libraryGroup,
            selected: selectedReferences) : []
        return try await HermesRuntime(executable: backend.executable)
            .suggestRoleUpdate(for: role, request: request, skills: skills, matchAvatar: matchAvatar,
                currentInstructions: currentInstructions, references: references)
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

    func updateRole(_ role: Role, instructions: String? = nil, changeLibraryGroup: Bool = false) throws {
        if instructions != nil { try checkRoleFilesEditable(role) }
        let role = try store.update(role, instructions: instructions, changeLibraryGroup: changeLibraryGroup)
        if changeLibraryGroup { libraryGroups = try store.libraryGroups() }
        if let index = roles.firstIndex(where: { $0.id == role.id }) {
            let scopeChanged = roles[index].skillIDs != role.skillIDs
            roles[index] = role
            if scopeChanged || instructions != nil {
                backend?.reset(home: store.runtime(for: role.id))
                if roleID == role.id {
                    if let instructions { roleFiles[.soul] = instructions }
                    if let selectedSkill, !availableSkills.contains(selectedSkill) { self.selectedSkill = nil }
                    prewarm()
                }
            }
        }
    }

    func libraryGroup(named input: String) throws -> String? {
        guard let name = try store.libraryGroupName(input) else { return nil }
        return libraryGroups.first { $0.localizedCaseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    func createLibraryGroup(_ name: String) throws -> String {
        guard let name = try store.libraryGroupName(name) else { throw StudioError.message("请输入分组名。") }
        guard !libraryGroups.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw StudioError.message("「\(name)」分组已存在。")
        }
        let group = try store.createLibraryGroup(name)
        libraryGroups = try store.libraryGroups()
        return group
    }

    @discardableResult
    func dissolveLibraryGroup(_ name: String) -> Bool {
        do {
            try store.dissolveLibraryGroup(name)
            let latest = try store.list()
            let archived = try store.archivedRoles()
            libraryGroups = try store.libraryGroups()
            roles = latest
            archivedRoles = archived
            return true
        } catch { report(error); return false }
    }

    @discardableResult
    func reorderLibraryGroup(_ name: String, to target: String) -> Bool {
        do {
            guard try store.reorderLibraryGroup(name, to: target) else { return false }
            libraryGroups = try store.libraryGroups()
            return true
        } catch { report(error); return false }
    }

    @discardableResult
    func moveRole(_ id: UUID, to group: String?) -> Bool {
        guard let index = roles.firstIndex(where: { $0.id == id }) else { return false }
        do {
            guard let role = try store.moveRoleToLibraryGroup(id, to: group) else { return false }
            roles[index] = role
            return true
        } catch { report(error); return false }
    }

    func togglePin(_ role: Role) {
        var updated = role
        updated.pinned = role.pinned != true
        do { try updateRole(updated) } catch { report(error) }
    }

    func archiveRole(_ role: Role) {
        do {
            guard !conversations[role.id, default: []].contains(where: { isGenerating($0.id) }) else {
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
        try checkRoleFilesEditable(role)
        try store.writeFile(file, for: role.id, text: text)
        backend?.reset(home: store.runtime(for: role.id))
        if role.id == roleID {
            try reloadFiles(for: role.id)
            prewarm()
        }
    }

    private func checkRoleFilesEditable(_ role: Role) throws {
        guard !conversations[role.id, default: []].contains(where: { isGenerating($0.id) }) else {
            throw StudioError.message("这个角色正在回复，结束后可以保存。")
        }
    }

    func openData() {
        NSWorkspace.shared.open(roleID.map { store.runtime(for: $0).deletingLastPathComponent() } ?? store.root)
    }

    func stop() {
        guard let id = conversationID, let turn = runningTurns[id], !turn.stopping else { return }
        pauseQueue(id)
        runningTurns[id]?.stopping = true
        runningTurns[id]?.activity = ""
        turn.control.cancel()
    }

    func continueReply() {
        guard canContinueReply, let backend, var thread = conversation,
            let request = interruptedTurn?.request,
            let requestIndex = thread.messages.firstIndex(where: { $0.id == request.id }),
            validateWorkspace() else { return }
        let sourceIndex = request.continuationOf.flatMap { id in thread.messages.firstIndex { $0.id == id } } ?? requestIndex
        let source = thread.messages[sourceIndex]
        do {
            let attachments = try (source.images ?? []).map { image in
                try ImagePayload.prepare(name: image.name, data: Data(contentsOf: store.imageURL(image, for: thread.roleID)))
            }
            let skill = availableSkills.first { $0.name == source.skill }
            var context = thread
            context.messages = Array(thread.messages.prefix(sourceIndex))
            let input = requestInput(source.text, in: context, hasImages: !attachments.isEmpty, skill: skill,
                workspace: project?.directory)
            thread.messages[requestIndex].usedGroupRecall = input.recallsGroup ? true : nil
            error = nil
            startTurn(in: thread, backend: backend, text: input.prompt,
                images: attachments, skill: skill, workspace: project?.directory, skillIDs: role?.skillIDs,
                allowGroupLookup: input.allowGroupLookup, retrying: requestIndex)
        } catch { report(error) }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, roleID != nil else { return }
        guard let backend else {
            error = "找不到本机 Hermes。安装后，在窗口底部重新检测。"
            return
        }
        if let targetID = selectedHandoffTargetID {
            guard !isGeneratingHere else {
                error = "请等当前任务结束，再向其他助手发起协作。"
                return
            }
            guard let target = roles.first(where: { $0.id == targetID && $0.id != roleID }) else {
                error = "接收助手已不可用，请重新选择。"
                return
            }
            if collaborationMode == .question {
                guard !text.isEmpty, images.isEmpty, selectedSkill == nil else {
                    error = "直接提问需要文字。请先移除图片和技能，或让当前助手根据材料拟问题。"
                    return
                }
                submitConsultation(question: text, to: target, backend: backend, context: sharedConsultationContext)
            } else {
                let isQuestion = collaborationMode == .preparedQuestion
                let task = text.isEmpty
                    ? (isQuestion ? "针对当前任务需要外部意见的事项拟一个问题。" : "交接当前对话的任务与进展。") : text
                deliver(text: task, images: images, skill: selectedSkill,
                    handoff: RoleHandoff(target: target, isQuestion: isQuestion))
            }
            return
        }
        if let thread = conversation, isGeneratingHere || !queuedMessages.isEmpty {
            guard queuedMessages.count < 20 else {
                error = "待发队列最多保留 20 条消息，当前草稿已保留。"
                return
            }
            let message = QueuedMessage(text: text, images: images, skill: selectedSkill)
            replyQueues[thread.id, default: []].append(message)
            restoreDraft(ComposerDraft())
            error = nil
            sendNextQueuedMessage(in: thread)
            return
        }
        deliver(text: text, images: images, skill: selectedSkill)
    }

    func removeQueuedMessage(_ id: UUID) {
        guard let threadID = conversationID, insertingMessage != id else { return }
        removeQueuedMessage(id, from: threadID)
    }

    func insertQueuedMessage() {
        guard canInsertQueuedMessage, let threadID = conversationID, let turn = currentTurn,
            let message = queuedMessages.first else { return }
        guard turn.control.insert(id: message.id, text: message.text) else {
            error = "当前回合暂时无法接收补充，消息仍在队列中。"
            return
        }
        runningTurns[threadID]?.insertion = message.id
        error = nil
    }

    func resumeReplyQueue() {
        guard let thread = conversation else { return }
        pausedQueues.remove(thread.id)
        error = nil
        sendNextQueuedMessage(in: thread)
    }

    private func pauseQueue(_ id: UUID) {
        if replyQueues[id]?.isEmpty == false { pausedQueues.insert(id) }
    }

    private func removeQueuedMessage(_ id: UUID, from threadID: UUID) {
        replyQueues[threadID]?.removeAll { $0.id == id }
        if replyQueues[threadID]?.isEmpty == true {
            replyQueues[threadID] = nil
            pausedQueues.remove(threadID)
        }
    }

    private func sendNextQueuedMessage(in thread: Conversation) {
        guard !terminating, !isGenerating(thread.id), !pausedQueues.contains(thread.id), thread.archivedAt == nil,
            let next = replyQueues[thread.id]?.first else { return }
        do {
            guard let backend, let role = roles.first(where: { $0.id == thread.roleID }) else {
                throw StudioError.message("助手或 Hermes 不可用，消息仍在队列中。")
            }
            let workspace = projects(for: role.id).first { $0.id == thread.projectID }?.directory
            try checkWorkspace(workspace, projectID: thread.projectID)
            if let skill = next.skill, !skills.contains(skill) || role.skillIDs?.contains(skill.id) == false {
                throw StudioError.message("待发消息中的技能已不可用，可以移除此消息后继续队列。")
            }
            let saved = try saveRequest(next, in: thread, workspace: workspace)
            removeQueuedMessage(next.id, from: thread.id)
            startTurn(in: saved.thread, backend: backend, text: saved.prompt, images: next.images, skill: next.skill,
                workspace: workspace, skillIDs: role.skillIDs, allowGroupLookup: saved.allowGroupLookup)
        } catch {
            pauseQueue(thread.id)
            conversationErrors[thread.id] = error.localizedDescription
        }
    }

    func handoffDestination(for request: Message) -> Conversation? {
        guard let handoff = request.handoff else { return nil }
        return conversations[handoff.targetRoleID]?.first { $0.id == request.id }
    }

    func handoffReceiptStatus(for destination: Conversation, recipient: String) -> String {
        if destination.archivedAt != nil { return "接手对话已归档" }
        if let turn = runningTurns[destination.id] {
            return turn.permissions.isEmpty ? "\(recipient)正在接手" : "\(recipient)正在等待审批"
        }
        if conversationErrors[destination.id] != nil { return "接手对话有提示" }
        return "已交接给\(recipient)"
    }

    func hasSentQuestion(_ preparationID: UUID) -> Bool {
        conversation?.messages.contains { $0.consultation?.preparationID == preparationID } == true
    }

    func reviewHandoff(_ request: Message) -> RoleHandoffReview? {
        guard let source = conversation, let role,
            let request = source.messages.first(where: { $0.id == request.id }),
            let handoff = request.handoff,
            let target = roles.first(where: { $0.id == handoff.targetRoleID }),
            let text = handoff.deliveryText(task: request.text, sourceName: role.name) else { return nil }
        let origin = RoleHandoffOrigin(roleID: role.id, conversationID: source.id, roleName: role.name)
        return RoleHandoffReview(id: request.id, origin: origin, target: target, text: text,
            isQuestion: handoff.isQuestion == true)
    }

    func openHandoffConversation(_ id: UUID, roleID: UUID) {
        guard let role = roles.first(where: { $0.id == roleID }),
            activeThreads(for: roleID).contains(where: { $0.id == id }) else {
            error = "交接会话已不可用。"
            return
        }
        selectedThreads[roleID] = id
        select(role)
    }

    func sendHandoff(_ review: RoleHandoffReview) {
        let targetID = review.target.id
        guard let backend, let target = roles.first(where: { $0.id == targetID }),
            let source = activeThreads(for: review.origin.roleID).first(where: { $0.id == review.origin.conversationID }),
            let request = source.messages.first(where: { $0.id == review.id }),
            let handoff = request.handoff, handoff.targetRoleID == targetID,
            (handoff.isQuestion == true) == review.isQuestion,
            handoff.deliveryText(task: request.text, sourceName: review.origin.roleName) == review.text else {
            error = "当前无法发送。请确认 Hermes 和接收助手可用，再重新审阅。"
            return
        }
        if review.isQuestion {
            guard !hasSentQuestion(request.id) else { return }
            guard conversationID == source.id, !isGeneratingHere else {
                error = "请回到来源对话，等当前回复结束后再提问。"
                return
            }
            submitConsultation(question: review.text, to: target, backend: backend, preparationID: request.id)
            return
        }
        guard handoffDestination(for: request) == nil else { return }
        var thread = Conversation(roleID: targetID)
        // 发起消息的 ID 同时标识接收会话，重复确认只会打开同一条会话。
        thread.id = request.id
        thread.title = "来自\(review.origin.roleName)的交接"
        thread.handoffOrigin = review.origin
        thread.messages = [Message(.user, review.text)]
        do { try store.save(thread) } catch {
            report(error)
            return
        }
        let prompt = """
        根据用户的任务说明接手下面的交接。交接摘要是已有工作背景。遇到缺失的文件、权限或决定时，请向用户说明。

        \(review.text)
        """
        startTurn(in: thread, backend: backend, text: prompt, skillIDs: target.skillIDs)
        error = nil
    }

    func consultationText(for requestID: UUID) -> String? {
        guard currentTurn?.consultationID == requestID else { return nil }
        return currentTurn?.consultationText
    }

    func consultationRole(_ consultation: RoleConsultation) -> Role? {
        roles.first { $0.id == consultation.targetRoleID } ?? archivedRoles.first { $0.id == consultation.targetRoleID }
    }

    var sharedConsultationContext: [RoleConsultation.ContextEntry] {
        guard collaborationMode == .question, let consultationShare,
            consultationShare.targetID == selectedHandoffTargetID else { return [] }
        return consultationShare.entries
    }

    func consultationContextReview() -> ConsultationContextReview? {
        guard collaborationMode == .question, !isGeneratingHere, let conversation, let role,
            let target = roles.first(where: { $0.id == selectedHandoffTargetID }) else { return nil }
        let entries = RoleConsultation.recentContext(in: conversation, sourceName: role.name)
        guard !entries.isEmpty else { return nil }
        let selected = sharedConsultationContext
        return ConsultationContextReview(id: draftContext, target: target, entries: entries,
            selectedIDs: Set((selected.isEmpty ? entries : selected).map(\.id)))
    }

    func shareConsultationContext(_ ids: Set<UUID>, from review: ConsultationContextReview) {
        guard draftContext == review.id, selectedHandoffTargetID == review.target.id,
            collaborationMode == .question, !isGeneratingHere else { return }
        let entries = review.entries.filter { ids.contains($0.id) }
        consultationShare = entries.isEmpty ? nil : ConsultationShare(targetID: review.target.id, entries: entries)
    }

    func clearConsultationContext() { consultationShare = nil }

    func retryConsultation(_ requestID: UUID) {
        guard !isGeneratingHere, let backend, let thread = conversation,
            let index = thread.messages.firstIndex(where: { $0.id == requestID }),
            let request = thread.messages[index].consultation, request.status != .answered,
            let target = roles.first(where: { $0.id == request.targetRoleID }) else {
            error = "请确认接收助手和 Hermes 可用，等当前回复结束后重试。"
            return
        }
        // 重试旧问题时保留时间线顺序，回复仍归到最初的提问。
        runConsultation(in: thread, at: index, target: target, backend: backend)
    }

    func quoteConsultation(_ requestID: UUID) {
        guard let request = conversation?.messages.first(where: { $0.id == requestID }),
            let consultation = request.consultation, consultation.status == .answered,
            let answer = consultation.answer else { return }
        guard selectedHandoffTargetID == nil else {
            error = "先移除输入框里的协作对象，再把回复引用给当前助手。"
            return
        }
        let quote = """
        请参考「\(consultation.targetName)」的协作回复，结合当前对话继续处理。

        提问：
        \(request.text)

        协作回复：
        \(answer)
        """
        guard !draft.contains(quote) else { return }
        draft = [draft, quote].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func submitConsultation(question: String, to target: Role, backend: HermesRuntime,
        preparationID: UUID? = nil, context: [RoleConsultation.ContextEntry] = []) {
        guard let roleID else { return }
        var thread = conversation ?? Conversation(roleID: roleID)
        thread.projectID = projectID
        thread.sessionID = composerSessionID
        if thread.messages.isEmpty {
            thread.title = "向\(target.name)提问"
        }
        var request = Message(.user, question)
        request.consultation = RoleConsultation(target: target, preparationID: preparationID, context: context)
        thread.messages.append(request)
        guard runConsultation(in: thread, at: thread.messages.count - 1, target: target, backend: backend) else { return }
        if preparationID == nil {
            let previousScope = composerScope
            preparedSessions[draftContext] = nil
            restoreDraft(ComposerDraft())
            select(thread)
            if let previousScope, previousScope != composerScope { clearComposer(previousScope) }
        }
    }

    @discardableResult
    private func runConsultation(in initialThread: Conversation, at index: Int, target: Role, backend: HermesRuntime) -> Bool {
        var thread = initialThread
        let threadID = thread.id
        let scratch = RoleStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-studio-consultation-\(UUID())", isDirectory: true))
        do {
            try scratch.create(target, instructions: store.file(.soul, for: target.id))
            thread.messages[index].consultation?.status = .pending
            thread.messages[index].consultation?.answer = nil
            thread.updated = Date()
            try store.save(thread)
        } catch {
            try? FileManager.default.removeItem(at: scratch.root)
            report(error)
            return false
        }
        let control = TurnControl()
        let requestID = thread.messages[index].id
        runningTurns[threadID] = RunningTurn(control: control, approval: nil, preparingHandoff: false,
            activity: "\(target.name)正在回答", consultationID: requestID)
        conversationErrors[threadID] = nil
        error = nil
        publish(thread)
        let events = backend.consultation(home: scratch.runtime(for: target.id), role: target,
            question: thread.messages[index].text, context: thread.messages[index].consultation?.context ?? [],
            temporaryRoot: scratch.root, control: control)
        Task {
            var answer = ""
            var status = RoleConsultation.Status.failed
            for await event in events {
                switch event {
                case .text(let text, _):
                    if !control.isCancelled {
                        answer += text
                        runningTurns[threadID]?.consultationText = TextOnlyReply.parse(answer, streaming: true).text
                    }
                case .finished(let reason):
                    if control.isCancelled || reason == "cancelled" { status = .stopped }
                    else if reason == "end_turn" { status = .answered }
                case .failed(let reason):
                    if control.isCancelled { status = .stopped }
                    else { conversationErrors[threadID] = reason }
                default:
                    break
                }
            }
            answer = TextOnlyReply.parse(answer).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if status == .answered && answer.isEmpty { status = .failed }
            if status == .answered { thread.messages[index].consultation?.answer = answer }
            thread.messages[index].consultation?.status = status
            do { try store.save(thread) } catch {
                thread.messages[index].consultation?.status = .failed
                thread.messages[index].consultation?.answer = nil
                conversationErrors[threadID] = error.localizedDescription
            }
            publish(thread)
            runningTurns.removeValue(forKey: threadID)
            if thread.messages[index].consultation?.status == .answered { sendNextQueuedMessage(in: thread) }
            else { pauseQueue(threadID) }
        }
        return true
    }

    func respond(to permission: ToolPermission, option: String?) {
        guard let id = conversationID, let turn = runningTurns[id],
            turn.permissions.contains(where: { $0.id == permission.id }) else { return }
        if !turn.control.respond(to: permission.id, optionID: option) {
            error = "这条审核请求已失效。"
        }
        runningTurns[id]?.permissions.removeAll { $0.id == permission.id }
    }

    private func validateWorkspace() -> Bool {
        do {
            try checkWorkspace(project?.directory, projectID: projectID)
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func checkWorkspace(_ workspace: URL?, projectID: UUID?) throws {
        if projectID != nil, workspace == nil {
            throw StudioError.message("找不到此助手的项目。可以先将对话移回对话记录。")
        }
        if let workspace, (try? workspace.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            throw StudioError.message("项目目录已移动或不可访问。")
        }
    }

    private func requestInput(_ text: String, in thread: Conversation, hasImages: Bool, skill: HermesSkill?,
        workspace: URL?, handoff: RoleHandoff? = nil) -> (prompt: String, recallsGroup: Bool, allowGroupLookup: Bool) {
        let asksAboutGroup = GroupChatRecall.explicitlyReferencesGroup(text, roleID: thread.roleID,
            discussions: groupWorkspace.discussions)
        let consultation = asksAboutGroup || handoff != nil ? nil
            : RoleConsultation.localReplyContext(for: text, in: thread, roles: roles + archivedRoles)
        if !text.isEmpty, consultation == nil, handoff == nil, !hasImages, skill == nil, workspace == nil,
            let recall = GroupChatRecall.prompt(for: text, in: thread, roles: roles, discussions: groupWorkspace.discussions) {
            return (recall, true, true)
        }
        if let handoff {
            return (GroupChatRecall.withPreviousReplies(handoff.preparationPrompt(task: text), messages: thread.messages), false, true)
        }
        let withRoles = RoleDirectoryEntry.promptForMentions(in: text, roles: roles, caller: thread.roleID)
        if let consultation { return ("\(withRoles)\n\n\(consultation)", false, false) }
        return (text.hasPrefix("/") ? withRoles : GroupChatRecall.withPreviousReplies(withRoles, messages: thread.messages), false, true)
    }

    @discardableResult
    private func deliver(text: String, images attachments: [ImagePayload], skill selectedSkill: HermesSkill?,
        handoff: RoleHandoff? = nil) -> Bool {
        guard let targetRoleID = roleID, let backend, validateWorkspace() else { return false }
        let workspace = project?.directory
        var thread = conversation ?? Conversation(roleID: targetRoleID)
        thread.projectID = projectID
        thread.sessionID = composerSessionID
        let skill = selectedSkill.flatMap { availableSkills.contains($0) ? $0 : nil }
        let message = QueuedMessage(text: text, images: attachments, skill: skill)
        let saved: (thread: Conversation, prompt: String, allowGroupLookup: Bool)
        do {
            saved = try saveRequest(message, in: thread, workspace: workspace, handoff: handoff)
        } catch {
            report(error)
            return false
        }
        let previousScope = composerScope
        preparedSessions[draftContext] = nil
        restoreDraft(ComposerDraft())
        startTurn(in: saved.thread, backend: backend, text: saved.prompt,
            images: attachments, skill: skill, workspace: workspace, skillIDs: role?.skillIDs,
            allowGroupLookup: saved.allowGroupLookup)
        select(saved.thread)
        if let previousScope, previousScope != composerScope { clearComposer(previousScope) }
        error = nil
        return true
    }

    private func saveRequest(_ message: QueuedMessage, in existingThread: Conversation, workspace: URL?,
        handoff: RoleHandoff? = nil) throws -> (thread: Conversation, prompt: String, allowGroupLookup: Bool) {
        var thread = existingThread
        if thread.messages.isEmpty {
            let title = message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? message.skill?.name ?? "图片消息"
            thread.title = String(title.prefix(32))
        }
        let input = requestInput(message.text, in: thread, hasImages: !message.images.isEmpty,
            skill: message.skill, workspace: workspace, handoff: handoff)
        thread.updated = Date()
        var request = Message(.user, message.text)
        request.id = message.id
        if !message.images.isEmpty {
            request.images = try message.images.map { try store.saveImage($0, for: thread.roleID) }
        }
        request.skill = message.skill?.name
        request.handoff = handoff
        if input.recallsGroup { request.usedGroupRecall = true }
        thread.messages.append(request)
        try store.save(thread)
        return (thread, input.prompt, input.allowGroupLookup)
    }

    private func startTurn(in initialThread: Conversation, backend: HermesRuntime, text: String,
        images attachments: [ImagePayload] = [], skill: HermesSkill? = nil, workspace: URL? = nil,
        skillIDs allowedSkills: Set<String>? = nil, allowGroupLookup: Bool = true, retrying: Int? = nil) {
        var thread = initialThread
        let outputStart = thread.messages.count
        let requestIndex = retrying ?? outputStart - 1
        let handoff = thread.messages[requestIndex].handoff
        let start = ContinuousClock.now
        let threadID = thread.id
        let targetRoleID = thread.roleID
        let control = TurnControl()
        let recalling = thread.messages[requestIndex].usedGroupRecall == true
        let activity = recalling ? "正在回顾群聊" : handoff.map { $0.isQuestion == true ? "正在拟问题" : "正在整理交接摘要" } ?? "正在提交消息"
        runningTurns[threadID] = RunningTurn(control: control, approval: recalling ? nil : runPreferences.approval,
            preparingHandoff: handoff != nil, activity: activity, recallingGroup: recalling)
        conversationErrors[threadID] = nil
        publish(thread)
        let events: AsyncStream<TurnEvent>
        if recalling {
            let home = groupRecallStore.runtime(for: targetRoleID)
            do {
                guard let role = roles.first(where: { $0.id == targetRoleID }) else {
                    throw StudioError.message("当前助手已不可用。")
                }
                let instructions = try store.file(.soul, for: targetRoleID)
                if !FileManager.default.fileExists(atPath: home.path) {
                    try FileManager.default.createDirectory(at: groupRecallStore.root,
                        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try groupRecallStore.create(role, instructions: instructions)
                } else if try groupRecallStore.file(.soul, for: targetRoleID) != instructions {
                    try groupRecallStore.writeFile(.soul, for: targetRoleID, text: instructions)
                }
            } catch {
                runningTurns.removeValue(forKey: threadID)
                conversationErrors[threadID] = error.localizedDescription
                pauseQueue(threadID)
                return
            }
            let settings = thread.sessionID.flatMap { runSettingsBySession[$0] }
            events = backend.groupRecall(home: home, roleID: targetRoleID,
                prompt: text, model: settings?[.model]?.value ?? runPreferences.modelID,
                effort: settings?[.effort]?.value ?? runPreferences.effort, control: control)
        } else {
            events = backend.turn(home: store.runtime(for: targetRoleID), conversation: thread, text: text,
                images: attachments, skill: skill, workspace: workspace, skillIDs: allowedSkills,
                mcpServers: mcp.connections(for: targetRoleID, allowGroupLookup: allowGroupLookup), preferences: runPreferences,
                useModelDefaults: thread.sessionID == nil, interactive: true, control: control)
        }
        Task {
            var completedHandoff = false
            var completed = false
            var interrupted = false
            var recallText = ""
            var recallRequestedTool = false
            for await event in events {
                if recalling {
                    switch event {
                    case .tool, .permission:
                        recallRequestedTool = true
                        control.cancel()
                        continue
                    default:
                        break
                    }
                    if recallRequestedTool { continue }
                }
                switch event {
                case .session(let id):
                    if recalling { continue }
                    thread.sessionID = id
                    persist(thread)
                case .runSettings(let settings):
                    if let id = thread.sessionID { runSettingsBySession[id] = settings }
                case .text(let text, let id):
                    guard !control.isCancelled else { continue }
                    runningTurns[threadID]?.activity = "正在回复"
                    if recalling { recallText += text }
                    let visible = recalling ? TextOnlyReply.parse(recallText, streaming: true).text : text
                    if let last = thread.messages.indices.last, last >= outputStart,
                        thread.messages[last].author == .assistant, recalling || thread.messages[last].remoteID == id {
                        if recalling { thread.messages[last].text = visible }
                        else { thread.messages[last].text += visible }
                    } else if !visible.isEmpty {
                        thread.messages.append(Message(.assistant, visible, remoteID: id))
                    }
                    publish(thread)
                case .image(let image):
                    guard !control.isCancelled, !recalling else { continue }
                    do {
                        var message = Message(.assistant, "")
                        message.images = [try store.saveImage(image, for: targetRoleID)]
                        thread.messages.append(message)
                        publish(thread)
                    } catch { conversationErrors[threadID] = error.localizedDescription }
                case .tool(let update):
                    guard !control.isCancelled else { continue }
                    if let index = thread.messages.indices.reversed().first(where: {
                        $0 >= outputStart && thread.messages[$0].tool?.id == update.id
                    }) {
                        thread.messages[index].tool = thread.messages[index].tool?.updating(with: update)
                    } else {
                        var message = Message(.tool, "")
                        message.tool = update
                        thread.messages.append(message)
                    }
                    publish(thread)
                case .permission(let permission):
                    guard !control.isCancelled else { continue }
                    runningTurns[threadID]?.permissions.append(permission)
                case .permissionExpired(let toolID):
                    runningTurns[threadID]?.permissions.removeAll { $0.toolID == toolID }
                case .followUpReady, .followUpStarted, .followUpRejected:
                    break
                case .insertionAccepted(let id, let text):
                    guard id == runningTurns[threadID]?.insertion else { continue }
                    var message = Message(.user, text)
                    message.id = id
                    message.isGuidance = true
                    thread.messages.append(message)
                    removeQueuedMessage(id, from: threadID)
                    runningTurns[threadID]?.insertion = nil
                    publish(thread)
                    persist(thread)
                case .insertionFailed(let id, let reason):
                    guard id == runningTurns[threadID]?.insertion else { continue }
                    runningTurns[threadID]?.insertion = nil
                    conversationErrors[threadID] = reason
                    pauseQueue(threadID)
                case .activity(let title):
                    if !control.isCancelled, !recalling || title == "等待模型回复" { runningTurns[threadID]?.activity = title }
                case .finished(let reason):
                    if recalling, !control.isCancelled {
                        let visible = TextOnlyReply.parse(recallText).text
                        if let last = thread.messages.indices.last, last >= outputStart, thread.messages[last].author == .assistant {
                            thread.messages[last].text = visible
                        } else if !visible.isEmpty {
                            thread.messages.append(Message(.assistant, visible))
                        }
                    }
                    completed = reason == "end_turn" && !control.isCancelled
                    completedHandoff = handoff != nil && completed
                    if reason == "cancelled" {
                        interrupted = !recallRequestedTool
                        conversationErrors[threadID] = "回复已停止。"
                    } else if control.isCancelled {
                        conversationErrors[threadID] = "本轮回复已结束。"
                    } else if !thread.messages.dropFirst(outputStart).contains(where: { $0.author == .assistant }) {
                        conversationErrors[threadID] = "Hermes 结束了本轮对话，但没有返回内容。请检查模型配置或再发一条消息。"
                    }
                case .failed(let message):
                    conversationErrors[threadID] = message
                }
            }
            if recallRequestedTool {
                thread.messages.removeSubrange(outputStart...)
                conversationErrors[threadID] = "群聊回顾已停止。这个回合只能根据附带的群聊片段回复。"
            }
            finishRequest(in: &thread, at: requestIndex, outputStart: outputStart, started: start)
            thread.messages[requestIndex].interrupted = interrupted
            if completedHandoff, conversationErrors[threadID] == nil {
                let output = thread.messages.dropFirst(requestIndex + 1)
                let lastAction = output.lastIndex { $0.tool != nil || $0.isGuidance == true }
                let reply = lastAction.map { output.suffix(from: $0 + 1) } ?? output
                let brief = reply.filter { $0.author == .assistant }.map(\.text)
                    .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !brief.isEmpty { thread.messages[requestIndex].handoff?.brief = brief }
            }
            do { try store.save(thread) } catch {
                thread.messages[requestIndex].handoff?.brief = nil
                conversationErrors[threadID] = error.localizedDescription
            }
            publish(thread)
            if runningTurns.removeValue(forKey: threadID)?.insertion != nil {
                pauseQueue(threadID)
                if conversationErrors[threadID] == nil {
                    conversationErrors[threadID] = "未收到插入确认，消息仍在队列中。"
                }
            }
            if self.roleID == targetRoleID {
                do { try reloadFiles(for: targetRoleID) } catch { conversationErrors[threadID] = error.localizedDescription }
            }
            if !recalling { groupWorkspace.reloadProposals() }
            if completed, conversationErrors[threadID] == nil { sendNextQueuedMessage(in: thread) }
            else { pauseQueue(threadID) }
        }
    }

    private func finishRequest(in thread: inout Conversation, at requestIndex: Int, outputStart: Int, started: ContinuousClock.Instant) {
        for index in thread.messages.indices.dropFirst(outputStart) {
            guard let tool = thread.messages[index].tool, tool.isRunning else { continue }
            thread.messages[index].tool = tool.updating(with: ToolRun(id: tool.id, title: nil, status: "cancelled", details: nil))
        }
        let previousDuration = thread.messages[requestIndex].workDuration ?? 0
        thread.messages[requestIndex].workDuration = previousDuration + Double(started.duration(to: .now).components.seconds)
    }

    private func prewarm() {
        guard !showManagement, !isGeneratingHere, let role else { return }
        guard projectID == nil || project != nil else { return }
        let revision = runtimeRevision
        backend?.warm(home: store.runtime(for: role.id), conversation: conversation, workspace: project?.directory,
            skillIDs: role.skillIDs, mcpServers: mcp.connections(for: role.id)) { [weak self] id, settings in
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
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[index] = thread
        } else {
            threads.insert(thread, at: 0)
        }
        conversations[thread.roleID] = threads
    }

    private func persist(_ thread: Conversation) {
        do { try store.save(thread) } catch { conversationErrors[thread.id] = error.localizedDescription }
    }

    private func report(_ error: Error) { self.error = error.localizedDescription }
}
