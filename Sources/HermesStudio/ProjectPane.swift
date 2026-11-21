import StudioCore
import SwiftUI
import UniformTypeIdentifiers

struct ProjectPane: View {
    @ObservedObject var studio: StudioModel
    let create: (Role) -> Void
    @State private var selectedRoleID: UUID?
    @State private var selectedID: UUID?

    private var selectedRole: Role? {
        studio.roles.first { $0.id == selectedRoleID } ?? studio.role ?? studio.roles.first
    }

    private var projects: [StudioProject] {
        selectedRole.map { studio.projects(for: $0.id) } ?? []
    }

    private var selected: StudioProject? {
        projects.first { $0.id == selectedID } ?? projects.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("项目").font(.system(size: 28, weight: .semibold))
                    Text("查看所选助手的项目和项目对话。")
                        .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                }
                Spacer()
                if let role = selectedRole {
                    Picker("所属助手", selection: Binding(get: { role.id }, set: { selectedRoleID = $0 })) {
                        ForEach(studio.roles) { role in
                            Text(role.name).tag(role.id)
                        }
                    }
                    .frame(width: 225)
                    Button { create(role) } label: { Label("新建项目", systemImage: "folder.badge.plus") }
                        .buttonStyle(QuietButton())
                }
            }
            if let selected {
                HStack(alignment: .top, spacing: 14) {
                    folders.frame(width: 188)
                    project(selected)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 25, weight: .light))
                        .foregroundStyle(StudioPalette.accent)
                    if let role = selectedRole {
                        Text("此助手暂无项目").font(.system(size: 16, weight: .semibold))
                        Text("你可以新建一个目录，也可以选择已有的代码或资料文件夹。")
                            .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                        Button("添加目录") { create(role) }.buttonStyle(QuietButton())
                    } else {
                        Text("创建助手后即可添加项目。").font(.system(size: 16, weight: .semibold))
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: selectedRole?.id) { _, _ in selectedID = nil }
        .onChange(of: projects.count) { _, _ in selectedID = projects.first?.id }
    }

    private var folders: some View {
        VStack(spacing: 5) {
            ForEach(projects) { project in
                Button { selectedID = project.id } label: {
                    Label(project.name, systemImage: project.id == selected?.id ? "folder.fill" : "folder")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(project.id == selected?.id ? StudioPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(project.id == selected?.id ? .isSelected : [])
            }
        }
        .padding(7)
        .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 10))
    }

    private func project(_ project: StudioProject) -> some View {
        let threads = studio.conversations[project.roleID, default: []].filter { $0.projectID == project.id }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(project.name).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Spacer()
                Button {
                    studio.startConversation(in: project)
                } label: {
                    Label("新建会话", systemImage: "plus.bubble")
                }
                .buttonStyle(QuietButton())
                .fixedSize()
            }
            Button { studio.openFolder(project) } label: {
                Label(project.path, systemImage: "folder")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(StudioPalette.muted)
            }
            .buttonStyle(.plain)
            .help("在访达中打开 \(project.path)")
            Rectangle().fill(StudioPalette.line).frame(height: 1)
            if threads.isEmpty {
                Text("此项目还没有会话。")
                    .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                    .padding(.vertical, 8)
            } else {
                ForEach(threads) { thread in
                    if let role = studio.roles.first(where: { $0.id == thread.roleID }) {
                        Button {
                            studio.select(role)
                            studio.select(thread)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "bubble.left").foregroundStyle(roleTint(role))
                                Text(thread.title).lineLimit(1)
                                Spacer()
                                Text(role.name).foregroundStyle(StudioPalette.muted)
                                Image(systemName: "chevron.right").font(.system(size: 8))
                            }
                            .font(.system(size: 12)).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProjectEditor: View {
    @ObservedObject var studio: StudioModel
    let role: Role
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directory: URL?
    @State private var chooseDirectory = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建项目").font(.system(size: 21, weight: .semibold))
            Label(role.name, systemImage: roleSymbol(role))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(StudioPalette.muted)
            TextField("项目名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("项目名称")
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(directory == nil ? "创建新目录" : "使用已有目录").font(.system(size: 12, weight: .semibold))
                    Text(directory?.path ?? "在此助手的项目文件夹中创建。")
                        .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                        .lineLimit(2)
                }
                Spacer()
                if directory != nil {
                    Button("清除", systemImage: "xmark") { directory = nil }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
                Button("选择文件夹…") { chooseDirectory = true }.buttonStyle(QuietButton())
            }
            .padding(10)
            .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(StudioPalette.accent) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton())
                Button("创建项目", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 485)
        .background(.regularMaterial)
        .fileImporter(isPresented: $chooseDirectory, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                directory = url
                if name.isEmpty { name = url.lastPathComponent }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        do {
            try studio.createProject(name: name, directory: directory, for: role.id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
