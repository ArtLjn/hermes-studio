import StudioCore
import SwiftUI

struct RoleInspector: View {
    @ObservedObject var studio: StudioModel
    let role: Role
    let onEdit: () -> Void
    let onDetails: () -> Void
    let onEditFile: (RoleFile) -> Void
    @State private var tab: Tab = .profile

    enum Tab: String, CaseIterable {
        case profile = "角色设定"
        case memories = "独立记忆"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("角色与记忆")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onEdit) {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(QuietButton())
                .help("编辑角色资料")
                .accessibilityLabel("编辑角色资料")
            }
            .frame(height: StudioPalette.toolbarHeight)
            .padding(.horizontal, 17)
            StudioRule()

            HStack(spacing: 3) {
                ForEach(Tab.allCases, id: \.self) { choice in
                    Button {
                        tab = choice
                    } label: {
                        Text(choice.rawValue)
                            .font(.system(size: 12, weight: tab == choice ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .frame(height: 29)
                            .foregroundStyle(tab == choice ? StudioPalette.ink : StudioPalette.muted)
                            .background(tab == choice ? StudioPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == choice ? .isSelected : [])
                }
            }
            .padding(3)
            .background(StudioPalette.background, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 17)
            .padding(.top, 17)
            .padding(.bottom, 19)

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if tab == .profile {
                        HStack(alignment: .top, spacing: 12) {
                            RolePortrait(role: role, store: studio.store, size: 44)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11)
                                        .strokeBorder(roleTint(role).opacity(0.45), lineWidth: 1)
                                        .allowsHitTesting(false)
                                }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(role.name).font(.system(size: 18, weight: .semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)
                                if !role.summary.isEmpty {
                                    Text(role.summary)
                                        .font(.system(size: 12))
                                        .foregroundStyle(StudioPalette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.top, 2)
                        }
                        Divider().overlay(StudioPalette.line)
                        Button("查看角色与配置目录", systemImage: "folder", action: onDetails)
                            .buttonStyle(QuietButton())
                        fileCard(.soul, empty: "还没有角色指令。")
                        Button {
                            tab = .memories
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "books.vertical")
                                    .foregroundStyle(StudioPalette.accent)
                                Text("查看独立记忆")
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(11)
                            .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    } else {
                        fileCard(.memory, empty: "尚未保存长期记忆。")
                        fileCard(.user, empty: "尚未保存用户偏好。")
                    }
                }
                .padding(.horizontal, 17)
                .padding(.bottom, 17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: studio.openData) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text("打开角色数据目录")
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                }
                .font(.system(size: 11))
                .foregroundStyle(StudioPalette.muted)
                .padding(.horizontal, 18)
                .frame(height: 43)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(StudioPalette.line).frame(height: 1) }
        }
        .background(StudioPalette.sidebar.opacity(0.82))
    }

    private func fileCard(_ file: RoleFile, empty: String) -> some View {
        let contents = studio.roleFiles[file, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(file.label)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { onEditFile(file) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 23)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("编辑\(file.label)")
                .accessibilityLabel("编辑\(file.label)")
            }
            Text(contents.isEmpty ? empty : contents)
                .font(.system(size: 12))
                .foregroundStyle(contents.isEmpty ? StudioPalette.muted : StudioPalette.ink.opacity(0.86))
                .lineSpacing(4)
                .lineLimit(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Text(file.rawValue.split(separator: "/").last.map(String.init) ?? file.rawValue)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(StudioPalette.muted)
                .padding(.top, 3)
        }
        .padding(12)
        .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }
}
