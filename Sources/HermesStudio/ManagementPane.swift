import StudioCore
import SwiftUI

enum ManagementPage: String {
    case overview = "工作台"
    case roles = "角色库"
    case projects = "项目"
    case conversations = "对话记录"
    case mcp = "MCP 管理"
    case archivedChats = "已归档对话"
    case drafts = "角色草稿箱"

    static let destinations: [Self] = [.overview, .roles, .projects, .conversations, .mcp]

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
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .archivedChats: "archivebox"
        case .drafts: "tray"
        }
    }
}

enum ConversationBatch {
    static let size = 8

    static func nextVisibleCount(current: Int, total: Int) -> Int {
        min(current + size, total)
    }
}

enum RoleLibraryFilter: Equatable {
    case all, ungrouped, group(String)

    var title: String {
        switch self {
        case .all: "全部分组"
        case .ungrouped: "未分组"
        case .group(let name): name
        }
    }

    func includes(group: String?) -> Bool {
        switch self {
        case .all: true
        case .ungrouped: group == nil
        case .group(let name): group == name
        }
    }

    func matches(_ role: Role, query: String) -> Bool {
        includes(group: role.libraryGroup) && (query.isEmpty || role.name.localizedCaseInsensitiveContains(query)
            || role.summary.localizedCaseInsensitiveContains(query) || role.libraryGroup?.localizedCaseInsensitiveContains(query) == true)
    }
}

struct ManagementPane: View {
    private enum LibraryGroupEdit: Hashable, Identifiable {
        case create, rename(String)

