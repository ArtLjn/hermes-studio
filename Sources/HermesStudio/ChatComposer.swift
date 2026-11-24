import AppKit
import StudioCore
import SwiftUI
import UniformTypeIdentifiers

struct ChatComposer: View {
    @ObservedObject var studio: StudioModel
    @Binding var focused: Bool
    let focusRequest: UUID
    @State private var chooseImages = false
    @State private var dropping = false
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorHeight: CGFloat = 30
    @State private var highlighted = 0
    @State private var dismissedToken: Token?
    @State private var dismissedDraft: String?
    @State private var nativeResult: (NativeRequest, [HermesCompletion])?
    @State private var historyResult: (HistoryRequest, String)?
    @State private var contextReview: ConsultationContextReview?

    private enum Token: Equatable {
        case skill(SkillCommand)
        case reference(String, NSRange)
    }

    private struct NativeRequest: Equatable {
        let roleID: UUID
        let query: HermesCompletion.Query
    }

    private struct HistoryRequest: Equatable {
        let home: URL
        let draft: String
    }

    private var token: Token? {
        guard focused, selection.length == 0 else { return nil }
        if let command = SkillCommand.atCaret(selection.location, in: studio.draft) { return .skill(command) }
        if studio.roleID != nil, let reference = HermesCompletion.reference(at: selection.location, in: studio.draft) {
            return .reference(reference.word, reference.range)
        }
        return nil
    }

    private var activeToken: Token? { token == dismissedToken ? nil : token }

    private var skillSearchRoleID: UUID? {
        guard case .skill = activeToken else { return nil }
        return studio.roleID
    }

    private var nativeRequest: NativeRequest? {
        guard studio.available, let roleID = studio.roleID, let token = activeToken else { return nil }
        switch token {
        case .skill(let command):
            guard !command.isExplicit, command.range.location == 0 else { return nil }
            return NativeRequest(roleID: roleID, query: .slash("/" + command.query))
        case .reference(let word, _):
            guard let project = studio.project else { return nil }
            return NativeRequest(roleID: roleID, query: .reference(word: word, project: project.directory))
        }
    }

    private func choices(for token: Token) -> [ComposerChoice] {
        let matches = nativeResult.flatMap { $0.0 == nativeRequest ? $0.1 : nil } ?? []
        let native = matches.map(ComposerChoice.native)
        switch token {
        case .skill(let command):
            return native + HermesSkill.matching(command.query, in: studio.availableSkills).map(ComposerChoice.skill)
        case .reference(let word, _):
            guard let sourceID = studio.roleID, studio.selectedHandoffTargetID == nil else { return native }
            return RoleHandoff.candidates(for: word, in: studio.roles, excluding: sourceID).map(ComposerChoice.role) + native
        }
    }

    private var showingInlineCompletion: Bool {
        focused && token == nil && dismissedDraft != studio.draft && !studio.draft.isEmpty &&
            selection.length == 0 && selection.location == studio.draft.utf16.count && studio.roleID != nil
    }

    private var historyRequest: HistoryRequest? {
        guard showingInlineCompletion, let home = studio.inputHistoryHome else { return nil }
        return HistoryRequest(home: home, draft: studio.draft)
    }

    private var completion: String? {
        guard showingInlineCompletion, let roleID = studio.roleID else { return nil }
        let local = ChatCompletion.suffix(for: studio.draft, in: studio.threads, roleID: roleID, projectID: studio.projectID)
        return local ?? historyResult.flatMap { $0.0 == historyRequest ? $0.1 : nil }
    }

