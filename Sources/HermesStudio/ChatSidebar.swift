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
    let goHome: () -> Void
    let createProject: (Role) -> Void
    @State private var expandedProjects: Set<UUID> = []
    @State private var targetedProject: UUID?

    private var ungrouped: [Conversation] {
        let projectIDs = Set(studio.projects.map(\.id))
        return studio.threads.filter { thread in
            thread.projectID.map { !projectIDs.contains($0) } ?? true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: goHome) {
                WorkspaceNavLabel(title: "工作台", symbol: "square.grid.2x2")
            }
            .buttonStyle(StudioRowButton())
            .help("返回工作台（⌘1）")
            .padding(.horizontal, 8)

            StudioRule().padding(.horizontal, 12).padding(.vertical, 10)
            if let role = studio.role { roleHeader(role) }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionHeader("项目") {
                        StudioIconButton(title: "新建项目", symbol: "plus") {
                            if let role = studio.role { createProject(role) }
                        }
                    }
                    if studio.projects.isEmpty {
                        emptyLabel("暂无项目")
                    }
                    ForEach(studio.projects) { project in
                        projectGroup(project)
                    }

                    sectionHeader("独立对话") { EmptyView() }
                        .padding(.top, 11)
                    if ungrouped.isEmpty {
                        emptyLabel("暂无独立对话")
                    }
                    ForEach(ungrouped) { thread in
                        threadRow(thread)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .onChange(of: studio.roleID) { _, _ in
            expandedProjects = Set([studio.projectID].compactMap { $0 })
            targetedProject = nil
        }
        .onChange(of: studio.projectID, initial: true) { _, projectID in
            if let projectID { expandedProjects.insert(projectID) }
        }
    }

    private func roleHeader(_ role: Role) -> some View {
        HStack(spacing: 7) {
            RolePortrait(role: role, store: studio.store, size: 21)
            Menu {
                ForEach(studio.roles) { candidate in
                    Button(candidate.name, systemImage: candidate.id == role.id ? "checkmark" : roleSymbol(candidate)) {
                        if candidate.id != role.id { studio.select(candidate) }
                    }
                }
            } label: {
                Text(role.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("当前角色 \(role.name)，切换角色")
            Spacer(minLength: 2)
            StudioIconButton(title: "新对话", symbol: "square.and.pencil", action: studio.newConversation)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.bottom, 9)
    }

    private func sectionHeader<Action: View>(_ title: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 0) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioPalette.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            action()
        }
        .padding(.leading, 8)
        .frame(height: 27)
    }

    private func emptyLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(StudioPalette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }

    private func projectGroup(_ project: StudioProject) -> some View {
        let expanded = expandedProjects.contains(project.id)
        let active = studio.projectID == project.id
        let threads = studio.threads.filter { $0.projectID == project.id }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    if expanded { expandedProjects.remove(project.id) } else { expandedProjects.insert(project.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .frame(width: 9)
                            .foregroundStyle(StudioPalette.muted)
                        Image(systemName: "folder")
                            .foregroundStyle(active ? StudioPalette.accent : StudioPalette.muted)
                        Text(project.name)
                            .lineLimit(1)
                            .foregroundStyle(StudioPalette.ink)
                    }
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                    .padding(.leading, 7)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                }
                .buttonStyle(StudioRowButton())
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                .contextMenu { Button("在访达中打开") { studio.openFolder(project) } }

                StudioIconButton(title: "在\(project.name)中新建对话", symbol: "plus") {
                    expandedProjects.insert(project.id)
                    studio.newConversation(in: project)
                }
            }
            .background(targetedProject == project.id ? StudioPalette.accent.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
            .dropDestination(for: ConversationDrag.self) { items, _ in
                guard items.count == 1, let item = items.first, item.roleID == studio.roleID else { return false }
                return moveThread(item.id, to: project)
            } isTargeted: { targeted in
                if targeted { targetedProject = project.id }
                else if targetedProject == project.id { targetedProject = nil }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    if threads.isEmpty { emptyLabel("暂无项目对话") }
                    ForEach(threads) { thread in threadRow(thread) }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(StudioPalette.line)
                        .frame(width: 1)
                        .allowsHitTesting(false)
                }
                .padding(.leading, 11)
            }
        }
    }

    private func moveThread(_ id: UUID, to project: StudioProject) -> Bool {
        guard studio.moveConversation(id, to: project) else { return false }
        expandedProjects.insert(project.id)
        return true
    }

    @ViewBuilder
    private func threadRow(_ thread: Conversation) -> some View {
        let selected = studio.conversationID == thread.id
        let row = Button { studio.select(thread) } label: {
            HStack(spacing: 0) {
                WorkspaceNavLabel(title: thread.title, symbol: "bubble.left", selected: selected)
                if thread.id == studio.runningConversation {
                    ProgressView().controlSize(.mini).padding(.trailing, 7)
                }
            }
        }
        .buttonStyle(StudioRowButton(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])

        if thread.id == studio.runningConversation || (studio.projects.isEmpty && thread.projectID == nil) {
            row
        } else {
            row
                .draggable(ConversationDrag(id: thread.id, roleID: thread.roleID))
                .contextMenu {
                    Menu("移动到") {
                        ForEach(studio.projects.filter { $0.id != thread.projectID }) { project in
                            Button(project.name, systemImage: "folder") { _ = moveThread(thread.id, to: project) }
                        }
                        if thread.projectID != nil {
                            Button("独立对话", systemImage: "bubble.left") { studio.moveConversation(thread.id, to: nil) }
                        }
                    }
                }
                .help(thread.title)
        }
    }
}
