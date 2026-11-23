import StudioCore
import SwiftUI

enum GroupEditorSource: Identifiable {
    case new, settings(GroupDiscussion), proposal(GroupProposal)

    var id: String {
        switch self {
        case .new: "new-group"
        case .settings(let group): group.id.uuidString
        case .proposal(let proposal): proposal.id.uuidString
        }
    }
}

struct GroupEditor: View {
    enum Page: String, CaseIterable {
        case members = "群信息与成员"
        case chat = "聊天规则"
        case tools = "工具权限"
    }

    private static let memberRowHeight: CGFloat = 47
    private static let visibleMemberRows = 4

    @ObservedObject var studio: StudioModel
    @ObservedObject var model: GroupWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let source: GroupEditorSource
    let saved: (UUID) -> Void
    @State private var title: String
    @State private var goal: String
    @State private var selected: Set<UUID>
    @State private var relayLimit: Int
    @State private var replyMode: GroupDiscussion.ReplyMode
    @State private var casualReplyLimit: String
    @State private var idleChatMinutes: Int
    @State private var idleDailyLimit: Int
    @State private var allowsFullAccess: Bool
    @State private var toolPermissions: GroupToolPermissions
    @State private var chatActivity: GroupChatActivity
    @State private var chatFocus: GroupChatFocus
    @State private var continuesAfterMention: Bool
    @State private var memberChatPreferences: [UUID: GroupMemberChatPreferences]
    @State private var editingMember: UUID?
    @State private var page: Page
    @State private var task: String
    @State private var speaker: UUID?

    init(source: GroupEditorSource, studio: StudioModel, model: GroupWorkspaceModel, page: Page = .members,
        saved: @escaping (UUID) -> Void) {
        self.source = source
        self.studio = studio
        self.model = model
        self.saved = saved
        let group: GroupDiscussion?
        if case .settings(let existing) = source { group = existing } else { group = nil }
        _replyMode = State(initialValue: group?.effectiveReplyMode ?? .natural)
        _casualReplyLimit = State(initialValue: String(group?.casualMessagesPerTopic ?? 3))
        _idleChatMinutes = State(initialValue: group?.idleChatMinutes ?? 0)
        _idleDailyLimit = State(initialValue: group?.effectiveIdleDailyLimit ?? 1)
        _allowsFullAccess = State(initialValue: group?.allowsFullAccess ?? (group != nil && model.fullAccess))
        _toolPermissions = State(initialValue: group?.toolPermissions ?? GroupToolPermissions())
        _chatActivity = State(initialValue: group?.effectiveChatActivity ?? .natural)
        _chatFocus = State(initialValue: group?.effectiveChatFocus ?? .userCentered)
        _continuesAfterMention = State(initialValue: group?.continuesAfterMention == true)
        _memberChatPreferences = State(initialValue: group?.memberChatPreferences ?? [:])
        _page = State(initialValue: page)
        switch source {
        case .new:
            _title = State(initialValue: "")
            _goal = State(initialValue: "")
            _selected = State(initialValue: [])
            _relayLimit = State(initialValue: 0)
            _task = State(initialValue: "")
            _speaker = State(initialValue: nil)
        case .settings(let group):
            _title = State(initialValue: group.title)
            _goal = State(initialValue: group.goal)
            _selected = State(initialValue: Set(group.memberIDs))
            _relayLimit = State(initialValue: group.relayLimit)
            _task = State(initialValue: "")
            _speaker = State(initialValue: nil)
        case .proposal(let proposal):
            _title = State(initialValue: proposal.title)
            _goal = State(initialValue: proposal.goal)
            _selected = State(initialValue: Set(proposal.members.map(\.roleID) + [proposal.authorID]))
            _relayLimit = State(initialValue: 0)
            _task = State(initialValue: proposal.firstTask)
            _speaker = State(initialValue: proposal.authorID)
        }
    }

    private var groupID: UUID? {
        if case .settings(let group) = source { return group.id }
        return nil
    }

    private var proposal: GroupProposal? {
        if case .proposal(let proposal) = source { return proposal }
        return nil
    }

    private var orderedRoles: [Role] {
        let preferred: [UUID]
        switch source {
        case .proposal(let proposal): preferred = [proposal.authorID] + proposal.members.map(\.roleID)
        case .settings(let group): preferred = group.memberIDs
        case .new: return studio.roles
        }
        let ordered = preferred.compactMap { id in studio.roles.first { $0.id == id } }
        return ordered + studio.roles.filter { !preferred.contains($0.id) }
    }

