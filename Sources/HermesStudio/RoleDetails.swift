import AppKit
import StudioCore
import SwiftUI

struct RoleDetails: View {
    @ObservedObject var studio: StudioModel
    let role: Role?
    let home: URL
    let edit: ((Role) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var files: [RoleFile: String] = [:]
    @State private var displayedFile = RoleFile.memory
    @State private var error: String?

    private var terminal: Bool { role == nil }
    private var displayedRole: Role? { role ?? studio.linkedTerminalRole(for: home) }
    private var title: String { displayedRole?.name ?? "终端 Hermes" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                if let displayedRole {
                    RolePortrait(role: displayedRole, store: studio.store, size: 38)
                } else {
                    RolePortrait(image: nil, symbol: "terminal", size: 38)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 21, weight: .semibold))
                    Text(terminal ? "终端配置与记忆 · 只读" : "桌面角色 · 独立记忆")
                        .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                }
                Spacer()
                Button("在访达中打开", systemImage: "folder") { NSWorkspace.shared.open(home) }
                    .buttonStyle(QuietButton())
            }
            VStack(alignment: .leading, spacing: 8) {
                pathRow("配置目录", home.path)
                pathRow("配置文件", home.appendingPathComponent("config.yaml").path)
                if let role {
                    pathRow("角色技能", role.skillIDs.map { "仅启用所选（\($0.count)）" } ?? "继承本机技能")
                } else if let linked = studio.linkedTerminalRole(for: home) {
                    pathRow("桌面目录", studio.store.runtime(for: linked.id).path)
                }
            }
            .padding(12).background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 9))
            Picker("角色文件", selection: $displayedFile) {
                ForEach(RoleFile.allCases) { file in Text(file.label).tag(file) }
            }
            .pickerStyle(.segmented)
            ScrollView {
                let content = files[displayedFile, default: ""]
                Text(content.isEmpty ? "此文件暂无内容。" : content)
                    .font(.system(size: 12))
                    .foregroundStyle(content.isEmpty ? StudioPalette.muted : StudioPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(11)
            }
            .frame(height: 215)
            .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 9))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(StudioPalette.accent) }
            HStack(spacing: 9) {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton())
                Spacer()
                if let role {
                    if let edit {
                        Button("编辑资料与技能") { edit(role) }.buttonStyle(QuietButton())
                    }
                    Button("进入对话", systemImage: "arrow.up.right") {
                        dismiss()
                        studio.select(role)
                    }
                    .buttonStyle(QuietButton())
                } else {
                    Button("创建独立副本", systemImage: "plus.rectangle.on.rectangle", action: copy)
                        .buttonStyle(QuietButton())
                        .help("将角色指令和当前记忆复制到一个新的桌面角色。")
                    Button("进入对话", systemImage: "arrow.up.right", action: openTerminalChat)
                        .buttonStyle(QuietButton())
                }
            }
        }
        .padding(22).frame(width: 625)
        .background(.regularMaterial)
        .onAppear(perform: load)
    }

    private func pathRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 11, weight: .semibold)).frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(StudioPalette.muted)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() {
        for file in RoleFile.allCases {
            do { files[file] = try RoleStore.readFile(file, in: home) }
            catch { self.error = "无法读取\(file.label)：\(error.localizedDescription)" }
        }
    }

    private func copy() {
        do {
            let role = try studio.copyTerminalRole(from: home)
            dismiss()
            studio.select(role)
        } catch { self.error = error.localizedDescription }
    }

    private func openTerminalChat() {
        do {
            let role = try studio.terminalChatRole(from: home)
            dismiss()
            studio.select(role)
        } catch { self.error = error.localizedDescription }
    }
}

struct TerminalRoleCard: View {
    let home: URL
    let role: Role?
    let store: RoleStore
    let open: () -> Void
    let details: () -> Void
    let edit: () -> Void
    let editInstructions: () -> Void

    private var title: String { role?.name ?? "终端 Hermes" }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    if let role {
                        RolePortrait(role: role, store: store, size: 36)
                    } else {
                        RolePortrait(image: nil, symbol: "terminal", size: 36)
                    }
                    Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Spacer()
                }
                .padding(.trailing, 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(home.path).font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    if let role, !role.summary.isEmpty {
                        Text(role.summary).font(.system(size: 11)).lineLimit(1)
                    }
                }
                .foregroundStyle(StudioPalette.muted)
                .frame(maxWidth: .infinity, minHeight: 29, alignment: .topLeading)
                Rectangle().fill(StudioPalette.line).frame(height: 1)
                HStack {
                    Spacer()
                    Text("进入对话").font(.system(size: 11, weight: .semibold))
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium))
                }
            }
            .padding(15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("进入\(title)的对话")
        .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(StudioPalette.line).allowsHitTesting(false) }
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("详细信息", systemImage: "info.circle", action: details)
                Divider()
                Button("编辑角色资料", action: edit)
                Button("编辑角色指令", action: editInstructions)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                    .frame(width: 27, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("管理\(title)")
            .padding(12)
        }
    }
}