    var body: some View {
        let suggestion = completion
        let request = nativeRequest
        let history = historyRequest
        VStack(spacing: 8) {
            if let token = activeToken, request != nil || !choices(for: token).isEmpty || studio.project != nil {
                CompletionSuggestions(matches: choices(for: token), highlighted: highlighted, store: studio.store,
                    emptyMessage: request != nil && nativeResult?.0 != request ? "正在查找补全…" : "没有匹配的补全") {
                    select($0, for: token)
                }
            }
            composer(suggestion: suggestion)
        }
        .onChange(of: token) { _, _ in
            highlighted = 0
            dismissedToken = nil
        }
        .task(id: skillSearchRoleID) {
            guard skillSearchRoleID != nil, !Task.isCancelled else { return }
            await studio.refreshSkillCatalog()
        }
        .task(id: request) {
            guard let request else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let matches = await studio.complete(request.query)
            guard !Task.isCancelled else { return }
            highlighted = 0
            nativeResult = (request, matches)
        }
        .task(id: history) {
            guard !Task.isCancelled else { return }
            historyResult = nil
            guard let history, let suffix = await studio.inputHistory.suffix(for: history.draft, in: history.home),
                !Task.isCancelled else { return }
            historyResult = (history, suffix)
        }
        .onChange(of: studio.draft) { _, _ in dismissedDraft = nil }
        .sheet(item: $contextReview) { review in
            ConsultationContextSheet(review: review, store: studio.store) { selected in
                studio.shareConsultationContext(selected, from: review)
            }
        }
    }

