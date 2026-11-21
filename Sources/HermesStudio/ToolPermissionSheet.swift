import StudioCore
import SwiftUI

struct ToolPermissionSheet: View {
    let permission: ToolPermission
    let respond: (String?) -> Void
    @State private var showsOriginal = false

    private var heading: (String, String) {
        switch permission.kind {
        case "execute": ("允许运行这条命令？", "terminal")
        case "edit": ("允许修改这个文件？", "doc.badge.gearshape")
        case "delete": ("允许删除这些内容？", "trash")
        case "move": ("允许移动这些内容？", "folder")
        case "read": ("允许读取这些内容？", "doc.text")
        case "fetch": ("允许访问这个网络资源？", "globe")
        case "clarify": ("Hermes 需要你的选择", "questionmark.bubble")
        default: ("允许 Hermes 执行这项操作？", "hand.raised")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(heading.0, systemImage: heading.1)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let edit = permission.edit {
                Text(edit.path).font(.subheadline).textSelection(.enabled)
                Picker("文件内容", selection: $showsOriginal) {
                    Text("修改后").tag(false)
                    Text("修改前").tag(true)
                }
                .pickerStyle(.segmented)
                preview(showsOriginal ? (edit.before ?? "原文件不存在") : (edit.after ?? "没有修改后的内容"))
            } else {
                if permission.kind != "execute" || permission.title != permission.details {
                    Text(permission.title)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .frame(maxHeight: 125, alignment: .topLeading)
                }
                if permission.kind != "clarify", let details = permission.details,
                    permission.kind == "execute" || details != permission.title {
                    preview(details)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(permission.options) { option in
                        Button { respond(option.id) } label: {
                            Text(optionLabel(option))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxHeight: CGFloat(min(permission.options.count, 6)) * 34)
            Button("取消请求") { respond(nil) }
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 510)
    }

    private func preview(_ value: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 110)
        .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 6))
    }

    private func optionLabel(_ option: ToolPermission.Option) -> String {
        switch option.id {
        case "allow_once": "仅允许这一次"
        case "allow_session": "本次会话允许"
        case "allow_always": "始终允许"
        case "deny": "拒绝"
        case "deny_always": "始终拒绝"
        case "skip": "跳过"
        default: option.name
        }
    }
}
