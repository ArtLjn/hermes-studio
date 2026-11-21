import StudioCore
import SwiftUI

struct StudioWindow: View {
    @ObservedObject var studio: StudioModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("studio.showRoleSidebar") private var showSidebar = true
    @AppStorage("studio.showInspector") private var showInspector = true
    @State private var sheet: StudioSheet?
    @State private var managementPage = ManagementPage.overview

    private var panelAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.20) }
    private var sidebarAction: () -> Void { { showSidebar.toggle() } }
    private var sidebarLabel: String { showSidebar ? "收起侧栏" : "展开侧栏" }
    private var toolbarLeading: CGFloat { showSidebar ? 14 : 78 }

    var body: some View {
        GeometryReader { layout in
            let showInlineInspector = layout.size.width >= (showSidebar ? 1070 : 910)
            HStack(spacing: 0) {
                sidePanel(width: StudioPalette.sidebarWidth, edge: .leading, isOpen: showSidebar) {
                    WorkspaceSidebar(studio: studio) {
                        if studio.showManagement {
                            managementNavigation
                        } else {
                            ChatSidebar(studio: studio, goHome: studio.goHome, createProject: { sheet = .project($0) })
                        }
                    }
                }
                if studio.showManagement {
                    ManagementPane(studio: studio, page: $managementPage, sidebarVisible: showSidebar, toolbarLeading: toolbarLeading,
                        sidebarLabel: sidebarLabel, toggleSidebar: sidebarAction,
                        create: { sheet = .create }, edit: { sheet = .edit($0) }, details: { sheet = .details($0) },
                        terminalDetails: { sheet = .terminal($0) }, editFile: { sheet = .file($0, $1) },
                        createProject: { sheet = .project($0) }, openDraftBox: { sheet = .draftBox })
                } else {
                    VStack(spacing: 0) {
                        header(showInlineInspector: showInlineInspector)
                        StudioRule()
                        ChatPane(studio: studio)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInlineInspector, let role = studio.role {
                        sidePanel(width: 276, edge: .trailing, isOpen: showInspector) { inspector(role) }
                    }
                }
            }
        }
        .background { WallpaperSurface() }
        .foregroundStyle(StudioPalette.ink)
        .tint(StudioPalette.accent)
        .ignoresSafeArea()
        .onChange(of: studio.showManagement) { _, showing in
            if showing { managementPage = .overview }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .create:
                RoleEditor(studio: studio, role: nil)
            case .edit(let role):
                RoleEditor(studio: studio, role: role)
            case .file(let role, let file):
                MemoryEditor(studio: studio, role: role, file: file)
            case .inspect(let role):
                inspector(role)
                    .frame(width: 420, height: 590)
            case .details(let role):
                RoleDetails(studio: studio, role: role, home: studio.store.runtime(for: role.id), edit: { self.sheet = .edit($0) })
            case .terminal(let home):
                RoleDetails(studio: studio, role: nil, home: home, edit: nil)
            case .project(let role):
                ProjectEditor(studio: studio, role: role)
            case .draftBox:
                RoleDraftBox(studio: studio)
            }
        }
    }

    private func sidePanel<Content: View>(width: CGFloat, edge: HorizontalEdge, isOpen: Bool,
        @ViewBuilder content: () -> Content) -> some View {
        let besideChat: Alignment = edge == .leading ? .trailing : .leading
        return content()
            .frame(width: width)
            .padding(edge == .leading ? .trailing : .leading, 1)
            .overlay(alignment: besideChat) { Rectangle().fill(StudioPalette.line).frame(width: 1) }
            .frame(width: isOpen ? width + 1 : 0, alignment: besideChat)
            .clipped()
            .contentShape(Rectangle())
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
            .animation(panelAnimation, value: isOpen)
    }

    private var managementNavigation: some View {
        VStack(spacing: 3) {
            ForEach(ManagementPage.allCases, id: \.self) { page in
                let selected = page == managementPage
                Button { managementPage = page } label: {
                    WorkspaceNavLabel(title: page.rawValue, symbol: page.icon, selected: selected)
                }
                .buttonStyle(StudioRowButton(selected: selected))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
    }

    private func header(showInlineInspector: Bool) -> some View {
        HStack(spacing: 9) {
            StudioIconButton(title: sidebarLabel, symbol: "sidebar.left", action: sidebarAction)
            if !showSidebar {
                StudioIconButton(title: "返回工作台", symbol: "arrow.left", action: studio.goHome)
                if let role = studio.role {
                    Text(role.name).lineLimit(1).foregroundStyle(StudioPalette.muted)
                    breadcrumbSeparator
                }
            }
            if let project = studio.project {
                Button { studio.openFolder(project) } label: {
                    Label(project.name, systemImage: "folder")
                        .lineLimit(1)
                        .foregroundStyle(StudioPalette.muted)
                }
                .buttonStyle(.plain)
                .help(project.path)
                breadcrumbSeparator
            }
            Text(studio.conversation?.title ?? "新对话")
                .fontWeight(.semibold)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 5)
            Button(action: studio.newConversation) {
                Label("新对话", systemImage: "square.and.pencil")
            }
            .buttonStyle(QuietButton())
            .fixedSize()
            StudioIconButton(title: showInlineInspector ? (showInspector ? "收起角色与记忆" : "展开角色与记忆") : "角色与记忆",
                symbol: "sidebar.right") {
                if showInlineInspector {
                    showInspector.toggle()
                } else if let role = studio.role {
                    sheet = .inspect(role)
                }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, toolbarLeading)
        .padding(.trailing, 15)
        .frame(height: StudioPalette.toolbarHeight)
    }

    private var breadcrumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(StudioPalette.muted)
            .accessibilityHidden(true)
    }

    private func inspector(_ role: Role) -> some View {
        RoleInspector(studio: studio, role: role, onEdit: { sheet = .edit(role) },
            onDetails: { sheet = .details(role) },
            onEditFile: { sheet = .file(role, $0) })
            .id(role.id)
    }
}

enum StudioSheet: Identifiable {
    case create, edit(Role), file(Role, RoleFile), inspect(Role), details(Role), terminal(URL), project(Role), draftBox

    var id: String {
        switch self {
        case .create: "create"
        case .project(let role): "project-\(role.id)"
        case .draftBox: "draft-box"
        case .edit(let role): "edit-\(role.id)"
        case .file(let role, let file): "file-\(role.id)-\(file)"
        case .inspect(let role): "inspect-\(role.id)"
        case .details(let role): "details-\(role.id)"
        case .terminal(let url): "terminal-\(url.path)"
        }
    }
}

func roleSymbol(_ role: Role) -> String {
    if role.terminalSource != nil { return "terminal" }
    return role.template == .blank ? "circle.hexagongrid" : role.template.symbol
}

