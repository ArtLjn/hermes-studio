import StudioCore
import SwiftUI

enum ManagementPage: String {
    case overview = "工作台"
    case roles = "角色库"
    case projects = "项目"
    case conversations = "对话记录"
    case archivedChats = "已归档对话"
    case drafts = "角色草稿箱"

    static let destinations: [Self] = [.overview, .roles, .projects, .conversations]

    var navigationRoot: Self {
        switch self {
        case .archivedChats: .conversations
        case .drafts: .roles
        default: self
        }
    }

    var icon: String {
        switch self {
        case .overview: "house"
        case .roles: "person.2"
        case .projects: "folder"
        case .conversations: "clock"
        case .archivedChats: "archivebox"
        case .drafts: "tray"
        }
    }
}

struct ManagementPane: View {
    @ObservedObject var studio: StudioModel
    @Binding var page: ManagementPage
    let toolbarLeading: CGFloat
    let create: () -> Void
    let edit: (Role) -> Void
    let details: (Role) -> Void
    let terminalDetails: (URL) -> Void
    let editFile: (Role, RoleFile) -> Void
    let createProject: (Role) -> Void
    @State private var roleQuery = ""
    @State private var conversationQuery = ""
    @State private var pinnedOnly = false
    @State private var previewingArchive: UUID?
    @FocusState private var searchFocused: Bool

    private var orderedRoles: [Role] {
        let activity = studio.conversations.mapValues { $0.first?.updated ?? .distantPast }
        let terminalRoleID = studio.terminalHome.flatMap { studio.linkedTerminalRole(for: $0)?.id }
        return studio.roles.filter { $0.id != terminalRoleID }.sorted { left, right in
            if (left.pinned == true) != (right.pinned == true) { return left.pinned == true }
            let lastLeft = activity[left.id, default: .distantPast]
            let lastRight = activity[right.id, default: .distantPast]
            return lastLeft == lastRight ? left.created < right.created : lastLeft > lastRight
        }
    }

    private var matchingRoles: [Role] {
        let query = roleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return orderedRoles.filter { role in
            (!pinnedOnly || role.pinned == true) && (query.isEmpty
                || role.name.localizedCaseInsensitiveContains(query) || role.summary.localizedCaseInsensitiveContains(query))
        }
    }

