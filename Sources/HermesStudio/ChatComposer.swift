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
        if studio.project != nil, let reference = HermesCompletion.reference(at: selection.location, in: studio.draft) {
            return .reference(reference.word, reference.range)
        }
        return nil
    }

    private var activeToken: Token? { token == dismissedToken ? nil : token }

    private var nativeRequest: NativeRequest? {
        guard studio.available, let roleID = studio.roleID, let token = activeToken else { return nil }
        switch token {
        case .skill(let command):
            guard command.range.location == 0,
                (studio.draft as NSString).substring(with: command.range) == "/" + command.query else { return nil }
            return NativeRequest(roleID: roleID, query: .slash("/" + command.query))
        case .reference(let word, _):
            guard let project = studio.project else { return nil }
            return NativeRequest(roleID: roleID, query: .reference(word: word, project: project.directory))
        }
    }

    private func choices(for token: Token) -> [ComposerChoice] {
        let matches = nativeResult.flatMap { $0.0 == nativeRequest ? $0.1 : nil } ?? []
        let native = matches.map(ComposerChoice.native)
        guard case .skill(let command) = token else { return native }
        return native + HermesSkill.matching(command.query, in: studio.availableSkills).map(ComposerChoice.skill)
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
            if let token = activeToken {
                CompletionSuggestions(matches: choices(for: token), highlighted: highlighted,
                    emptyMessage: request != nil && nativeResult?.0 != request ? "正在查找补全…" : "没有匹配的补全") {
                    select($0, for: token)
                }
            }
            if !studio.queuedTurns.isEmpty { queuedMessages }
            composer(suggestion: suggestion)
        }
        .onChange(of: token) { _, _ in
            highlighted = 0
            dismissedToken = nil
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
    }

    private func composer(suggestion: String?) -> some View {
        VStack(spacing: 6) {
            if !studio.images.isEmpty || studio.selectedSkill != nil { contextTray }
            ComposerEditor(text: $studio.draft, focused: $focused, selection: $selection, height: $editorHeight,
                focusRequest: focusRequest,
                placeholder: dropping ? "松开以添加图片" : studio.role.map { "发消息给\($0.name)…" } ?? "选择一个角色…",
                completion: suggestion, handle: handle, pasteImage: studio.pasteClipboardImages)
                .frame(height: editorHeight)
            toolbar(suggestion: suggestion)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 11)
                .fill(StudioPalette.raised.opacity(0.90))
        }
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
            if case .skill(let command) = token, command.query.isEmpty { return true }
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
        default:
            return
        }
        studio.draft = (studio.draft as NSString).replacingCharacters(in: range, with: insertion)
        selection = NSRange(location: range.location + insertion.utf16.count, length: 0)
        focused = true
    }

    private var queuedMessages: some View {
        let queue = studio.queuedTurns
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(queue) { queuedTray($0) }
            }
        }
        .frame(height: CGFloat(min(queue.count, 3)) * 34)
        .padding(.horizontal, 5)
        .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("待发消息")
    }

    private func queuedTray(_ queued: QueuedTurn) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(StudioPalette.accent)
                .accessibilityHidden(true)
            if let first = queued.images.first, let thumbnail = NSImage(data: first.data) {
                Image(nsImage: thumbnail).resizable().scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
            }
            if queued.text.isEmpty {
                Text("\(queued.images.count) 张图片").lineLimit(1)
            } else {
                Text(queued.text).lineLimit(1).help(queued.text)
                if !queued.images.isEmpty { Text("\(queued.images.count) 张图片") }
            }
            if let skill = queued.skill { Label(skill.name, systemImage: "puzzlepiece").lineLimit(1) }
            Spacer(minLength: 4)
            if queued.id == studio.submittedFollowUp {
                Text("已提交给 Hermes").font(.system(size: 11))
            } else if studio.runningConversation == nil {
                Button("发送") { studio.sendQueuedTurn(queued) }
                    .buttonStyle(.plain)
            }
            if queued.id != studio.submittedFollowUp {
                Button("移除待发消息", systemImage: "trash") { studio.cancelQueuedTurn(queued.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("移除待发消息")
                Menu {
                    if queued.id != studio.queuedTurns.first(where: { $0.id != studio.submittedFollowUp })?.id {
                        Button("下一条发送", systemImage: "arrow.up.to.line") { studio.prioritizeQueuedTurn(queued) }
                    }
                    Button("取回编辑", systemImage: "pencil") {
                        studio.editQueuedTurn(queued)
                        focused = true
                    }
                    .disabled(!studio.canEditQueuedTurn)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 18, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("更多待发消息操作")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(StudioPalette.muted)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var contextTray: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(studio.images) { image in
                    ZStack(alignment: .topTrailing) {
                        if let preview = NSImage(data: image.data) {
                            Image(nsImage: preview).resizable().scaledToFill()
                                .frame(width: 78, height: 61).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 7))
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
                    .help(image.image.name)
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
            if studio.isGeneratingHere {
                actionButton("停止回复", symbol: "stop.fill", action: studio.stop)
                actionButton("追加请求", symbol: "arrow.up", action: studio.send)
                    .disabled(!studio.canSend)
                    .help("在当前回复结束后自动发送")
            } else {
                actionButton("发送消息", symbol: "arrow.up", action: studio.send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!studio.canSend || studio.runningConversation != nil)
                    .help("回车发送 · Shift＋回车换行")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(StudioPalette.muted)
    }

    private func actionButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 31, height: 31) }
            .accessibilityLabel(label)
            .buttonStyle(ComposerActionStyle())
    }
}

private struct ComposerActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? StudioPalette.background : StudioPalette.muted)
            .background(enabled ? StudioPalette.ink : StudioPalette.selected, in: RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private enum ComposerChoice: Identifiable {
    case skill(HermesSkill)
    case native(HermesCompletion)

    var id: String {
        switch self {
        case .skill(let item): "skill:" + item.id
        case .native(let item): "native:" + item.id
        }
    }
    var title: String {
        switch self {
        case .skill(let item): item.name
        case .native(let item): item.display
        }
    }
    var detail: String {
        switch self {
        case .skill(let item): item.summary
        case .native(let item): item.detail
        }
    }
    var symbol: String {
        switch self {
        case .skill: "puzzlepiece.extension"
        case .native(let item):
            if item.text.hasPrefix("@folder") { "folder" }
            else if item.text.hasPrefix("@file") { "doc" }
            else { "terminal" }
        }
    }
}

private struct CompletionSuggestions: View {
    let matches: [ComposerChoice]
    let highlighted: Int
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
                Image(systemName: match.symbol)
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
