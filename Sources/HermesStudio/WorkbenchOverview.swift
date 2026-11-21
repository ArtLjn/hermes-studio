import StudioCore
import SwiftUI

struct WorkbenchOverview: View {
    @ObservedObject var studio: StudioModel
    let roles: [Role]
    let create: () -> Void
    let openRoles: () -> Void
    let openProjects: () -> Void
    let openHistory: () -> Void
    @State private var preferredRoleID: UUID?
    @State private var preferTerminal = false

    private var recent: [(thread: Conversation, role: Role)] {
        studio.recentThreads.compactMap { thread in
            studio.roles.first { $0.id == thread.roleID }.map { (thread, $0) }
        }
    }

    private var selectedRole: Role? {
        if preferTerminal, studio.terminalHome != nil { return nil }
        return studio.roles.first { $0.id == preferredRoleID }
            ?? recent.first?.role
            ?? roles.first
            ?? studio.terminalHome.flatMap { studio.linkedTerminalRole(for: $0) }
    }

    private var terminalShortcut: URL? {
        studio.terminalHome.flatMap { studio.linkedTerminalRole(for: $0) == nil ? $0 : nil }
    }

    private var projects: [StudioProject] {
        studio.roles.flatMap { studio.projects(for: $0.id) }.sorted { $0.created > $1.created }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack {
                Text("工作台")
                    .font(.system(size: 28, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("创建角色", systemImage: "plus", action: create)
                    .buttonStyle(QuietButton())
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            startBar
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 26) {
                    recentList(limit: 6).frame(minWidth: 340, maxWidth: .infinity)
                    workspaceLists.frame(width: 257)
                }
                VStack(alignment: .leading, spacing: 24) {
                    recentList(limit: 4)
                    workspaceLists
                }
            }
        }
    }

    private var startBar: some View {
        HStack(spacing: 13) {
            if selectedRole != nil || terminalShortcut != nil {
                Text("对话角色")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioPalette.muted)
                rolePicker
                Spacer(minLength: 5)
                StudioPrimaryButton(title: "新对话", symbol: "square.and.pencil", action: startConversation)
            } else {
                Text("创建角色后即可发起对话")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.muted)
                Spacer(minLength: 5)
                StudioPrimaryButton(title: "创建角色", symbol: "plus", action: create)
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 54)
        .background(StudioPalette.sidebar.opacity(0.66), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(StudioPalette.line).allowsHitTesting(false)
        }
    }

    private var rolePicker: some View {
        HStack(spacing: 5) {
            if let role = selectedRole {
                RolePortrait(role: role, store: studio.store, size: 19)
            } else {
                Image(systemName: "terminal").foregroundStyle(StudioPalette.muted)
            }
            Menu {
                ForEach(studio.roles) { role in
                    Button(role.name, systemImage: selectedRole?.id == role.id ? "checkmark" : roleSymbol(role)) {
                        preferredRoleID = role.id
                        preferTerminal = false
                    }
                }
                if terminalShortcut != nil {
                    Button("终端 Hermes", systemImage: preferTerminal ? "checkmark" : "terminal") { preferTerminal = true }
                }
            } label: {
                Text(selectedRole?.name ?? "终端 Hermes")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("选择对话角色")
            .accessibilityValue(selectedRole?.name ?? "终端 Hermes")
        }
        .frame(maxWidth: 144)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func startConversation() {
        if let role = selectedRole {
            openNewConversation(role)
        } else if let terminalShortcut {
            studio.withTerminalRole(from: terminalShortcut, perform: openNewConversation)
        }
    }

    private func openNewConversation(_ role: Role) {
        studio.select(role)
        if studio.conversationID != nil {
            studio.newConversation()
            studio.chooseProject(nil)
        }
    }

    private func recentList(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("最近对话", actionTitle: "全部对话", action: openHistory)
            if recent.isEmpty {
                empty("发起对话后，会显示在这里。")
            } else {
                ForEach(recent.prefix(limit), id: \.thread.id) { item in
                    WorkspaceConversationRow(thread: item.thread, role: item.role, studio: studio)
                    StudioRule()
                }
            }
        }
    }

    private var workspaceLists: some View {
        let availableProjects = projects
        let projectsByName = Dictionary(grouping: availableProjects, by: \.name)
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("我的角色", actionTitle: "角色库", action: openRoles)
                if let home = studio.terminalHome {
                    let role = studio.linkedTerminalRole(for: home)
                    shortcut(title: role?.name ?? "终端 Hermes", detail: "本机角色", portrait: {
                        if let role { RolePortrait(role: role, store: studio.store, size: 24) }
                        else { RolePortrait(image: nil, symbol: "terminal", size: 24) }
                    }) {
                        studio.withTerminalRole(from: home, perform: studio.select as (Role) -> Void)
                    }
                }
                ForEach(roles.prefix(4)) { role in
                    shortcut(title: role.name, detail: role.summary, portrait: {
                        RolePortrait(role: role, store: studio.store, size: 24)
                    }) { studio.select(role) }
                }
                if roles.isEmpty && studio.terminalHome == nil { empty("暂无角色") }
            }
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("项目", actionTitle: "全部项目", action: openProjects)
                if availableProjects.isEmpty {
                    empty("暂无项目")
                } else {
                    ForEach(availableProjects.prefix(4)) { project in
                        let owner = studio.roles.first { $0.id == project.roleID }?.name ?? ""
                        let sharesName = (projectsByName[project.name]?.count ?? 0) > 1
                        let detail = sharesName ? "\(owner) · \(project.directory.deletingLastPathComponent().lastPathComponent)" : owner
                        shortcut(title: project.name, detail: detail, portrait: {
                                Image(systemName: "folder").font(.system(size: 13))
                                    .foregroundStyle(StudioPalette.muted).frame(width: 24)
                            }) { studio.startConversation(in: project) }
                            .help(project.path)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
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
            StudioRule()
        }
    }

    private func empty(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(StudioPalette.muted)
            .padding(.vertical, 14)
    }

    private func shortcut<Portrait: View>(title: String, detail: String, @ViewBuilder portrait: () -> Portrait,
        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                portrait()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(StudioPalette.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 5)
            .frame(height: 43)
        }
        .buttonStyle(StudioRowButton())
    }
}