    private var chosen: [Role] { orderedRoles.filter { selected.contains($0.id) } }
    private var firstSpeaker: UUID? { chosen.first(where: { $0.id == speaker })?.id ?? chosen.first?.id }
    private var validReplyLimit: Int? {
        guard let value = Int(casualReplyLimit.trimmingCharacters(in: .whitespacesAndNewlines)),
            GroupDiscussion.casualReplyRange.contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(groupID != nil ? "群聊设置" : proposal != nil ? "审阅建群提案" : "新建群聊")
                .font(.system(size: 19, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Picker("群聊设置页面", selection: $page) {
                ForEach(Page.allCases, id: \.self) { section in Text(section.rawValue).tag(section) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            Group {
                switch page {
                case .members: memberSettings
                case .chat:
                    ScrollView {
                        chatSettings.padding(.trailing, 8).padding(.vertical, 2)
                    }
                    .frame(height: 350)
                case .tools: toolSettings
                }
            }
            .frame(maxWidth: .infinity, minHeight: proposal == nil ? 294 : 342, alignment: .topLeading)
            if validReplyLimit == nil {
                Text("发言上限请输入 1–30 的整数。")
                    .font(.system(size: 12)).foregroundStyle(StudioPalette.accent)
            } else if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(StudioPalette.accent)
            }
            StudioRule()
            HStack {
                Text(chosen.isEmpty ? "请至少选择一位助手" : "已选 \(chosen.count) 位成员")
                    .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(groupID == nil ? "创建群聊" : "保存") {
                    if let id = model.saveSettings(groupID: groupID, proposalID: proposal?.id, title: title,
                        goal: goal, memberIDs: chosen.map(\.id), relayLimit: relayLimit, replyMode: replyMode,
                        casualReplyLimit: validReplyLimit, idleChatMinutes: idleChatMinutes, chatActivity: chatActivity,
                        continuesAfterMention: continuesAfterMention, chatFocus: chatFocus,
                        allowsFullAccess: model.fullAccess ? allowsFullAccess : nil, idleDailyLimit: idleDailyLimit,
                        toolPermissions: toolPermissions,
                        memberChatPreferences: memberChatPreferences, firstTask: task,
                        firstSpeaker: firstSpeaker, runtime: studio.groupRuntime) { saved(id) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validReplyLimit == nil)
            }
        }
        .padding(22)
        .frame(width: 528)
        .textFieldStyle(.roundedBorder)
    }

    private var memberSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("群名") { TextField("输入群名", text: $title).accessibilityLabel("群名") }
            field("群目标") {
                TextField("选填", text: $goal, axis: .vertical).lineLimit(1...2).accessibilityLabel("群目标")
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("成员")
                membersList
            }
            if proposal != nil {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        sectionTitle("首条任务")
                        Spacer()
                        if !chosen.isEmpty {
                            Picker("先请谁发言", selection: Binding(get: { firstSpeaker }, set: { speaker = $0 })) {
                                ForEach(chosen) { role in Text(role.name).tag(Optional(role.id)) }
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)
                        }
                    }
                    TextField("任务内容", text: $task, axis: .vertical)
                        .lineLimit(1...2).accessibilityLabel("首条任务")
                }
            }
        }
    }

    private var toolSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("访问范围") {
                Picker("本群工具权限", selection: $allowsFullAccess) {
                    Text("仅聊天").tag(false)
                    Text("允许工具").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 202)
                .disabled(!model.fullAccess)
            }
            Text(model.fullAccess ? "这里设置全群的工具上限。需要限制某位成员时，打开其「发言与权限」。" : "在运行设置开启群聊完全访问后，可以给本群启用更多工具。")
                .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
            GroupToolOptions(choices: $toolPermissions, includesExtendedTools: allowsFullAccess && model.fullAccess)
            Text("工具选择从下一条回复生效。终端和外部 MCP 也可能具备文件或联网能力。")
                .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
        }
        .font(.system(size: 12))
    }

    private var chatSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text((validReplyLimit.map { "当前每轮最多 \($0) 次请求" } ?? "请输入发言上限")
                    + (relayLimit == 0 ? " · 接力需确认" : " · 自动接力最多 \(relayLimit) 次"))
                    .foregroundStyle(StudioPalette.muted)
                Spacer()
                Button("应用热络预设") {
                    chatActivity = .lively
                    replyMode = .natural
                    casualReplyLimit = "5"
                    relayLimit = 1
                    continuesAfterMention = true
                }
                .help("每轮最多 5 次请求，单人被点名后允许接话，允许自动接力 1 次；静默主动开场设置保持不变。")
            }
            StudioRule()
            field("聊天重心") {
                Picker("聊天重心", selection: $chatFocus) {
                    ForEach(GroupChatFocus.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            Text(chatFocus.explanation)
                .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                .padding(.leading, 59).fixedSize(horizontal: false, vertical: true)
            StudioRule()
            field("活跃度") {
                Picker("群内活跃度", selection: $chatActivity) {
                    ForEach(GroupChatActivity.allCases, id: \.self) { option in Text(option.title).tag(option) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize().frame(width: 202, alignment: .leading)
            }
            Text(chatActivity.explanation)
                .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                .padding(.leading, 59).fixedSize(horizontal: false, vertical: true)
            StudioRule()
            field("发言方式") {
                Picker("发言方式", selection: $replyMode) {
                    ForEach(GroupDiscussion.ReplyMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize().frame(width: 294, alignment: .leading)
            }
            Text(replyMode.explanation)
                .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                .padding(.leading, 59).fixedSize(horizontal: false, vertical: true)
            Toggle("单人被点名后，允许其他成员接话", isOn: $continuesAfterMention)
                .toggleStyle(.checkbox)
                .help("其他成员可补充刚才的回复，也可以略过。安静模式会停止自然接话。")
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("发言上限")
                    TextField("1–30", text: $casualReplyLimit)
                        .frame(width: 53).multilineTextAlignment(.center)
                        .accessibilityLabel("每个话题发言上限，1 到 30")
                    Text("条").foregroundStyle(StudioPalette.muted)
                }
                .help("每条用户消息的助手请求上限，输入 1–30。略过和失败也计入；上限不是必须说满的条数。")
                Picker("主动开话题", selection: $idleChatMinutes) {
                    Text("关闭").tag(0)
                    ForEach([15, 30, 60], id: \.self) { Text("安静 \($0) 分钟后").tag($0) }
                    if idleChatMinutes > 0 && idleChatMinutes < 15 {
                        Text("安静 15 分钟后").tag(idleChatMinutes)
                    }
                }
                .help("前台查看本群时触发，每次一条，等待你回应。")
            }
            Text("上限包含略过和失败，不必说满；新消息会停止旧话题的自动续聊。自动接话只聊天，不使用终端或外部工具。")
                .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if idleChatMinutes > 0 {
                Picker("本群每天主动次数", selection: $idleDailyLimit) {
                    ForEach(0...3, id: \.self) { Text("\($0) 次").tag($0) }
                }
                Text("仅在 9–22 点、你最近一小时参与过的当前群触发。所有群合计每天最多 3 次。每次仅聊天，30 秒超时；无人回应就停。次数按已发起请求计算，失败也计入。")
                    .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("任务接力", selection: $relayLimit) {
                Text("手动确认").tag(0)
                ForEach(1...3, id: \.self) { count in Text("\(count) 次").tag(count) }
            }
            .help("定向任务和助手主动 @ 的接力上限。")
        }
        .pickerStyle(.menu)
        .font(.system(size: 12))
    }

    @ViewBuilder
    private var membersList: some View {
        let roles = chosen + orderedRoles.filter { !selected.contains($0.id) }
        if roles.isEmpty {
            Text("还没有可选成员")
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.muted)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(roles) { role in
                        memberRow(role)
                            .overlay(alignment: .bottom) {
                                if role.id != roles.last?.id {
                                    StudioRule().padding(.leading, 49).allowsHitTesting(false)
                                }
                            }
                    }
                }
            }
            .defaultScrollAnchor(.top)
            .scrollIndicatorsFlash(onAppear: roles.count > Self.visibleMemberRows)
            .frame(height: CGFloat(min(roles.count, Self.visibleMemberRows)) * Self.memberRowHeight)
            .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("群聊成员")
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioPalette.muted)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .medium)).frame(width: 49, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func memberRow(_ role: Role) -> some View {
        let reason: String? = switch source {
        case .proposal(let proposal): proposal.members.first { $0.roleID == role.id }?.reason
        case .settings(let group): group.memberDuties?[role.id]
        case .new: nil
        }
        let included = selected.contains(role.id)
        let summary = memberChatPreferences[role.id]?.summary ?? ""
        let subtitle = included && !summary.isEmpty ? summary : (reason ?? (proposal?.authorID == role.id ? "提案发起人" : role.summary))
        return HStack(spacing: 4) {
            Button {
                if included { selected.remove(role.id) } else { selected.insert(role.id) }
            } label: {
                HStack(spacing: 10) {
                    RolePortrait(role: role, store: studio.store, size: 29)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(role.name).font(.system(size: 13, weight: .semibold))
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(included ? StudioPalette.accent : StudioPalette.muted)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(height: Self.memberRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioRowButton())
            .accessibilityLabel(role.name)
            .accessibilityAddTraits(included ? .isSelected : [])
            .help(subtitle)
            if included {
                Button { editingMember = role.id } label: {
                    Text("发言与权限").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioPalette.accent)
                        .frame(width: 70, height: 27)
                }
                .buttonStyle(StudioRowButton())
                .padding(.trailing, 6)
                .accessibilityLabel("设置\(role.name)的发言与权限")
                .popover(isPresented: Binding(get: { editingMember == role.id }, set: { if !$0 { editingMember = nil } }),
                    arrowEdge: .trailing) {
                    GroupMemberBehaviorEditor(role: role, store: studio.store, settings: Binding(
                        get: { memberChatPreferences[role.id] ?? GroupMemberChatPreferences() },
                        set: { memberChatPreferences[role.id] = $0 }), groupTools: toolPermissions,
                        includesExtendedTools: allowsFullAccess && model.fullAccess)
                }
            } else {
                Color.clear.frame(width: 70, height: 27)
                    .padding(.trailing, 6).accessibilityHidden(true)
            }
        }
    }
}

struct GroupMemberBehaviorEditor: View {
    private enum Page { case speech, tools }

    let role: Role
    let store: RoleStore
    @Binding var settings: GroupMemberChatPreferences
    var groupTools = GroupToolPermissions()
    var includesExtendedTools = false
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .speech

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                RolePortrait(role: role, store: store, size: 31)
                VStack(alignment: .leading, spacing: 3) {
                    Text(role.name).font(.system(size: 14, weight: .semibold))
                    Text("仅在本群生效").font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                }
                Spacer()
                StudioIconButton(title: "关闭成员设置", symbol: "xmark") { dismiss() }
            }
            Picker("设置类别", selection: $page) {
                Text("发言与风格").tag(Page.speech)
                Text("工具权限").tag(Page.tools)
            }
            .labelsHidden().pickerStyle(.segmented)
            switch page {
            case .speech: speechSettings
            case .tools:
                Text("群里开启的工具，可对这位成员单独关闭。")
                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                GroupToolOptions(choices: Binding(get: { settings.toolPermissions ?? GroupToolPermissions() },
                    set: { settings.toolPermissions = $0 }), available: groupTools, includesExtendedTools: includesExtendedTools)
            }
        }
        .pickerStyle(.menu)
        .font(.system(size: 12))
        .padding(15)
        .frame(width: 340)
        .foregroundStyle(StudioPalette.ink)
        .background(StudioPalette.sidebar)
    }

    private var speechSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("何时发言", selection: $settings.initiative) {
                ForEach(GroupMemberChatPreferences.Initiative.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            if settings.initiative == .reserved {
                Text("通常等别人点名，群里没人愿意先答时也会接话。")
                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
            } else if settings.initiative == .proactive {
                Text("其他成员刚发言时，有机会优先接话。")
                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
            } else if settings.initiative == .mentionedOnly {
                Text("用户 @、@所有人或收到明确接力时会回应。")
                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
            }
            Toggle("群安静时可以开话题", isOn: Binding(
                get: { settings.initiative != .reserved && settings.initiative != .mentionedOnly && settings.canOpenIdleTopic != false },
                set: { settings.canOpenIdleTopic = $0 }))
                .disabled(settings.initiative == .reserved || settings.initiative == .mentionedOnly)
                .help("群聊开启「主动开话题」时生效")
            Toggle("可以发起接力", isOn: Binding(get: { settings.canRequestRelay != false },
                set: { settings.canRequestRelay = $0 }))
                .help("自动接力次数和手动确认由聊天规则决定")
            StudioRule()
            Picker("说话风格", selection: $settings.tone) {
                ForEach(GroupMemberChatPreferences.Tone.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            if settings.tone == .custom {
                TextField("例如清冷克制，偶尔带一点幽默", text: $settings.customTone, axis: .vertical)
                    .lineLimit(2...3).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("自定义说话风格")
            }
            if settings.tone != .inherit {
                Picker("风格强度", selection: $settings.intensity) {
                    ForEach(GroupMemberChatPreferences.Intensity.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

private struct GroupToolOptions: View {
    @Binding var choices: GroupToolPermissions
    var available = GroupToolPermissions()
    let includesExtendedTools: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
            option("邀请群成员", \.invitations)
            option("读取群内链接", \.sharedLinks)
            if includesExtendedTools {
                option("终端命令", \.terminal)
                option("文件工具", \.files)
                option("网页搜索", \.web)
                option("浏览器操作", \.browser)
                option("外部 MCP", \.externalMCP)
                option("角色技能", \.skills)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func option(_ title: String, _ key: WritableKeyPath<GroupToolPermissions, Bool>) -> some View {
        let allowed = available[keyPath: key]
        return Toggle(title, isOn: Binding(get: { allowed && choices[keyPath: key] },
            set: { choices[keyPath: key] = $0 }))
            .disabled(!allowed)
    }
}