    private var matchingThreads: [Conversation] {
        let query = conversationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return studio.recentThreads }
        let matchingIDs = Set(studio.roles.filter { $0.name.localizedCaseInsensitiveContains(query) }.map(\.id))
        return studio.recentThreads.filter { $0.title.localizedCaseInsensitiveContains(query) || matchingIDs.contains($0.roleID) }
    }

    private var archivedPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("已归档对话", subtitle: "恢复后，对话会回到原来的角色和项目。", addRole: false)
            if studio.archivedThreads.isEmpty {
                emptyState("还没有已归档的对话", icon: "archivebox")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(studio.archivedThreads) { thread in
                        if let role = role(for: thread), let archivedAt = thread.archivedAt {
                            HStack(spacing: 10) {
                                RolePortrait(role: role, store: studio.store, size: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(thread.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    let project = studio.projects(for: role.id).first { $0.id == thread.projectID }
                                    Text([role.name, project?.name].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(archivedAt, style: .date)
                                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                                Button("恢复", systemImage: "arrow.uturn.backward") {
                                    studio.setConversationArchived(thread, archived: false)
                                    if previewingArchive == thread.id { previewingArchive = nil }
                                }
                                .buttonStyle(QuietButton())
                                .accessibilityLabel("恢复对话 \(thread.title)")
                                Button(previewingArchive == thread.id ? "收起" : "查看",
                                    systemImage: previewingArchive == thread.id ? "chevron.up" : "chevron.down") {
                                    previewingArchive = previewingArchive == thread.id ? nil : thread.id
                                }
                                .buttonStyle(QuietButton())
                            }
                            .padding(.vertical, 9)
                            if previewingArchive == thread.id {
                                VStack(alignment: .leading, spacing: 18) {
                                    if thread.messages.isEmpty {
                                        Text("这条对话还没有消息。")
                                            .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                                    }
                                    ForEach(ChatTurn.collect(thread.messages)) { turn in
                                        ChatTurnRow(turn: turn, role: role, store: studio.store,
                                            roleID: role.id, activity: nil)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 9))
                                .padding(.bottom, 9)
                            }
                            StudioRule()
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            StudioRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    switch page {
                    case .overview:
                        WorkbenchOverview(studio: studio, roles: orderedRoles, create: create,
                            openRoles: { navigate(.roles) }, openProjects: { navigate(.projects) },
                            openHistory: { navigate(.conversations) })
                    case .roles: catalog
                    case .projects: ProjectPane(studio: studio, create: createProject)
                    case .conversations: conversationList
                    case .archivedChats: archivedPage
                    case .drafts: RoleDraftBox(studio: studio)
                    }
                    if let error = studio.error {
                        Label(error, systemImage: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(StudioPalette.accent)
                    }
                }
                .frame(maxWidth: 1000)
                .padding(.horizontal, 32)
                .padding(.top, 29)
                .padding(.bottom, 35)
                .frame(maxWidth: .infinity)
            }
            .id(page)
        }
        .onChange(of: studio.roles.count) { _, _ in
            roleQuery = ""
            pinnedOnly = false
        }
    }

    private var topBar: some View {
        HStack(spacing: 9) {
            if page != page.navigationRoot {
                Button {
                    navigate(page.navigationRoot)
                } label: {
                    Label(page.navigationRoot.rawValue, systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StudioPalette.muted)
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                }
                .buttonStyle(StudioRowButton())
                .accessibilityLabel("返回\(page.navigationRoot.rawValue)")
            }
            Spacer()
            if page == .roles || page == .conversations {
                StudioIconButton(title: page == .conversations ? "搜索对话（⌘K）" : "搜索角色（⌘K）",
                    symbol: "magnifyingglass") { searchFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
        .padding(.leading, toolbarLeading)
        .padding(.trailing, 15)
        .frame(height: StudioPalette.toolbarHeight)
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("角色库", subtitle: "管理 Hermes 的指令和独立记忆。", addRole: true)
            HStack(spacing: 8) {
                Button("全部角色") { pinnedOnly = false }
                    .buttonStyle(QuietButton())
                    .accessibilityAddTraits(pinnedOnly ? [] : .isSelected)
                Button("已置顶", systemImage: "pin") { pinnedOnly = true }
                    .buttonStyle(QuietButton())
                    .accessibilityAddTraits(pinnedOnly ? .isSelected : [])
                draftBoxButton
                Spacer()
                searchBox("搜索角色", query: $roleQuery)
            }
            let query = roleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let terminal = pinnedOnly ? nil : studio.terminalHome.flatMap { home in
                let linked = studio.linkedTerminalRole(for: home)
                return query.isEmpty || "终端 Hermes".localizedCaseInsensitiveContains(query)
                    || linked?.name.localizedCaseInsensitiveContains(query) == true
                    || linked?.summary.localizedCaseInsensitiveContains(query) == true || home.path.localizedCaseInsensitiveContains(query)
                    ? home : nil
            }
            if matchingRoles.isEmpty && terminal == nil {
                emptyState(pinnedOnly && roleQuery.isEmpty ? "还没有置顶角色" : "没有匹配的角色",
                    icon: pinnedOnly && roleQuery.isEmpty ? "pin" : "magnifyingglass")
            } else {
                roleGrid(matchingRoles, terminalHome: terminal)
            }
        }
    }

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("对话记录", subtitle: "按角色名称或对话标题查找历史会话。", addRole: false)
            HStack {
                sectionTitle("全部对话", count: matchingThreads.count)
                Spacer()
                searchBox("搜索对话或角色", query: $conversationQuery)
                Button("已归档", systemImage: "archivebox") { navigate(.archivedChats) }
                    .buttonStyle(QuietButton())
                    .fixedSize()
            }
            if matchingThreads.isEmpty {
                emptyState(conversationQuery.isEmpty ? "还没有对话记录" : "没有匹配的对话", icon: "bubble.left.and.bubble.right")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(matchingThreads) { thread in
                        if let role = role(for: thread) {
                            WorkspaceConversationRow(thread: thread, role: role, studio: studio)
                            StudioRule()
                        }
                    }
                }

            }
        }
    }

    private func pageTitle(_ title: String, subtitle: String, addRole: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 28, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
            }
            Spacer()
            if addRole {
                StudioPrimaryButton(title: "创建角色", symbol: "plus", action: create)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        .padding(.bottom, 4)
    }

    private func roleGrid(_ roles: [Role], terminalHome: URL?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 292), spacing: 13)], alignment: .leading, spacing: 13) {
            if let terminalHome {
                TerminalRoleCard(home: terminalHome, role: studio.linkedTerminalRole(for: terminalHome), store: studio.store,
                    open: { studio.withTerminalRole(from: terminalHome, perform: studio.select as (Role) -> Void) },
                    details: { terminalDetails(terminalHome) },
                    edit: { studio.withTerminalRole(from: terminalHome, perform: edit) },
                    editInstructions: { studio.withTerminalRole(from: terminalHome) { editFile($0, .soul) } })
            }
            ForEach(roles) { role in
                ManagementRoleCard(role: role, store: studio.store, conversationCount: studio.activeThreads(for: role.id).count,
                    open: { studio.select(role) }, details: { details(role) }, togglePin: { studio.togglePin(role) },
                    edit: { edit(role) }, editFile: { editFile(role, $0) }, archive: { studio.archiveRole(role) })
            }
        }
    }

    private var draftBoxButton: some View {
        Button { navigate(.drafts) } label: {
            Label(studio.archivedRoles.isEmpty ? "草稿箱" : "草稿箱（\(studio.archivedRoles.count)）", systemImage: "tray")
        }
        .buttonStyle(QuietButton())
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(count.formatted())
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(StudioPalette.muted)
        }
    }

    private func searchBox(_ label: String, query: Binding<String>) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(StudioPalette.muted)
            TextField(label, text: query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel(label)
            if !query.wrappedValue.isEmpty {
                Button("清除搜索", systemImage: "xmark.circle.fill") { query.wrappedValue = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(width: 195, height: 32)
        .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 7))
    }

    private func emptyState(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 13))
            .foregroundStyle(StudioPalette.muted)
            .frame(maxWidth: .infinity, minHeight: 124)
            .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 12))
    }

    private func role(for thread: Conversation) -> Role? {
        studio.roles.first { $0.id == thread.roleID }
    }

    private func navigate(_ destination: ManagementPage) {
        searchFocused = false
        page = destination
    }
}

