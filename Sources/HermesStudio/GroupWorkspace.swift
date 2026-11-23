import AppKit
import StudioCore
import SwiftUI

struct GroupWorkspace: View {
    @ObservedObject var studio: StudioModel
    @ObservedObject var model: GroupWorkspaceModel
    @State private var selectedID: UUID?
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var editor: GroupEditorSource?
    @State private var viewingHistory: GroupDiscussion?
    @State private var viewingArchive = false
    @State private var renamingID: UUID?
    @State private var conversationTitle = ""
    @State private var replyDetailsExpanded = false

    static func recentThreads(_ threads: [GroupDiscussion], selectedID: UUID?) -> [GroupDiscussion] {
        let pinned = threads.filter { $0.pinnedAt != nil }
        let unpinned = threads.filter { $0.pinnedAt == nil }
        let recent = unpinned.prefix(5)
        if let selectedID, !recent.contains(where: { $0.id == selectedID }),
            let selected = unpinned.first(where: { $0.id == selectedID }) {
            return pinned + recent.dropLast() + [selected]
        }
        return pinned + recent
    }

    private var selected: GroupDiscussion? {
        let threads = model.activeDiscussions
        return threads.first { $0.id == selectedID } ?? threads.first
    }

    var body: some View {
        GeometryReader { layout in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: layout.size.width < 850 ? 176 : 209)
                    .frame(maxHeight: .infinity)
                    .background(StudioPalette.sidebar.opacity(0.72))
                Rectangle().fill(StudioPalette.line).frame(width: 1)
                if let group = selected {
                    discussion(group).id(group.id)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("与多位助手一起工作")
                            .font(.system(size: 23, weight: .semibold))
                        Text(model.discussions.isEmpty ? "建个群，邀请几位助手一起聊。" : "新建群内对话，或恢复已归档的对话。")
                            .font(.system(size: 13))
                            .foregroundStyle(StudioPalette.muted)
                        Button("新建群聊", systemImage: "plus") { editor = .new }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                }
            }
        }
        .onAppear {
            model.visibleThreadID = selected?.id
            if selectedID == nil, let first = selected { select(first) }
            model.reloadProposals()
        }
        .sheet(item: $editor) { source in
            GroupEditor(source: source, studio: studio, model: model) { id in
                if selected?.groupID != id { selectedID = id }
                expandedGroupIDs.insert(id)
                editor = nil
            }
        }
        .sheet(item: $viewingHistory) { group in
            GroupHistorySheet(groupName: group.title, threads: model.activeConversations(in: group.id),
                selectedID: selected?.id) { thread in
                    select(thread)
                    viewingHistory = nil
                }
        }
        .sheet(isPresented: $viewingArchive) {
            GroupArchiveSheet(model: model, onRestore: select)
        }
        .onChange(of: selectedID) { _, _ in
            replyDetailsExpanded = false
            model.visibleThreadID = selected?.id
        }
        .onChange(of: selected?.id, initial: true) { _, id in
            if let runtime = studio.groupRuntime { model.updateWarmCache(groupID: NSApp.isActive ? id : nil, runtime: runtime) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if let runtime = studio.groupRuntime { model.updateWarmCache(groupID: nil, runtime: runtime) }
        }
        .onChange(of: studio.available) { _, _ in
            if let runtime = studio.groupRuntime { model.updateWarmCache(groupID: NSApp.isActive ? selected?.id : nil, runtime: runtime) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let runtime = studio.groupRuntime { model.updateWarmCache(groupID: selected?.id, runtime: runtime) }
        }
        .onDisappear {
            model.visibleThreadID = nil
            if let runtime = studio.groupRuntime { model.updateWarmCache(groupID: nil, runtime: runtime) }
        }
        .alert("重命名对话", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("对话名称", text: $conversationTitle)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let renamingID { model.renameConversation(renamingID, title: conversationTitle) }
            }
            .disabled(conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("群聊").font(.system(size: 15, weight: .semibold))
                Spacer()
                StudioIconButton(title: "已归档群聊对话", symbol: "archivebox") { viewingArchive = true }
                StudioIconButton(title: "新建群聊", symbol: "plus") { editor = .new }
            }
            .padding(.horizontal, 15)
            .frame(height: StudioPalette.toolbarHeight)
            StudioRule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if !model.pendingProposals.isEmpty {
                        Text("待确认的提案")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(StudioPalette.muted)
                            .padding(.leading, 9)
                            .padding(.top, 6)
                        ForEach(model.pendingProposals) { proposal in
                            Button { editor = .proposal(proposal) } label: {
                                Label(proposal.title, systemImage: "doc.text")
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(StudioRowButton(selected: false))
                            .accessibilityLabel("审阅建群提案 \(proposal.title)")
                        }
                        StudioRule().padding(.vertical, 6)
                    }
                    ForEach(model.discussions.filter { $0.parentGroupID == nil }) { group in
                        groupSection(group)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 9)
                .font(.system(size: 13))
            }
        }
    }

    private func groupSection(_ group: GroupDiscussion) -> some View {
        let threads = model.activeConversations(in: group.id)
        let visible = Self.recentThreads(threads, selectedID: selected?.id)
        let expanded = expandedGroupIDs.contains(group.id)
        let active = threads.reduce(0) { $0 + $1.turns.filter { $0.state == .running }.count }
        return VStack(alignment: .leading, spacing: 1) {
            Button {
                if selected?.groupID != group.id, let first = threads.first { select(first) }
                else if expanded { expandedGroupIDs.remove(group.id) }
                else { expandedGroupIDs.insert(group.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2")
                        .font(.system(size: 13))
                        .foregroundStyle(StudioPalette.muted)
                        .frame(width: 17)
                        .accessibilityHidden(true)
                    Text(group.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if active > 0 { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(StudioPalette.muted)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 8)
                .frame(height: 31)
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioRowButton(selected: selected?.groupID == group.id && !expanded))
            .accessibilityLabel(group.title)
            .accessibilityValue("\(expanded ? "已展开" : "已折叠")，\(threads.count) 段对话")
            .help(active > 0 ? "\(active) 位助手正在回复" : "\(threads.count) 段对话")
            if expanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visible) { thread in
                        GroupHistoryRow(thread: thread, selected: selected?.id == thread.id) { select(thread) }
                            .contextMenu { conversationActions(thread) }
                    }
                    if threads.isEmpty {
                        Button("群内新对话", systemImage: "square.and.pencil") { newConversation(in: group.id) }
                            .buttonStyle(QuietButton())
                    }
                    if threads.count > visible.count {
                        Button { viewingHistory = group } label: {
                            HStack(spacing: 5) {
                                Text("全部 \(threads.count) 段对话").lineLimit(1)
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                                    .accessibilityHidden(true)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(StudioPalette.muted)
                            .padding(.horizontal, 7)
                            .frame(height: 27)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(StudioRowButton())
                    }
                }
                .padding(.leading, 26)
                .padding(.bottom, 3)
            }
        }
    }

    private func select(_ thread: GroupDiscussion) {
        selectedID = thread.id
        expandedGroupIDs.insert(thread.groupID)
    }

    private func newConversation(in groupID: UUID) {
        if let id = model.newConversation(in: groupID) {
            selectedID = id
            expandedGroupIDs.insert(groupID)
        }
    }

    @ViewBuilder
    private func conversationActions(_ thread: GroupDiscussion) -> some View {
        Button("重命名对话", systemImage: "pencil") {
            conversationTitle = thread.displayConversationTitle
            renamingID = thread.id
        }
        Button(thread.pinnedAt == nil ? "置顶对话" : "取消置顶",
            systemImage: thread.pinnedAt == nil ? "pin" : "pin.slash") {
            model.toggleConversationPin(thread.id)
        }
        Button("归档对话", systemImage: "archivebox") {
            let wasSelected = selected?.id == thread.id
            if model.setConversationArchived(thread.id, archived: true), wasSelected {
                if let next = model.activeConversations(in: thread.groupID).first ?? model.activeDiscussions.first {
                    select(next)
                } else {
                    selectedID = nil
                }
            }
        }
        .disabled(!model.canArchiveConversation(thread))
    }

    private func discussion(_ group: GroupDiscussion) -> some View {
        let members = group.memberIDs.compactMap { id in studio.roles.first { $0.id == id } }
        return VStack(spacing: 0) {
            header(group, members: members)
            StudioRule()
            transcript(group, members: members)
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(error).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button("关闭提示", systemImage: "xmark") { model.error = nil }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.accent)
                .padding(.vertical, 7)
                .frame(maxWidth: StudioPalette.transcriptWidth)
                .padding(.horizontal, 22)
            }
            GroupComposer(members: members, store: studio.store,
                draft: Binding(get: { model.drafts[group.id] ?? GroupComposerDraft() }, set: { model.drafts[group.id] = $0 }),
                available: studio.groupRuntime != nil, status: groupStatus(group),
                report: { model.error = $0 }) { target, text, files in
                    guard let runtime = studio.groupRuntime else { return false }
                    return model.submit(groupID: group.id, roleIDs: target.memberIDs, question: text, attachments: files,
                        runtime: runtime, toEveryone: target == .everyone)
                }
                .frame(maxWidth: StudioPalette.transcriptWidth)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ group: GroupDiscussion, members: [Role]) -> some View {
        let detail = group.displayConversationTitle
        let mode = group.effectiveReplyMode.title
        let activity = group.effectiveChatActivity
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    .help(group.goal.isEmpty ? group.title : group.goal)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                        .lineLimit(1).help(detail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            Text(activity == .natural ? mode : "\(activity.title) · \(mode)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StudioPalette.muted)
                .fixedSize()
            StudioIconButton(title: "群内新对话", symbol: "square.and.pencil") {
                newConversation(in: group.groupID)
            }
            Menu("对话操作", systemImage: "ellipsis.circle") { conversationActions(group) }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("对话操作")
            Button {
                if let parent = model.discussions.first(where: { $0.id == group.groupID }) {
                    editor = .settings(parent)
                }
            } label: {
                HStack(spacing: 7) {
                    HStack(spacing: -3) {
                        ForEach(members.prefix(4)) { role in
                            RolePortrait(role: role, store: studio.store, size: 23)
                                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(StudioPalette.sidebar, lineWidth: 1) }
                        }
                    }
                    Text("群设置").font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(StudioPalette.muted)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
            }
            .buttonStyle(StudioRowButton(selected: false))
            .fixedSize()
            .accessibilityLabel("打开群聊设置")
            .help(members.map(\.name).joined(separator: "、"))
        }
        .padding(.horizontal, 22)
        .frame(height: StudioPalette.toolbarHeight)
    }

    private func transcript(_ group: GroupDiscussion, members: [Role]) -> some View {
        let additionalRecipients = Dictionary(grouping: group.turns.filter { $0.kind == .multiMentionReply }, by: \.taskID)
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 23) {
                        ForEach(group.turns.filter { turn in
                            turn.initiatedByUser || (turn.requesterID != nil && turn.kind != .reaction)
                                || turn.state == .failed || turn.state == .cancelled
                                || turn.answer?.isEmpty == false
                                || model.liveText(groupID: group.id, turnID: turn.id)?.isEmpty == false
                        }) { turn in
                            transcriptRow(turn, groupID: group.id, members: members,
                                additionalRecipients: additionalRecipients[turn.id] ?? [],
                                mayRequestRelay: group.canRequestRelay(turn.roleID))
                        }
                        Color.clear.frame(height: 1).id("group-end")
                    }
                    .frame(maxWidth: StudioPalette.transcriptWidth, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                }
                .defaultScrollAnchor(.bottom)
                .overlay(alignment: .center) {
                    if group.turns.isEmpty {
                        Text("发条消息开启群聊")
                            .font(.system(size: 14))
                            .foregroundStyle(StudioPalette.muted)
                    }
                }
                .onChange(of: group.turns.count) { _, _ in proxy.scrollTo("group-end", anchor: .bottom) }
            }
        }
    }

    private func transcriptRow(_ turn: GroupTurn, groupID: UUID, members: [Role], additionalRecipients: [GroupTurn],
        mayRequestRelay: Bool) -> some View {
        GroupTranscriptRow(turn: turn,
            speaker: historyRole(turn.roleID),
            requester: turn.requesterID.flatMap(historyRole),
            additionalRecipientNames: additionalRecipients.map { historyRole($0.roleID)?.name ?? $0.roleName },
            relayRole: mayRequestRelay ? members.first { $0.id == turn.relay?.roleID } : nil,
            relayRecipientName: turn.relay.flatMap { historyRole($0.roleID)?.name },
            store: studio.store, liveText: model.liveText(groupID: groupID, turnID: turn.id),
            canRetry: members.contains { $0.id == turn.roleID } && studio.groupRuntime != nil,
            canRelay: studio.groupRuntime != nil,
            retry: {
                if let runtime = studio.groupRuntime { model.retry(groupID: groupID, turnID: turn.id, runtime: runtime) }
            },
            relay: {
                if let runtime = studio.groupRuntime { model.followRelay(groupID: groupID, turnID: turn.id, runtime: runtime) }
            })
    }

    private func historyRole(_ id: UUID) -> Role? {
        studio.roles.first { $0.id == id } ?? studio.archivedRoles.first { $0.id == id }
    }

    @ViewBuilder
    private func groupStatus(_ group: GroupDiscussion) -> some View {
        let active = group.turns.filter { $0.state == .running }
        let pending = group.turns.filter { $0.state == .queued }.count
        var represented: Set<UUID> = []
        let progress = (active + group.turns.filter { $0.state == .queued })
            .filter { represented.insert($0.roleID).inserted }
        if !active.isEmpty || pending > 0 || group.paused {
            GroupReplyProgressStack(entries: progress.map { turn in
                let role = historyRole(turn.roleID)
                return .init(id: turn.id, role: role, name: role?.name ?? turn.roleName,
                    activity: turn.state == .queued
                        ? "排队中"
                        : model.activity(groupID: group.id, turnID: turn.id) ?? "准备回复",
                    waiting: turn.state == .queued,
                    cancel: turn.state == .queued ? { model.cancelWaiting(groupID: group.id, turnID: turn.id) } : nil)
            }, store: studio.store, expanded: $replyDetailsExpanded,
                controls: HStack(spacing: 10) {
                    if pending > 0 {
                        Menu("\(pending) 条排队") {
                            ForEach(group.turns.filter { $0.state == .queued }) { turn in
                                Button("移出 \(turn.roleName) · \(turn.question.prefix(24))") {
                                    model.cancelWaiting(groupID: group.id, turnID: turn.id)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                    if group.paused { Text("已暂停") }
                    if !active.isEmpty {
                        Button("停止回复", systemImage: "stop", action: { model.stop(groupID: group.id) })
                            .disabled(model.isStopping(group.id))
                    }
                    Button(group.paused ? "继续队列" : "暂停队列", systemImage: group.paused ? "play" : "pause") {
                        model.setPaused(!group.paused, groupID: group.id, runtime: studio.groupRuntime)
                    }
                    .disabled(group.paused && studio.groupRuntime == nil)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StudioPalette.muted)
                .buttonStyle(.plain))
        }
    }
}

struct GroupHistoryRow: View {
    let thread: GroupDiscussion
    let selected: Bool
    var showsDate = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                if thread.pinnedAt != nil {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(StudioPalette.muted)
                        .accessibilityLabel("已置顶")
                }
                Text(thread.displayConversationTitle)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? StudioPalette.ink : StudioPalette.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if thread.turns.contains(where: { $0.state == .running }) {
                    ProgressView().controlSize(.mini).accessibilityLabel("正在回复")
                } else if showsDate {
                    Text(thread.updated, format: .dateTime.month().day())
                        .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioRowButton(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(thread.displayConversationTitle)
    }
}

struct GroupHistorySheet: View {
    let groupName: String
    let threads: [GroupDiscussion]
    let selectedID: UUID?
    let open: (GroupDiscussion) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searching: Bool

    private var matches: [GroupDiscussion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? threads : threads.filter { $0.displayConversationTitle.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(groupName).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text("\(threads.count) 段对话").font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                }
                Spacer()
                StudioIconButton(title: "关闭对话列表", symbol: "xmark") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioPalette.muted).accessibilityHidden(true)
                TextField("按标题查找对话", text: $query)
                    .textFieldStyle(.plain).focused($searching)
            }
            .font(.system(size: 13))
            .padding(8)
            .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 6))
            if matches.isEmpty {
                Text("找不到匹配的对话")
                    .foregroundStyle(StudioPalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { thread in
                            GroupHistoryRow(thread: thread, selected: selectedID == thread.id, showsDate: true) { open(thread) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 400, height: 400)
        .foregroundStyle(StudioPalette.ink)
        .background(StudioPalette.sidebar)
        .onAppear { searching = true }
    }
}

struct GroupArchiveSheet: View {
    @ObservedObject var model: GroupWorkspaceModel
    let onRestore: (GroupDiscussion) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let archived = model.archivedDiscussions
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已归档群聊对话").font(.system(size: 16, weight: .semibold))
                Spacer()
                StudioIconButton(title: "关闭归档列表", symbol: "xmark") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(StudioPalette.accent).textSelection(.enabled)
            }
            if archived.isEmpty {
                Text("还没有已归档的群聊对话")
                    .foregroundStyle(StudioPalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(archived) { thread in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(thread.displayConversationTitle).font(.system(size: 13, weight: .medium))
                                    Text(thread.title).font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                                }
                                .lineLimit(1)
                                Spacer(minLength: 0)
                                if let archivedAt = thread.archivedAt {
                                    Text(archivedAt, style: .date).font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                                }
                                Button("恢复", systemImage: "arrow.uturn.backward") {
                                    if model.setConversationArchived(thread.id, archived: false) { onRestore(thread) }
                                }
                                .buttonStyle(QuietButton())
                                .accessibilityLabel("恢复对话 \(thread.displayConversationTitle)")
                                .fixedSize()
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 400, height: 400)
        .foregroundStyle(StudioPalette.ink)
        .background(StudioPalette.sidebar)
    }
}

struct GroupReplyProgressStack<Controls: View>: View {
    struct Entry: Identifiable {
        let id: UUID
        let role: Role?
        let name: String
        let activity: String
        var waiting = false
        var cancel: (() -> Void)? = nil
    }

    let entries: [Entry]
    let store: RoleStore
    @Binding var expanded: Bool
    let controls: Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if !entries.isEmpty {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 7) {
                            if !expanded {
                                HStack(spacing: -3) {
                                    ForEach(entries.prefix(4)) { entry in portrait(entry, size: 16) }
                                }
                            }
                            Text(expanded ? "成员进度" : summary).lineLimit(1)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioPalette.muted)
                        .padding(.horizontal, 5)
                        .frame(height: 25)
                    }
                    .buttonStyle(StudioRowButton())
                    .accessibilityValue(expanded ? "已展开回复详情" : "已折叠回复详情")
                }
                Spacer(minLength: 3)
                controls.fixedSize(horizontal: true, vertical: false)
            }
            if expanded {
                ForEach(entries) { entry in
                    HStack(spacing: 7) {
                        portrait(entry, size: 16)
                        Text(entry.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(entry.activity).font(.system(size: 11)).foregroundStyle(StudioPalette.muted).lineLimit(1)
                        if entry.waiting {
                            if let cancel = entry.cancel {
                                Button("移出队列", action: cancel).buttonStyle(.plain)
                                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                            }
                        } else {
                            ProgressView().controlSize(.mini).accessibilityHidden(true)
                        }
                    }
                    .padding(.leading, 5)
                    .frame(height: 23)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var summary: String {
        if let entry = entries.first, entries.count == 1 { return "\(entry.name) · \(entry.activity)" }
        let active = entries.filter { !$0.waiting }.count
        return active == 0 ? "\(entries.count) 位成员排队中" : "\(active) 位正在回复 · \(entries.count - active) 位排队"
    }

    private func portrait(_ entry: Entry, size: CGFloat) -> RolePortrait {
        if let role = entry.role { return RolePortrait(role: role, store: store, size: size) }
        return RolePortrait(image: nil, symbol: "person.fill", size: size)
    }
}

private struct GroupTranscriptRow: View {
    let turn: GroupTurn
    let speaker: Role?
    let requester: Role?
    let additionalRecipientNames: [String]
    let relayRole: Role?
    let relayRecipientName: String?
    let store: RoleStore
    let liveText: String?
    let canRetry: Bool
    let canRelay: Bool
    let retry: () -> Void
    let relay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if turn.initiatedByUser || (turn.requesterID != nil && turn.kind != .reaction) {
                if turn.requesterID != nil {
                    requestMessage
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    requestMessage
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if let answer = visibleAnswer {
                if !answer.isEmpty || pendingRelay != nil {
                    assistantHeader(role: speaker, name: speaker?.name ?? turn.roleName, detail: answerDetail,
                        mentionsRecipient: false)
                }
                if !answer.isEmpty {
                    MarkdownReply(text: answer)
                }
            } else if turn.state == .failed || turn.state == .cancelled {
                HStack(spacing: 8) {
                    Text(stateLabel)
                    if canRetry && (turn.state == .cancelled || turn.state == .failed) {
                        Button("重试", action: retry).buttonStyle(.link)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.muted)
            }
            if let target = relayRole, let proposed = pendingRelay {
                Button(action: relay) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(canRelay ? "请\(target.name)接力" : "等待\(target.name)接力 · Hermes 未就绪")
                                .fontWeight(.semibold)
                            Text(proposed.question)
                                .foregroundStyle(StudioPalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(canRelay ? StudioPalette.accent : StudioPalette.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canRelay)
                .help("把这条问题交给\(target.name)，回复会出现在当前群聊")
            }
            if let names = turn.joinedMemberNames, !names.isEmpty {
                Label("\(names.joined(separator: "、"))已加入群聊", systemImage: "person.badge.plus")
                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
            }
            if turn.savedGroupMemory == true {
                Label("已存为群记忆", systemImage: "bookmark")
                    .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
            }
        }
    }

    private var requestMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            let target = speaker?.name ?? turn.roleName
            if turn.requesterID != nil {
                assistantHeader(role: requester, name: requester?.name ?? turn.requesterName, detail: "@\(target)",
                    mentionsRecipient: true)
            } else {
                let recipients = turn.addressesEveryone ? [GroupRecipient.everyoneName] : [target] + additionalRecipientNames
                let detail = turn.startsTopic && !turn.addressesEveryone ? "· 群聊话题"
                    : recipients.map { "@\($0)" }.joined(separator: " ")
                Text("\(turn.requesterName) \(detail)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioPalette.muted)
            }
            Text(turn.question).font(.system(size: 13)).textSelection(.enabled)
            if let raw = turn.sharedLink, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                Link(destination: url) {
                    Label("在浏览器打开", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(StudioPalette.accent)
                }
            }
            ForEach(turn.attachments) { file in
                if let image = file.image,
                    let thumbnail = NSImage(contentsOf: GroupDiscussionStore(root: store.root).imageURL(image)) {
                    ChatImagePreviewButton(name: file.name, image: thumbnail,
                        fileURL: GroupDiscussionStore(root: store.root).imageURL(image)) {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                            .frame(maxWidth: 240, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                } else if file.image != nil {
                    Label("图片不可用 · \(file.name)", systemImage: "photo")
                        .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                } else {
                    DisclosureGroup {
                        Text(file.text).font(.system(size: 12)).textSelection(.enabled).padding(.top, 4)
                    } label: {
                        Label(file.name, systemImage: "doc").font(.system(size: 11))
                    }
                }
            }
        }
    }

    private func assistantHeader(role: Role?, name: String, detail: String?, mentionsRecipient: Bool) -> some View {
        HStack(spacing: 7) {
            if let role {
                RolePortrait(role: role, store: store, size: 26)
            } else {
                RolePortrait(image: nil, symbol: "person.fill", size: 26)
            }
            Text(name).font(.system(size: 12, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(mentionsRecipient ? StudioPalette.accent : StudioPalette.muted)
            }
        }
    }

    private var answerDetail: String? {
        if turn.kind == .proactiveTopic { return "主动开话题" }
        if turn.requesterID != nil { return "回复 \(requester?.name ?? turn.requesterName)" }
        return nil
    }

    private var pendingRelay: GroupRelay? {
        guard relayRole != nil, let relay = turn.relay, !relay.enqueued && !relay.reviewed else { return nil }
        return relay
    }

    private var visibleAnswer: String? {
        guard let answer = liveText ?? turn.answer, !answer.isEmpty else { return nil }
        let visible = TextOnlyReply.parse(answer, streaming: turn.state == .running).text
        if turn.state == .running { return GroupRelay.extract(from: visible).0 }
        if let relay = turn.relay, let relayRecipientName, relay.enqueued || relay.reviewed || pendingRelay != nil {
            return relay.removingNamedMention(from: visible, recipientName: relayRecipientName)
        }
        return visible
    }

    private var stateLabel: String {
        switch turn.state {
        case .queued: "等待\(turn.roleName)发言"
        case .running: "\(turn.roleName)正在回复…"
        case .cancelled: "已取消"
        case .failed: "未收到完整回复"
        case .completed: ""
        }
    }
}
