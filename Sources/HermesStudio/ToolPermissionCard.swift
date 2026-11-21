import StudioCore
import SwiftUI

struct ToolPermissionCard: View {
    let permission: ToolPermission
    let respond: (String?) -> Void

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

    private var allow: ToolPermission.Option? { permission.options.first { $0.kind == "allow_once" } }
    private var deny: ToolPermission.Option? { permission.options.first { $0.kind == "reject_once" } }
    private var otherOptions: [ToolPermission.Option] {
        permission.options.filter { $0.id != allow?.id && $0.id != deny?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Label(heading.0, systemImage: heading.1)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                evidence
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            StudioRule()
            actions
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .foregroundStyle(StudioPalette.ink)
        .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(StudioPalette.outline)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var evidence: some View {
        if let edit = permission.edit {
            PermissionFilePreview(edit: edit)
        } else {
            if permission.kind != "execute" || permission.title != permission.details {
                Text(permission.title)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if permission.kind != "clarify", let details = permission.details,
                permission.kind == "execute" || details != permission.title {
                PermissionContentPreview(text: details)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 7) {
            Button("取消请求") { respond(nil) }
                .buttonStyle(StudioRowButton())
                .font(.system(size: 11))
                .foregroundStyle(StudioPalette.muted)
                .padding(.horizontal, 3)
                .padding(.vertical, 4)
            Spacer(minLength: 4)
            if !otherOptions.isEmpty {
                Menu(allow == nil && deny == nil ? "选择回应" : "更多选项") {
                    ForEach(otherOptions) { option in
                        Button(optionLabel(option)) { respond(option.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let deny {
                Button(optionLabel(deny)) { respond(deny.id) }
                    .buttonStyle(QuietButton())
            }
            if let allow {
                StudioPrimaryButton(title: optionLabel(allow), symbol: "checkmark") { respond(allow.id) }
            }
        }
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

private struct PermissionFilePreview: View {
    private enum ViewMode: String, Hashable {
        case changes = "变更"
        case before = "修改前"
        case after = "修改后"
    }

    let edit: ToolPermission.Edit
    private let changes: [PermissionChangedLine]
    @State private var mode: ViewMode

    init(edit: ToolPermission.Edit) {
        self.edit = edit
        changes = PermissionChangedLine.preview(before: edit.before, after: edit.after)
        _mode = State(initialValue: changes.isEmpty ? .after : .changes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 3) {
                    Text((edit.path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(edit.path)
                        .font(.system(size: 10))
                        .foregroundStyle(StudioPalette.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .textSelection(.enabled)
                .help(edit.path)
                Spacer(minLength: 4)
                Picker("文件预览", selection: $mode) {
                    if !changes.isEmpty { Text(ViewMode.changes.rawValue).tag(ViewMode.changes) }
                    Text(ViewMode.before.rawValue).tag(ViewMode.before)
                    Text(ViewMode.after.rawValue).tag(ViewMode.after)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }
            switch mode {
            case .changes: diff
            case .before: PermissionContentPreview(text: edit.before ?? "原文件不存在")
            case .after: PermissionContentPreview(text: edit.after ?? "没有修改后的内容")
            }
        }
    }

    private var diff: some View {
        GeometryReader { bounds in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(changes) { line in
                        HStack(spacing: 8) {
                            Text("\(line.number)")
                                .frame(minWidth: 25, alignment: .trailing)
                                .foregroundStyle(StudioPalette.muted)
                            Text(line.added ? "+" : "−")
                                .foregroundStyle(line.color)
                                .accessibilityLabel(line.added ? "新增" : "移除")
                            Text(verbatim: String(line.value))
                                .foregroundStyle(StudioPalette.ink)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: max(0, bounds.size.width - 20), minHeight: 19, alignment: .leading)
                        .padding(.horizontal, 10)
                        .background(line.color.opacity(0.09))
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 5)
            }
        }
        .frame(height: CGFloat(min(changes.count, 6)) * 20 + 10)
        .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct PermissionChangedLine: Identifiable {
    let number: Int
    let added: Bool
    let value: Substring
    var id: Int { added ? number : -number }
    var color: Color { added ? StudioPalette.connected : Color(red: 0.90, green: 0.57, blue: 0.58) }

    static func preview(before: String?, after: String?) -> [Self] {
        guard before != nil || after != nil,
            (before?.utf8.count ?? 0) + (after?.utf8.count ?? 0) <= 240_000 else { return [] }
        let old = before.flatMap { $0.isEmpty ? nil : $0.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) } ?? []
        let new = after.flatMap { $0.isEmpty ? nil : $0.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) } ?? []
        guard old.count + new.count <= 1400 else { return [] }
        let edits = new.difference(from: old)
        let removals = Set(edits.removals.compactMap { if case .remove(let offset, _, _) = $0 { offset } else { nil } })
        let insertions = Set(edits.insertions.compactMap { if case .insert(let offset, _, _) = $0 { offset } else { nil } })
        var lines: [Self] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if removals.contains(oldIndex) {
                lines.append(Self(number: oldIndex + 1, added: false, value: old[oldIndex]))
                oldIndex += 1
            } else if insertions.contains(newIndex) {
                lines.append(Self(number: newIndex + 1, added: true, value: new[newIndex]))
                newIndex += 1
            } else {
                oldIndex += 1
                newIndex += 1
            }
        }
        return lines
    }
}

private struct PermissionContentPreview: View {
    let text: String

    var body: some View {
        GeometryReader { bounds in
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(8)
                    .frame(minWidth: bounds.size.width, minHeight: bounds.size.height, alignment: .topLeading)
            }
        }
        .frame(height: CGFloat(text.prefix(4000).split(omittingEmptySubsequences: false,
            whereSeparator: \.isNewline).prefix(6).count) * 15 + 18)
        .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
