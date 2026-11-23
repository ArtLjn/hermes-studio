import StudioCore
import SwiftUI

func roleTint(_ role: Role) -> Color {
    switch role.template {
    case .general: StudioPalette.accent
    case .engineering: Color(red: 0.58, green: 0.78, blue: 0.80)
    case .writing: Color(red: 0.75, green: 0.79, blue: 0.92)
    case .blank: StudioPalette.muted
    }
}

struct ManagementRoleCard: View {
    let role: Role
    let store: RoleStore
    let conversationCount: Int
    let open: () -> Void
    let details: () -> Void
    let togglePin: () -> Void
    let edit: () -> Void
    let editFile: (RoleFile) -> Void
    let archive: () -> Void
    let libraryGroups: [String]
    let moveToGroup: (String?) -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    RolePortrait(role: role, store: store, size: 36)
                    Text(role.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    if role.pinned == true {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(StudioPalette.muted)
                            .accessibilityLabel("已置顶")
                    }
                }
                .padding(.trailing, 22)
                Text(role.summary.isEmpty ? "尚未填写简介" : role.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 29, alignment: .topLeading)
                    .padding(.top, 11)
                Rectangle().fill(StudioPalette.line).frame(height: 1)
                    .padding(.vertical, 10)
                HStack {
                    Label("\(conversationCount) 个对话", systemImage: "bubble.left")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(StudioPalette.muted)
                    Spacer()
                    Text("进入对话")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .padding(15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("进入\(role.name)的对话")
        .accessibilityValue("\(conversationCount) 个对话" + (role.pinned == true ? "，已置顶" : ""))
        .background(hovered ? StudioPalette.selected : StudioPalette.raised, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(hovered ? StudioPalette.outline : StudioPalette.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("详细信息", systemImage: "info.circle", action: details)
                Button(role.pinned == true ? "取消置顶" : "置顶角色", systemImage: role.pinned == true ? "pin.slash" : "pin",
                    action: togglePin)
                Divider()
                Button("编辑角色资料", action: edit)
                if !libraryGroups.isEmpty {
                    Menu("移到分组") {
                        Button("未分组") { moveToGroup(nil) }.disabled(role.libraryGroup == nil)
                        Divider()
                        ForEach(libraryGroups, id: \.self) { group in
                            Button(group) { moveToGroup(group) }.disabled(role.libraryGroup == group)
                        }
                    }
                }
                ForEach(RoleFile.allCases) { file in
                    Button("编辑\(file.label)") { editFile(file) }
                }
                if role.terminalSource == nil {
                    Divider()
                    Button("移到草稿箱", systemImage: "trash", role: .destructive, action: archive)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 27, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("管理\(role.name)")
            .padding(12)
        }
        .onHover { hovered = $0 }
    }
}
