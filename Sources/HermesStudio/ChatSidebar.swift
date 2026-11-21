import StudioCore
import SwiftUI
import UniformTypeIdentifiers

private struct ConversationDrag: Codable, Transferable {
    static let type = UTType(exportedAs: "com.hermesstudio.conversation")
    let id: UUID
    let roleID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: type)
    }
}

struct ChatSidebar: View {
    @ObservedObject var studio: StudioModel
    let createProject: (Role) -> Void
    @State private var projectsVisible = false
    @State private var expandedProjects: Set<UUID> = []
    @State private var projectsShowingAll: Set<UUID> = []
    @State private var targetedProject: UUID?
    @State private var showsSearch = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private let projectPreviewCount = 5

    private var recent: [Conversation] {
        let visibleProjects = projectsVisible ? expandedProjects : []
        return studio.threads.filter { thread in
            thread.pinnedAt == nil && (thread.projectID.map { !visibleProjects.contains($0) } ?? true)
        }
    }

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matchingThreads: [Conversation] { studio.threads.filter { $0.title.localizedCaseInsensitiveContains(searchTerm) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeading

            Button(action: studio.newConversation) {
                Label("新对话", systemImage: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioPalette.ink)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            }
            .buttonStyle(StudioRowButton())
            .help("新对话（⌘N）")
            .padding(.horizontal, 8)

            if let role = studio.role {
                RolePickerButton(roles: studio.roles, selected: role, store: studio.store,
                    select: studio.select as (Role) -> Void)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if searchTerm.isEmpty {
                        if !studio.pinnedThreads.isEmpty {
                            sectionHeader("已置顶") { EmptyView() }
                            ForEach(studio.pinnedThreads) { thread in threadRow(thread) }
                        }

                        sectionHeader("项目", expanded: $projectsVisible) {
                            StudioIconButton(title: "新建项目", symbol: "plus") {
                                if let role = studio.role {
                                    projectsVisible = true
                                    createProject(role)
                                }
                            }
                        }
                        .padding(.top, studio.pinnedThreads.isEmpty ? 0 : 9)
                        if projectsVisible {
                            ForEach(studio.projects) { project in projectGroup(project) }
                        }

                        if !recent.isEmpty {
                            sectionHeader("最近") { EmptyView() }.padding(.top, 9)
                            ForEach(recent) { thread in threadRow(thread) }
                        }
                    } else if matchingThreads.isEmpty {
                        Text("没有匹配的对话")
                            .font(.system(size: 11))
                            .foregroundStyle(StudioPalette.muted)
                            .padding(8)
                    } else {
                        ForEach(matchingThreads) { thread in threadRow(thread) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxHeight: .infinity)
        .background(StudioPalette.sidebar.opacity(0.68))
        .onChange(of: studio.roleID) { _, _ in
            projectsVisible = false
            expandedProjects = Set([studio.projectID].compactMap { $0 })
            projectsShowingAll = []
            targetedProject = nil
            query = ""
        }
        .onChange(of: studio.projectID, initial: true) { _, projectID in
            if let projectID { expandedProjects.insert(projectID) }
        }
    }

    private var sidebarHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(StudioBrand.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                StudioIconButton(title: showsSearch ? "关闭会话搜索" : "搜索当前角色的对话",
                    symbol: showsSearch ? "xmark" : "magnifyingglass") {
                    showsSearch.toggle()
                    if !showsSearch { query = "" }
                }
            }
            if showsSearch {
                TextField("搜索对话标题", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 6))
                    .focused($searchFocused)
                    .onAppear { searchFocused = true }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 39)
        .padding(.bottom, 6)
    }

    private func sectionHeader<Action: View>(_ title: String, expanded: Binding<Bool>? = nil,
        @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 0) {
            if let expanded {
                Button { expanded.wrappedValue.toggle() } label: {
                    HStack(spacing: 5) {
                        Text(title)
                        Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .padding(.trailing, 6)
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded.wrappedValue ? "已展开" : "已折叠")
            } else {
                Text(title).accessibilityAddTraits(.isHeader)
            }
            Spacer()
            action().padding(.trailing, 2)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(StudioPalette.muted)
        .padding(.leading, 8)
        .frame(height: 26)
    }

    private func projectGroup(_ project: StudioProject) -> some View {
        let expanded = expandedProjects.contains(project.id)
        let active = studio.projectID == project.id
        let threads = studio.threads.filter { $0.projectID == project.id && $0.pinnedAt == nil }
        let showsAll = projectsShowingAll.contains(project.id)
        let preview = Array(threads.prefix(projectPreviewCount))
        let selectedOutsidePreview = threads.dropFirst(projectPreviewCount).first { $0.id == studio.conversationID }
        let visible = showsAll ? threads : preview + [selectedOutsidePreview].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 2) {
            SidebarEntry(selected: active && studio.conversationID == nil, droppedOn: targetedProject == project.id) {
                if expanded { expandedProjects.remove(project.id) } else { expandedProjects.insert(project.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(active ? StudioPalette.ink : StudioPalette.muted)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(project.name).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StudioPalette.ink)
                        .lineLimit(1)
                }
                .padding(.leading, 8)
            } accessory: { hovered in
                if hovered {
                    StudioIconButton(title: "在\(project.name)中新建对话", symbol: "square.and.pencil") {
                        expandedProjects.insert(project.id)
                        studio.newConversation(in: project)
                    }
                }
            }
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            .contextMenu {
                Button("新对话", systemImage: "square.and.pencil") {
                    expandedProjects.insert(project.id)
                    studio.newConversation(in: project)
                }
                Button("在访达中打开", systemImage: "folder") { studio.openFolder(project) }
            }
            .dropDestination(for: ConversationDrag.self) { items, _ in
                guard items.count == 1, let item = items.first, item.roleID == studio.roleID else { return false }
                return moveThread(item.id, to: project)
            } isTargeted: { targeted in
                if targeted { targetedProject = project.id }
                else if targetedProject == project.id { targetedProject = nil }
            }

            if expanded {
                ForEach(visible) { thread in threadRow(thread, nested: true) }
                if threads.count > preview.count + (selectedOutsidePreview == nil ? 0 : 1) {
                    Button {
                        if showsAll { projectsShowingAll.remove(project.id) } else { projectsShowingAll.insert(project.id) }
                    } label: {
                        Text(showsAll ? "收起对话" : "显示更多")
                            .font(.system(size: 11))
                            .foregroundStyle(StudioPalette.muted)
                            .padding(.leading, 32)
                            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    }
                    .buttonStyle(StudioRowButton())
                }
            }
        }
    }

    private func moveThread(_ id: UUID, to project: StudioProject) -> Bool {
        guard studio.moveConversation(id, to: project) else { return false }
        expandedProjects.insert(project.id)
        return true
    }

    @ViewBuilder
    private func threadRow(_ thread: Conversation, nested: Bool = false) -> some View {
        let selected = studio.conversationID == thread.id
        let running = thread.id == studio.runningConversation
        let destinations = studio.projects.filter { $0.id != thread.projectID }
        let row = SidebarEntry(selected: selected) {
            studio.select(thread)
        } label: {
            Text(thread.title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? StudioPalette.ink : StudioPalette.muted)
                .lineLimit(1)
                .padding(.leading, nested ? 32 : 8)
        } accessory: { hovered in
            if running {
                ProgressView().controlSize(.mini)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("正在回复")
            } else if hovered {
                StudioIconButton(title: thread.pinnedAt == nil ? "置顶对话" : "取消置顶",
                    symbol: thread.pinnedAt == nil ? "pin" : "pin.slash") { studio.toggleConversationPin(thread) }
                StudioIconButton(title: "归档对话", symbol: "archivebox") {
                    studio.setConversationArchived(thread, archived: true)
                }
            }
        }
        if running {
            row
        } else {
            row
                .draggable(ConversationDrag(id: thread.id, roleID: thread.roleID))
                .contextMenu {
                    ConversationOrganizationActions(studio: studio, thread: thread)
                    if !destinations.isEmpty || thread.projectID != nil {
                        Menu("移动到") {
                            ForEach(destinations) { project in
                                Button(project.name, systemImage: "folder") { _ = moveThread(thread.id, to: project) }
                            }
                            if thread.projectID != nil {
                                Button("独立对话", systemImage: "bubble.left") { studio.moveConversation(thread.id, to: nil) }
                            }
                        }
                    }
                }
                .help(thread.title)
        }
    }
}

private struct SidebarEntry<Title: View, Accessory: View>: View {
    let selected: Bool
    var droppedOn = false
    let action: () -> Void
    @ViewBuilder let label: () -> Title
    @ViewBuilder let accessory: (Bool) -> Accessory
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                label()
                    .padding(.trailing, 6)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            accessory(hovered)
        }
        .padding(.trailing, 2)
        .background(fill, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private var fill: Color {
        if droppedOn { return StudioPalette.accent.opacity(0.18) }
        if selected { return StudioPalette.selected }
        return hovered ? StudioPalette.line : .clear
    }
}