struct WorkspaceConversationRow: View {
    let thread: Conversation
    let role: Role
    @ObservedObject var studio: StudioModel

    private var project: StudioProject? {
        studio.projects(for: thread.roleID).first { $0.id == thread.projectID }
    }

    var body: some View {
        Button {
            studio.select(role)
            studio.select(thread)
        } label: {
            HStack(spacing: 9) {
                RolePortrait(role: role, store: studio.store, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(role.name).lineLimit(1)
                        if let project {
                            Text("·").accessibilityHidden(true)
                            Label(project.name, systemImage: "folder").lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(StudioPalette.muted)
                }
                Spacer(minLength: 4)
                Text(thread.updated, style: Calendar.current.isDateInToday(thread.updated) ? .time : .date)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(StudioPalette.muted)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(StudioPalette.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .frame(height: 52)
        }
        .buttonStyle(StudioRowButton())
        .contextMenu {
            if thread.id != studio.runningConversation { ConversationOrganizationActions(studio: studio, thread: thread) }
        }
    }
}

struct ConversationOrganizationActions: View {
    @ObservedObject var studio: StudioModel
    let thread: Conversation

    var body: some View {
        Button(thread.pinnedAt == nil ? "置顶对话" : "取消置顶",
            systemImage: thread.pinnedAt == nil ? "pin" : "pin.slash") {
            studio.toggleConversationPin(thread)
        }
        Button("归档对话", systemImage: "archivebox") {
            studio.setConversationArchived(thread, archived: true)
        }
    }
}
