import StudioCore
import SwiftUI

struct WorkbenchOverview: View {
    @ObservedObject var studio: StudioModel
    let create: () -> Void
    let openProjects: () -> Void
    let openHistory: () -> Void
    @State private var preferredRoleID: UUID?
    @State private var preferredProjectID: UUID?
    @State private var preferTerminal = false

    private var recent: [Conversation] { studio.recentThreads }
    private var pinned: [Conversation] {
        recent.filter { $0.pinnedAt != nil }
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
    }

    private var selectedRole: Role? {
        if preferTerminal && terminalShortcut != nil { return nil }
        let roleID = preferredRoleID ?? studio.role?.id ?? recent.first?.roleID
        return studio.roles.first { $0.id == roleID } ?? studio.roles.first
    }

    private var terminalShortcut: URL? {
        studio.terminalHome.flatMap { studio.linkedTerminalRole(for: $0) == nil ? $0 : nil }
    }

    private var roleProjects: [StudioProject] { selectedRole.map { studio.projects(for: $0.id) } ?? [] }
    private var selectedProject: StudioProject? { roleProjects.first { $0.id == preferredProjectID } }
    private var prompt: String { studio.workbenchDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var recentProjects: [StudioProject] {
        var lastActivity: [UUID: Date] = [:]
        for thread in recent {
            if let projectID = thread.projectID, lastActivity[projectID] == nil {
                lastActivity[projectID] = thread.updated
            }
        }
        return studio.roles.flatMap { studio.projects(for: $0.id) }.sorted {
            (lastActivity[$0.id] ?? $0.created) > (lastActivity[$1.id] ?? $1.created)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("工作台")
                .font(.system(size: 28, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            startCard
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    activity.frame(minWidth: 350, maxWidth: .infinity)
                    projects.frame(width: 242)
                }
                VStack(alignment: .leading, spacing: 23) {
                    activity
                    projects
                }
            }
        }
        .frame(maxWidth: 880)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var startCard: some View {
        if selectedRole != nil || terminalShortcut != nil {
            VStack(alignment: .leading, spacing: 0) {
                TextField("想处理什么？", text: $studio.workbenchDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(2...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .accessibilityLabel("新对话内容")

                StudioRule()
                HStack(spacing: 8) {
                    RolePickerButton(roles: studio.roles, selected: selectedRole, store: studio.store,
                        selectTerminal: terminalShortcut == nil ? nil : {
                            preferTerminal = true
                            preferredProjectID = nil
                        }) { role in
                        preferredRoleID = role.id
                        preferTerminal = false
                        preferredProjectID = nil
                    }
                    .frame(maxWidth: 155, alignment: .leading)
                    if !roleProjects.isEmpty { projectPicker }
                    Spacer(minLength: 4)
                    StudioPrimaryButton(title: prompt.isEmpty ? "新对话" : "发送",
                        symbol: prompt.isEmpty ? "square.and.pencil" : "arrow.up", action: startConversation)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
            }
            .background(StudioPalette.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(StudioPalette.outline).allowsHitTesting(false)
            }
        } else {
            HStack {
                Text("创建角色后即可发起对话").foregroundStyle(StudioPalette.muted)
                Spacer()
                StudioPrimaryButton(title: "创建角色", symbol: "plus", action: create)
            }
            .font(.system(size: 12))
            .padding(12)
            .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var projectPicker: some View {
        Menu {
            Button("不关联项目", systemImage: selectedProject == nil ? "checkmark" : "bubble.left") {
                preferredProjectID = nil
            }
            ForEach(roleProjects) { project in
                Button(project.name, systemImage: selectedProject?.id == project.id ? "checkmark" : "folder") {
                    preferredProjectID = project.id
                }
            }
        } label: {
            Label(selectedProject?.name ?? "不关联项目", systemImage: "folder")
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 155, alignment: .leading)
        .accessibilityLabel("选择项目")
        .accessibilityValue(selectedProject?.name ?? "不关联项目")
    }

    private func startConversation() {
        if let role = selectedRole {
            openNewConversation(role, project: selectedProject)
        } else if let terminalShortcut {
            studio.withTerminalRole(from: terminalShortcut) { openNewConversation($0, project: nil) }
        }
    }

    private func openNewConversation(_ role: Role, project: StudioProject?) {
        let text = prompt
        studio.select(role)
        if let project {
            studio.newConversation(in: project)
        } else {
            if studio.conversationID != nil || !text.isEmpty { studio.newConversation() }
            studio.chooseProject(nil)
        }
        if !text.isEmpty {
            studio.draft = text
            studio.workbenchDraft = ""
            studio.send()
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !pinned.isEmpty {
                conversationList("已置顶", threads: Array(pinned.prefix(4)))
            }
            conversationList("最近对话", threads: Array(recent.filter { $0.pinnedAt == nil }.prefix(5)),
                actionTitle: "全部对话", action: openHistory)
        }
    }

    private func conversationList(_ title: String, threads: [Conversation],
        actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title, actionTitle: actionTitle, action: action)
            if threads.isEmpty {
                empty("暂无最近对话")
            }
            ForEach(threads) { thread in
                if let role = studio.roles.first(where: { $0.id == thread.roleID }) {
                    WorkspaceConversationRow(thread: thread, role: role, studio: studio)
                    StudioRule()
                }
            }
        }
    }

    private var projects: some View {
        let orderedProjects = recentProjects
        let projectsByName = Dictionary(grouping: orderedProjects, by: \.name)
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("最近项目", actionTitle: "全部项目", action: openProjects)
            if orderedProjects.isEmpty { empty("暂无项目") }
            ForEach(orderedProjects.prefix(4)) { project in
                Button { studio.startConversation(in: project) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(StudioPalette.muted)
                            .frame(width: 25)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if let role = studio.roles.first(where: { $0.id == project.roleID }) {
                                let pathHint = (projectsByName[project.name]?.count ?? 0) > 1
                                    ? " · \(project.directory.deletingLastPathComponent().lastPathComponent)" : ""
                                Text(role.name + pathHint).font(.system(size: 11))
                                    .foregroundStyle(StudioPalette.muted).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 3)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                            .foregroundStyle(StudioPalette.muted)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 5)
                    .frame(height: 43)
                }
                .buttonStyle(StudioRowButton())
                .help("在 \(project.path) 中新建对话")
            }
        }
    }

    private func sectionHeader(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 5)
                if let actionTitle, let action {
                    Button(action: action) {
                        HStack(spacing: 5) {
                            Text(actionTitle)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioPalette.muted)
                        .padding(.horizontal, 5)
                        .frame(height: 24)
                    }
                    .buttonStyle(StudioRowButton())
                }
            }
            StudioRule()
        }
    }

    private func empty(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(StudioPalette.muted)
            .padding(.vertical, 12)
    }
}
