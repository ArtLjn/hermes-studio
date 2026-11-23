import StudioCore
import SwiftUI

struct ToolPermissionCard: View {
    let permission: ToolPermission
    let editPolicy: String?
    let workspace: URL?
    let workspaceName: String
    let stop: () -> Void
    let respond: (String) -> Void
    @State private var showsOtherOptions = false
    @State private var clarificationHeight: CGFloat?

    private let maximumClarificationHeight: CGFloat = 178

    private var isClarification: Bool { permission.kind == "clarify" }

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

    private var allow: ToolPermission.Option? {
        isClarification ? nil : permission.options.first { $0.kind == "allow_once" }
    }
    private var deny: ToolPermission.Option? { permission.options.first { $0.kind == "reject_once" } }
    private var sessionAllow: ToolPermission.Option? {
        permission.options.first { $0.id == "allow_session" }
    }
    private var otherOptions: [ToolPermission.Option] {
        permission.options.filter { $0.id != allow?.id && $0.id != deny?.id && $0.id != sessionAllow?.id }
    }
    private var skip: ToolPermission.Option? {
        permission.options.first { $0.id == "skip" } ?? deny
    }
    private var clarificationOptions: [ToolPermission.Option] {
        permission.options.filter { $0.id != skip?.id }
    }

    private var scopeNote: String? {
        guard permission.kind == "edit" else { return nil }
        switch editPolicy {
        case "workspace_session", "accept_edits":
            if let workspace, let path = permission.edit?.path, path.hasPrefix("/"),
                !path.contains(", "), !path.contains(where: \.isNewline) {
                let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                if !target.pathComponents.starts(with: workspace.resolvingSymlinksInPath().pathComponents) {
                    return "目标在「\(workspaceName)」工作区外，这次编辑需要单独确认。"
                }
            }
            return "自动范围为「\(workspaceName)」和 Hermes 临时目录内的普通编辑。"
        case "session", "dont_ask":
            return "Hermes 要求对这次修改单独确认。"
        case "ask", "default":
            return "手动模式下，每次文件修改都需要确认。"
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Label(heading.0, systemImage: heading.1)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isClarification ? StudioPalette.muted : StudioPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                evidence
                if let scopeNote {
                    Text(scopeNote)
                        .font(.system(size: 11))
                        .foregroundStyle(StudioPalette.muted)
                        .help(workspace?.path ?? workspaceName)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isClarification && !clarificationOptions.isEmpty {
                ScrollView {
                    clarificationList
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { clarificationHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(clarificationHeight ?? maximumClarificationHeight, maximumClarificationHeight))
                .padding(.horizontal, 7)
                .padding(.bottom, 5)
            }

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
                    .font(.system(size: isClarification ? 13 : 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if permission.kind != "clarify", let details = permission.details,
                permission.kind == "execute" || details != permission.title {
                if permission.kind == "execute" {
                    ScrollView {
                        Text(verbatim: details)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 65)
                    .background(StudioPalette.background, in: RoundedRectangle(cornerRadius: 6))
                } else {
                    PermissionContentPreview(text: details)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 7) {
            stopButton
            Spacer(minLength: 4)
            if isClarification {
                if let skip {
                    Button(optionLabel(skip)) { respond(skip.id) }
                        .buttonStyle(QuietButton())
                        .fixedSize()
                }
            } else {
                choices
            }
        }
    }

    private var clarificationList: some View {
        VStack(spacing: 0) {
            ForEach(clarificationOptions) { option in
                if option.id != clarificationOptions.first?.id {
                    StudioRule().padding(.horizontal, 8)
                }
                clarificationRow(option)
            }
        }
    }

    private func clarificationRow(_ option: ToolPermission.Option) -> some View {
        let name = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = ["(Recommended)", "（推荐）"].first { name.hasSuffix($0) && name.count > $0.count }
        let title = marker.map { name.dropLast($0.count).trimmingCharacters(in: .whitespacesAndNewlines) } ?? name
        return Button { respond(option.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(verbatim: title)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if marker != nil {
                    Text("推荐")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioPalette.accent)
                        .fixedSize()
                }
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioPalette.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .buttonStyle(StudioRowButton())
    }

    private var stopButton: some View {
        Button("停止本轮", action: stop)
            .buttonStyle(StudioRowButton())
            .font(.system(size: 11))
            .foregroundStyle(StudioPalette.muted)
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .fixedSize()
    }

    private var choices: some View {
        HStack(spacing: 7) {
            if !otherOptions.isEmpty {
                Button(allow == nil && deny == nil ? "选择回应" : "更多选项") {
                    showsOtherOptions.toggle()
                }
                .buttonStyle(QuietButton())
                .fixedSize()
                .popover(isPresented: $showsOtherOptions, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(otherOptions) { option in
                            Button {
                                showsOtherOptions = false
                                respond(option.id)
                            } label: {
                                Text(optionLabel(option))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(QuietButton())
                        }
                    }
                    .frame(minWidth: 160, maxWidth: 280)
                    .padding(6)
                }
            }
            if let deny {
                Button(optionLabel(deny)) { respond(deny.id) }
                    .buttonStyle(QuietButton())
                    .fixedSize()
            }
            if let sessionAllow {
                Button("本次会话允许") { respond(sessionAllow.id) }
                    .buttonStyle(QuietButton())
                    .fixedSize()
                    .help("在当前会话中允许 Hermes 识别出的同类操作")
            }
            if let allow {
                StudioPrimaryButton(title: optionLabel(allow), symbol: "checkmark") { respond(allow.id) }
            }
        }
    }

    private func optionLabel(_ option: ToolPermission.Option) -> String {
        if permission.toolID.hasPrefix("model-confirm-") { return option.name }
        return switch option.id {
        case "allow_once": "仅允许这一次"
        case "allow_always": "以后允许同类操作"
        case "deny": "拒绝本次"
        case "deny_always": "以后拒绝同类操作"
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
