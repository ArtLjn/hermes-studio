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
    private var showsConversationSidebar: Bool { !studio.showManagement && showSidebar }
    private var toolbarLeading: CGFloat { showsConversationSidebar ? 14 : 78 - StudioPalette.sidebarRailWidth }

    var body: some View {
        GeometryReader { layout in
            let showInlineInspector = layout.size.width >=
                (showsConversationSidebar ? 1070 : 910) + StudioPalette.sidebarRailWidth
            HStack(spacing: 0) {
                sidePanel(width: StudioPalette.sidebarRailWidth, edge: .leading, isOpen: true) {
                    sidebarRail
                }
                if !studio.showManagement {
                    sidePanel(width: StudioPalette.sidebarWidth, edge: .leading, isOpen: showSidebar) {
                        ChatSidebar(studio: studio, createProject: { sheet = .project($0) })
                    }
                }
                if studio.showManagement {
                    ManagementPane(studio: studio, page: $managementPage, toolbarLeading: toolbarLeading,
                        create: { sheet = .create }, edit: { sheet = .edit($0) }, details: { sheet = .details($0) },
                        terminalDetails: { sheet = .terminal($0) }, editFile: { sheet = .file($0, $1) },
                        createProject: { sheet = .project($0) })
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
            if !showing { managementPage = .overview }
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

    private var sidebarRail: some View {
        VStack(spacing: 5) {
            if !studio.showManagement {
                railButton(showSidebar ? "收起侧栏" : "展开侧栏", symbol: "sidebar.left") {
                    showSidebar.toggle()
                }
                .padding(.bottom, 4)
            }
            ForEach(ManagementPage.destinations, id: \.self) { page in
                railButton(page.rawValue, symbol: page.icon,
                    selected: (studio.showManagement ? managementPage.navigationRoot : .overview) == page) {
                    openManagement(page)
                }
            }
            if !studio.showManagement && !showSidebar {
                StudioRule().padding(.horizontal, 12).padding(.vertical, 4)
                railButton("新对话", symbol: "square.and.pencil", action: studio.newConversation)
                if let role = studio.role { SidebarRoleMenu(studio: studio, role: role, compact: true) }
            }
            Spacer(minLength: 8)
            HermesStatusButton(studio: studio)
                .padding(.bottom, 6)
        }
        .padding(.top, 37)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioPalette.sidebar.opacity(0.68))
    }

    private func railButton(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? StudioPalette.ink : StudioPalette.muted)
                .frame(width: 36, height: 34)
        }
        .buttonStyle(StudioRowButton(selected: selected))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }

    private func openManagement(_ page: ManagementPage) {
        managementPage = page
        if !studio.showManagement { studio.goHome() }
    }

    private func header(showInlineInspector: Bool) -> some View {
        HStack(spacing: 9) {
            if !showSidebar {
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
    case create, edit(Role), file(Role, RoleFile), inspect(Role), details(Role), terminal(URL), project(Role)

    var id: String {
        switch self {
        case .create: "create"
        case .project(let role): "project-\(role.id)"
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