    private func composer(suggestion: String?) -> some View {
        VStack(spacing: 0) {
            if !studio.queuedMessages.isEmpty {
                ComposerReplyQueue(studio: studio).id(studio.conversationID)
                StudioRule()
            }
            VStack(spacing: 6) {
                if !studio.images.isEmpty || studio.selectedSkill != nil || studio.selectedHandoffTargetID != nil { contextTray }
                ComposerEditor(text: $studio.draft, focused: $focused, selection: $selection, height: $editorHeight,
                    focusRequest: focusRequest,
                    placeholder: dropping ? "松开以添加图片" : placeholder,
                    completion: suggestion, handle: handle, pasteImage: studio.pasteClipboardImages)
                    .frame(height: editorHeight)
                toolbar(suggestion: suggestion)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(StudioPalette.raised.opacity(0.90))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(dropping ? StudioPalette.accent : focused ? StudioPalette.accent.opacity(0.42) : StudioPalette.outline)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            studio.importImages(urls)
            return true
        } isTargeted: { dropping = $0 }
        .fileImporter(isPresented: $chooseImages, allowedContentTypes: [.image], allowsMultipleSelection: true) { selected in
            switch selected {
            case .success(let urls): studio.importImages(urls)
            case .failure(let error): studio.error = error.localizedDescription
            }
        }
    }

    private var placeholder: String {
        if studio.selectedHandoffTargetID != nil {
            switch studio.collaborationMode {
            case .handoff: return "补充交接任务或需要接手的事项…"
            case .question: return "输入要发给这位助手的问题…"
            case .preparedQuestion: return "告诉当前助手你想请教什么…"
            }
        }
        return studio.role.map { "发消息给\($0.name)… 输入 @ 可向其他助手提问或交接" } ?? "选择一个角色…"
    }

    private func handle(_ key: ComposerKey) -> Bool {
        guard let token = activeToken else {
            switch key {
            case .send:
                studio.send()
                return true
            case .complete, .acceptInline:
                guard let completion else { return false }
                accept(completion)
                return true
            case .dismiss:
                guard completion != nil else { return false }
                dismissedDraft = studio.draft
                return true
            case .up, .down:
                return false
            }
        }
        let matches = choices(for: token)
        switch key {
        case .acceptInline:
            return false
        case .send, .complete:
            if !matches.isEmpty {
                select(matches[min(highlighted, matches.count - 1)], for: token)
                return true
            }
            guard key == .send else { return false }
            if case .skill(let command) = token {
                guard !command.query.isEmpty else { return true }
                if !command.isExplicit, command.range.location == 0, HermesCompletion.supportsACPCommand(command.query) {
                    studio.send()
                } else {
                    finishSkillSearch(command)
                }
                return true
            }
            studio.send()
            return true
        case .up, .down:
            guard !matches.isEmpty else { return false }
            let offset = key == .up ? matches.count - 1 : 1
            highlighted = (min(highlighted, matches.count - 1) + offset) % matches.count
            return true
        case .dismiss:
            dismissedToken = token
            return true
        }
    }

    private func finishSkillSearch(_ command: SkillCommand) {
        let draft = studio.draft
        let context = studio.runSettingsContext
        Task {
            await studio.refreshSkillCatalog()
            guard studio.draft == draft, studio.runSettingsContext == context,
                activeToken == .skill(command) else { return }
            if let match = choices(for: .skill(command)).first {
                select(match, for: .skill(command))
            } else if command.isExplicit {
                studio.error = "没有找到匹配的技能，或当前角色未启用该技能。"
            } else {
                studio.send()
            }
        }
    }

    private func accept(_ suffix: String) {
        studio.draft += suffix
        selection = NSRange(location: studio.draft.utf16.count, length: 0)
        focused = true
    }

    private func select(_ choice: ComposerChoice, for token: Token) {
        let range: NSRange
        let insertion: String
        switch (choice, token) {
        case (.skill(let skill), .skill(let command)):
            range = command.range
            insertion = ""
            studio.selectedSkill = skill
        case (.native(let match), .skill(let command)):
            range = command.range
            insertion = match.insertion + " "
        case (.native(let match), .reference(_, let tokenRange)):
            range = tokenRange
            insertion = match.insertion
        case (.role(let role), .reference(_, let tokenRange)):
            range = tokenRange
            insertion = ""
            studio.selectedHandoffTargetID = role.id
            studio.collaborationMode = .question
            studio.clearConsultationContext()
        default:
            return
        }
        studio.draft = (studio.draft as NSString).replacingCharacters(in: range, with: insertion)
        selection = NSRange(location: range.location + insertion.utf16.count, length: 0)
        focused = true
    }

    private var contextTray: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                if let targetID = studio.selectedHandoffTargetID {
                    let target = studio.roles.first { $0.id == targetID }
                    HStack(spacing: 6) {
                        if let target {
                            RolePortrait(role: target, store: studio.store, size: 18)
                            Text(target.name)
                            Menu {
                                ForEach(RoleCollaborationMode.allCases) { mode in
                                    Button {
                                        studio.collaborationMode = mode
                                        if mode != .question { studio.clearConsultationContext() }
                                    } label: {
                                        if studio.collaborationMode == mode {
                                            Label(mode.label, systemImage: "checkmark")
                                        } else {
                                            Text(mode.label)
                                        }
                                    }
                                }
                            } label: {
                                Text(studio.collaborationMode.label)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel("协作方式")
                            .accessibilityValue(studio.collaborationMode.label)
                        } else {
                            Label("接收助手不可用", systemImage: "person.2")
                        }
                        Button {
                            studio.selectedHandoffTargetID = nil
                            studio.collaborationMode = .question
                            studio.clearConsultationContext()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除协作助手")
                    }
                    .padding(8)
                    .foregroundStyle(StudioPalette.accent)
                    .background(StudioPalette.selected, in: RoundedRectangle(cornerRadius: 7))
                }
                if let review = studio.consultationContextReview() {
                    let count = studio.sharedConsultationContext.count
                    Button(count == 0 ? "附带前文" : "已选 \(count) 条前文", systemImage: "quote.bubble") {
                        contextReview = review
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .foregroundStyle(count == 0 ? StudioPalette.muted : StudioPalette.accent)
                    .background(StudioPalette.selected, in: RoundedRectangle(cornerRadius: 7))
                }
                ForEach(studio.images) { image in
                    ZStack(alignment: .topTrailing) {
                        if let preview = NSImage(data: image.data) {
                            ChatImagePreviewButton(name: image.image.name, image: preview) {
                                Image(nsImage: preview).resizable().scaledToFill()
                                    .frame(width: 78, height: 61).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                        }
                        Button { studio.removeImage(image.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                                .frame(width: 18, height: 18)
                                .background(.black.opacity(0.72), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除图片 \(image.image.name)")
                        .padding(3)
                    }
                }
                if let skill = studio.selectedSkill {
                    HStack(spacing: 6) {
                        Label(skill.name, systemImage: "puzzlepiece")
                        Button { studio.selectedSkill = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除技能")
                    }
                    .padding(8)
                    .foregroundStyle(StudioPalette.accent)
                    .background(StudioPalette.selected, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .font(.system(size: 11))
        }
        .scrollIndicators(.hidden)
    }

    private func toolbar(suggestion: String?) -> some View {
        HStack(spacing: 7) {
            Menu {
                Button("选择图片…", systemImage: "photo") { chooseImages = true }
                Button("粘贴剪贴板图片", systemImage: "clipboard", action: studio.pasteImage)
            } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 23, height: 27)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("添加图片")
            .help("添加图片，也可拖入文件")
            if studio.conversationID == nil {
                Menu {
                    Button("无项目") { studio.chooseProject(nil) }
                    ForEach(studio.projects) { project in
                        Button(project.name) { studio.chooseProject(project) }
                    }
                } label: {
                    Label(studio.project?.name ?? "无项目", systemImage: "folder")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("选择对话项目")
            }
            if studio.pendingImages > 0 {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("正在准备图片")
            }
            Spacer(minLength: 4)
            if let suggestion {
                Button("Tab 补全") { accept(suggestion) }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioPalette.accent)
                    .help(suggestion)
                    .accessibilityLabel("补全为\(studio.draft + suggestion)")
            }
            ComposerRunSettingsButton(studio: studio)
            let enqueueing = studio.isGeneratingHere || !studio.queuedMessages.isEmpty
            if studio.isGeneratingHere {
                replyControl(studio.isStoppingHere ? "停止中" : "停止", label: "停止回复",
                    symbol: "stop.fill", help: "停止当前回复", action: studio.stop)
                    .disabled(studio.isStoppingHere)
            }
            if studio.canContinueReply {
                let title = studio.hasUnsentReply ? "重试原消息" : "继续回复"
                replyControl(studio.hasUnsentReply ? title : "继续", label: title, symbol: "play.fill",
                    help: "在当前会话中重试上次中断的请求", action: studio.continueReply)
            } else if !studio.isGeneratingHere || studio.canSend {
                let collaboration = studio.selectedHandoffTargetID.map { _ in studio.collaborationMode }
                let action: String = switch collaboration {
                case .handoff: "整理交接摘要"
                case .question: "向助手发送问题"
                case .preparedQuestion: "请当前助手拟问题"
                case nil: enqueueing ? "加入待发队列" : "发送消息"
                }
                let queueingDraft = enqueueing && studio.canSend && collaboration == nil
                actionButton(action, symbol: collaboration == nil ? "arrow.up" : "arrow.right",
                    title: queueingDraft ? "排队" : nil, action: studio.send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!studio.canSend)
                    .help(collaboration != nil ? action : enqueueing ? "回车加入队列 · Shift＋回车换行" : "回车发送 · Shift＋回车换行")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(StudioPalette.muted)
    }

    private func replyControl(_ title: String, label: String, symbol: String, help: String,
        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title).font(.system(size: 12, weight: .medium))
            } icon: {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(StudioPalette.muted)
            .padding(.horizontal, 9)
            .frame(height: 31)
        }
        .buttonStyle(StudioRowButton())
        .accessibilityLabel(label)
        .help(help)
    }

    private func actionButton(_ label: String, symbol: String, title: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let title {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 9)
                .frame(height: 31)
                .fixedSize()
            } else {
                Image(systemName: symbol).frame(width: 31, height: 31)
            }
        }
            .accessibilityLabel(label)
            .buttonStyle(ComposerActionStyle())
    }
}

private struct ComposerReplyQueue: View {
    @ObservedObject var studio: StudioModel
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let messages = studio.queuedMessages
        VStack(spacing: 0) {
            header(messages)
            if expanded {
                StudioRule()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { message in
                            row(message, isFirst: message.id == messages.first?.id)
                        }
                    }
                }
                .frame(height: CGFloat(min(messages.count, 4)) * 36)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(StudioPalette.muted)
        .background(.black.opacity(0.12))
    }

    private func header(_ messages: [StudioModel.QueuedMessage]) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12)
                    Text("待发 \(messages.count) 条")
                        .fontWeight(.semibold)
                        .foregroundStyle(StudioPalette.ink)
                        .fixedSize()
                    if !expanded, let first = messages.first {
                        Rectangle().fill(StudioPalette.outline).frame(width: 1, height: 12).accessibilityHidden(true)
                        preview(first)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
            }
            .buttonStyle(StudioRowButton())
            .accessibilityLabel(expanded ? "收起待发消息" : "展开 \(messages.count) 条待发消息")
            if studio.insertingMessage != nil {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("正在插入")
                }
                .fixedSize()
            } else if studio.isReplyQueuePaused {
                queueAction("继续队列", symbol: "play.fill", help: "恢复按顺序发送待发消息", action: studio.resumeReplyQueue)
                    .disabled(studio.isStoppingHere)
            } else if !expanded && studio.canInsertQueuedMessage {
                insertButton
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    private func row(_ message: StudioModel.QueuedMessage, isFirst: Bool) -> some View {
        HStack(spacing: 6) {
            preview(message)
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.ink)
            Spacer(minLength: 0)
            if isFirst && studio.canInsertQueuedMessage { insertButton }
            if message.id != studio.insertingMessage {
                StudioIconButton(title: "移除待发消息", symbol: "xmark") {
                    studio.removeQueuedMessage(message.id)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 36)
        .overlay(alignment: .top) {
            if !isFirst { StudioRule().padding(.horizontal, 14) }
        }
    }

    private func preview(_ message: StudioModel.QueuedMessage) -> some View {
        HStack(spacing: 6) {
            if let firstImage = message.images.first {
                if let image = NSImage(data: firstImage.data) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 23, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "photo").accessibilityHidden(true)
                }
                Text("\(message.images.count) 张图片").fixedSize()
            }
            if !message.text.isEmpty {
                Text(message.text).lineLimit(1).help(message.text)
            } else if let skill = message.skill {
                Text(skill.name).lineLimit(1).help(skill.name)
            }
        }
        .lineLimit(1)
    }

    private var insertButton: some View {
        queueAction("插入", symbol: "arrow.turn.down.right", help: "把队首文字插入当前任务", action: studio.insertQueuedMessage)
    }

    private func queueAction(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7)
                .frame(height: 26)
                .fixedSize()
        }
        .foregroundStyle(StudioPalette.accent)
        .buttonStyle(StudioRowButton())
        .help(help)
    }
}

private struct ComposerActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? StudioPalette.background : StudioPalette.muted.opacity(0.55))
            .background(enabled ? StudioPalette.accent : StudioPalette.line, in: RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private enum ComposerChoice: Identifiable {
    case skill(HermesSkill)
    case native(HermesCompletion)
    case role(Role)

    var id: String {
        switch self {
        case .skill(let item): "skill:" + item.id
        case .native(let item): "native:" + item.id
        case .role(let role): "role:" + role.id.uuidString
        }
    }
    var title: String {
        switch self {
        case .skill(let item): item.name
        case .native(let item): item.display
        case .role(let role): "@" + role.name
        }
    }
    var detail: String {
        switch self {
        case .skill(let item): item.summary
        case .native(let item): item.detail
        case .role(let role): role.summary.isEmpty ? "与此助手协作" : role.summary
        }
    }
    @ViewBuilder
    func icon(store: RoleStore) -> some View {
        switch self {
        case .role(let role):
            RolePortrait(role: role, store: store, size: 22)
        case .skill:
            Image(systemName: "puzzlepiece.extension")
        case .native(let item):
            if item.text.hasPrefix("@folder") { Image(systemName: "folder") }
            else if item.text.hasPrefix("@file") { Image(systemName: "doc") }
            else { Image(systemName: "terminal") }
        }
    }
}

private struct CompletionSuggestions: View {
    let matches: [ComposerChoice]
    let highlighted: Int
    let store: RoleStore
    let emptyMessage: String
    let select: (ComposerChoice) -> Void

    private let rowHeight: CGFloat = 34
    private var highlightedID: String? {
        guard !matches.isEmpty else { return nil }
        return matches[min(highlighted, matches.count - 1)].id
    }

    var body: some View {
        Group {
            if matches.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: rowHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches) { match in
                                row(for: match)
                            }
                        }
                    }
                    .frame(height: rowHeight * CGFloat(min(matches.count, 7)))
                    .onChange(of: highlightedID, initial: true) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .padding(5)
        .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(StudioPalette.line).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hermes 补全")
    }

    private func row(for match: ComposerChoice) -> some View {
        let selected = match.id == highlightedID
        return Button { select(match) } label: {
            HStack(spacing: 10) {
                match.icon(store: store)
                    .frame(width: 22)
                    .foregroundStyle(StudioPalette.accent)
                    .accessibilityHidden(true)
                Text(match.title)
                    .fontWeight(.semibold)
                    .layoutPriority(1)
                if !match.detail.isEmpty {
                    Text(match.detail)
                        .foregroundStyle(StudioPalette.muted)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "return")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioPalette.muted)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
            .background(selected ? StudioPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
