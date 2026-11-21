import StudioCore
import SwiftUI

enum ManagementPage: String, CaseIterable {
    case overview = "工作台"
    case roles = "角色库"
    case projects = "项目"
    case conversations = "对话记录"

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .roles: "person.2"
        case .projects: "folder"
        case .conversations: "bubble.left.and.bubble.right"
        }
    }
}

struct ManagementPane: View {
    @ObservedObject var studio: StudioModel
    @Binding var page: ManagementPage
    let sidebarVisible: Bool
    let toolbarLeading: CGFloat
    let sidebarLabel: String
    let toggleSidebar: () -> Void
    let create: () -> Void
    let edit: (Role) -> Void
    let details: (Role) -> Void
    let terminalDetails: (URL) -> Void
    let editFile: (Role, RoleFile) -> Void
    let createProject: (Role) -> Void
    let openDraftBox: () -> Void
    @State private var roleQuery = ""
    @State private var conversationQuery = ""
    @State private var pinnedOnly = false
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
            StudioIconButton(title: sidebarLabel, symbol: "sidebar.left", action: toggleSidebar)
            if !sidebarVisible {
                Menu {
                    ForEach(ManagementPage.allCases, id: \.self) { tab in
                        Button(tab.rawValue, systemImage: tab == page ? "checkmark" : tab.icon) { navigate(tab) }
                    }
                } label: {
                    Label(page.rawValue, systemImage: page.icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("切换页面")
            }
            Spacer()
            Button {
                if page != .conversations { navigate(.roles) }
                searchFocused = true
            } label: {
                Label(page == .conversations ? "搜索对话" : "搜索角色", systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioPalette.muted)
                    .padding(.horizontal, 7)
                    .frame(height: 28)
            }
            .buttonStyle(StudioRowButton())
            .keyboardShortcut("k", modifiers: .command)
            .help("搜索（⌘K）")
            if !sidebarVisible {
                StudioIconButton(title: studio.available ? "重新检测本机 Hermes" : "未检测到 Hermes，点击重新检测",
                    symbol: studio.available ? "checkmark.circle" : "exclamationmark.circle", action: studio.refreshRuntime)
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
                ManagementRoleCard(role: role, store: studio.store, conversationCount: studio.conversations[role.id]?.count ?? 0,
                    open: { studio.select(role) }, details: { details(role) }, togglePin: { studio.togglePin(role) },
                    edit: { edit(role) }, editFile: { editFile(role, $0) }, archive: { studio.archiveRole(role) })
            }
        }
    }

    private var draftBoxButton: some View {
        Button(action: openDraftBox) {
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
    }
}