        var id: Self { self }
    }

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
    @State private var visibleConversationCount = ConversationBatch.size
    @State private var pinnedOnly = false
    @State private var libraryFilter: RoleLibraryFilter = .all
    @State private var editingLibraryGroup: LibraryGroupEdit?
    @State private var dissolvingLibraryGroup: String?
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
            (!pinnedOnly || role.pinned == true) && libraryFilter.matches(role, query: query)
        }
    }

    private var libraryGroups: [String] { studio.libraryGroups }

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
                                        if let consultation = turn.request?.consultation {
                                            RoleConsultationReply(consultation: consultation,
                                                role: studio.consultationRole(consultation), store: studio.store)
                                        }
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
                        WorkbenchOverview(studio: studio, create: create,
                            openProjects: { navigate(.projects) },
                            openHistory: { navigate(.conversations) })
                    case .roles: catalog
                    case .projects: ProjectPane(studio: studio, create: createProject)
                    case .conversations: conversationList
                    case .mcp:
                        MCPManagementPane(management: studio.mcp, roles: studio.roles, test: studio.testMCP)
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
        .onChange(of: libraryGroups) { _, groups in
            if groups.isEmpty { libraryFilter = .all }
            else if case .group(let name) = libraryFilter, !groups.contains(name) { libraryFilter = .all }
        }
        .onChange(of: page) { _, _ in
            visibleConversationCount = ConversationBatch.size
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
            RoleLibraryGroupBar(groups: libraryGroups, selection: $libraryFilter,
                create: { editingLibraryGroup = .create }, rename: { editingLibraryGroup = .rename($0) },
                receive: dropLibraryItem)
            let query = roleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let terminalGroup = studio.terminalHome.flatMap { studio.linkedTerminalRole(for: $0)?.libraryGroup }
            let terminal = pinnedOnly ? nil : studio.terminalHome.flatMap { home in
                guard libraryFilter.includes(group: terminalGroup) else { return nil as URL? }
                let linked = studio.linkedTerminalRole(for: home)
                return query.isEmpty || "终端 Hermes".localizedCaseInsensitiveContains(query)
                    || linked.map { libraryFilter.matches($0, query: query) } == true || home.path.localizedCaseInsensitiveContains(query)
                    ? home : nil
            }
            if matchingRoles.isEmpty && terminal == nil && (!query.isEmpty || pinnedOnly) {
                emptyState(pinnedOnly && roleQuery.isEmpty ? "还没有置顶角色" : "没有匹配的角色",
                    icon: pinnedOnly && roleQuery.isEmpty ? "pin" : "magnifyingglass")
            } else {
                libraryGrids(matchingRoles, terminalHome: terminal, terminalGroup: terminalGroup,
                    showsEmptyGroups: query.isEmpty && !pinnedOnly)
            }
        }
        .sheet(item: $editingLibraryGroup) { operation in
            switch operation {
            case .create:
                RoleLibraryGroupEditor { name in
                    _ = try studio.createLibraryGroup(name)
                    libraryFilter = .all
                    pinnedOnly = false
                    roleQuery = ""
                }
            case .rename(let group):
                RoleLibraryGroupEditor(group: group) { name in
                    let renamed = try studio.renameLibraryGroup(group, to: name)
                    if libraryFilter == .group(group) { libraryFilter = .group(renamed) }
                }
            }
        }
        .alert("解散分组", isPresented: Binding(get: { dissolvingLibraryGroup != nil },
            set: { if !$0 { dissolvingLibraryGroup = nil } }), presenting: dissolvingLibraryGroup) { group in
            Button("取消", role: .cancel) {}
            Button("解散", role: .destructive) { studio.dissolveLibraryGroup(group) }
        } message: { group in
            Text("「\(group)」里的角色将移回「未分组」，角色资料和对话都会保留。")
        }
    }

    @ViewBuilder
    private func libraryGrids(_ roles: [Role], terminalHome: URL?, terminalGroup: String?, showsEmptyGroups: Bool) -> some View {
        switch libraryFilter {
        case .all where libraryGroups.isEmpty && (!roles.isEmpty || terminalHome != nil):
            roleGrid(roles, terminalHome: terminalHome)
        case .all:
            let grouped = Dictionary(grouping: roles, by: \.libraryGroup)
            ForEach(libraryGroups, id: \.self) { group in
                let members = grouped[group] ?? []
                let linkedHome = terminalGroup == group ? terminalHome : nil
                if showsEmptyGroups || !members.isEmpty || linkedHome != nil {
                    roleSection(group, roles: members, terminalHome: linkedHome)
                }
            }
            if grouped[nil]?.isEmpty == false || (terminalGroup == nil && terminalHome != nil) || (libraryGroups.isEmpty && showsEmptyGroups) {
                roleSection(nil, roles: grouped[nil] ?? [], terminalHome: terminalGroup == nil ? terminalHome : nil)
            }
        case .ungrouped:
            roleSection(nil, roles: roles, terminalHome: terminalHome)
        case .group(let group):
            roleSection(group, roles: roles, terminalHome: terminalHome)
        }
    }

    private func roleSection(_ group: String?, roles: [Role], terminalHome: URL?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let group {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioPalette.muted)
                        .frame(width: 21, height: 28)
                        .contentShape(Rectangle())
                        .draggable(RoleLibraryDrag.group(group))
                        .accessibilityLabel("拖动\(group)排序")
                        .help("拖动到其他分组调整顺序")
                } else {
                    Image(systemName: "tray")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioPalette.muted)
                        .frame(width: 21, height: 28)
                        .accessibilityHidden(true)
                }
                sectionTitle(group ?? "未分组", count: roles.count + (terminalHome == nil ? 0 : 1))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let group { libraryGroupActions(group) }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 30)
            if roles.isEmpty && terminalHome == nil {
                Label(group == nil ? "拖到这里，移回未分组" : "将角色拖到这里", systemImage: "plus.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 53)
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(StudioPalette.outline,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])).allowsHitTesting(false) }
            } else {
                roleGrid(roles, terminalHome: terminalHome)
            }
        }
        .modifier(RoleLibraryDropZone(group: group, receive: dropLibraryItem))
    }

    private func libraryGroupActions(_ group: String) -> some View {
        let index = libraryGroups.firstIndex(of: group)
        return Menu {
            Button("重命名分组", systemImage: "pencil") { editingLibraryGroup = .rename(group) }
            Button("上移", systemImage: "arrow.up") {
                if let index, index > 0 { studio.reorderLibraryGroup(group, to: libraryGroups[index - 1]) }
            }
            .disabled((index ?? 0) == 0)
            Button("下移", systemImage: "arrow.down") {
                if let index, index + 1 < libraryGroups.count { studio.reorderLibraryGroup(group, to: libraryGroups[index + 1]) }
            }
            .disabled((index ?? libraryGroups.count) + 1 >= libraryGroups.count)
            Divider()
            Button("解散分组", systemImage: "folder.badge.minus", role: .destructive) { dissolvingLibraryGroup = group }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).frame(width: 27, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("管理\(group)分组")
    }

    private func dropLibraryItem(_ item: RoleLibraryDrag, on group: String?) -> Bool {
        switch item {
        case .role(let id): return studio.moveRole(id, to: group)
        case .group(let name):
            guard let group else { return false }
            return studio.reorderLibraryGroup(name, to: group)
        }
    }

    private var conversationList: some View {
        let threads = matchingThreads
        let visible = threads.prefix(visibleConversationCount)
        return VStack(alignment: .leading, spacing: 16) {
            pageTitle("对话记录", subtitle: "按角色名称或对话标题查找历史会话。", addRole: false)
            HStack {
                sectionTitle("全部对话", count: threads.count)
                Spacer()
                searchBox("搜索对话或角色", query: $conversationQuery)
                Button("已归档", systemImage: "archivebox") { navigate(.archivedChats) }
                    .buttonStyle(QuietButton())
                    .fixedSize()
            }
            if threads.isEmpty {
                emptyState(conversationQuery.isEmpty ? "还没有对话记录" : "没有匹配的对话", icon: "bubble.left.and.bubble.right")
            } else {
                VStack(spacing: 0) {
                    ForEach(visible) { thread in
                        if let role = role(for: thread) {
                            WorkspaceConversationRow(thread: thread, role: role, studio: studio)
                            StudioRule()
                        }
                    }
                    if visible.count < threads.count {
                        Button("显示更多对话", systemImage: "chevron.down") {
                            visibleConversationCount = ConversationBatch.nextVisibleCount(
                                current: visibleConversationCount, total: threads.count)
                        }
                        .buttonStyle(QuietButton())
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                }
            }
        }
        .onChange(of: conversationQuery) { _, _ in
            visibleConversationCount = ConversationBatch.size
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
                let terminalRole = studio.linkedTerminalRole(for: terminalHome)
                TerminalRoleCard(home: terminalHome, role: terminalRole, store: studio.store,
                    open: { studio.withTerminalRole(from: terminalHome, perform: studio.select as (Role) -> Void) },
                    details: { terminalDetails(terminalHome) },
                    edit: { studio.withTerminalRole(from: terminalHome, perform: edit) },
                    editInstructions: { studio.withTerminalRole(from: terminalHome) { editFile($0, .soul) } })
                    .roleLibraryDragSource(terminalRole?.id)
            }
            ForEach(roles) { role in
                ManagementRoleCard(role: role, store: studio.store, conversationCount: studio.activeThreads(for: role.id).count,
                    open: { studio.select(role) }, details: { details(role) }, togglePin: { studio.togglePin(role) },
                    edit: { edit(role) }, editFile: { editFile(role, $0) }, archive: { studio.archiveRole(role) },
                    libraryGroups: libraryGroups, moveToGroup: { studio.moveRole(role.id, to: $0) })
                    .roleLibraryDragSource(role.id)
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
            if !studio.isGenerating(thread.id) { ConversationOrganizationActions(studio: studio, thread: thread) }
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
