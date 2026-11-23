import AppKit
import StudioCore
import SwiftUI
import UniformTypeIdentifiers

enum GroupRecipient: Hashable {
    case topic, everyone, member(UUID), members([UUID])

    var memberID: UUID? {
        if case .member(let id) = self { return id }
        return nil
    }

    var memberIDs: [UUID] {
        if case .members(let ids) = self { return ids }
        return memberID.map { [$0] } ?? []
    }

    func selecting(_ recipient: Self, toggle: Bool) -> Self {
        guard let id = recipient.memberID else { return recipient }
        var ids = memberIDs
        if ids.contains(id) {
            guard toggle else { return self }
            ids.removeAll { $0 == id }
        } else {
            ids.append(id)
        }
        if ids.isEmpty { return .topic }
        return ids.count == 1 ? .member(ids[0]) : .members(ids)
    }

    static let everyoneName = "所有人"
}

struct GroupComposerDraft {
    var text = ""
    var recipient: GroupRecipient = .topic
    var attachments: [GroupAttachment] = []
}

struct GroupComposer<Status: View>: View {
    let members: [Role]
    let store: RoleStore
    @Binding var draft: GroupComposerDraft
    let available: Bool
    let status: Status
    let report: (String) -> Void
    let submit: (GroupRecipient, String, [GroupAttachment]) -> Bool
    @State private var focused = true
    @State private var focusRequest = UUID()
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var height: CGFloat = 32
    @State private var highlighted = 0
    @State private var dismissedDraft: String?
    @State private var choosingFiles = false
    @State private var choosingRecipients = false

    private var speaker: Role? { members.first { $0.id == draft.recipient.memberID } }
    private var recipientNames: [String] {
        draft.recipient.memberIDs.map { id in members.first { $0.id == id }?.name ?? "成员已移除" }
    }
    private var recipientTitle: String {
        switch draft.recipient {
        case .topic: "群聊话题"
        case .everyone: "@\(GroupRecipient.everyoneName)"
        case .member, .members: recipientNames.map { "@\($0)" }.joined(separator: " ")
        }
    }

    private var canSend: Bool {
        available && !members.isEmpty && draft.recipient.memberIDs.allSatisfy { id in members.contains { $0.id == id } }
            && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty)
    }

    private var placeholder: String {
        switch draft.recipient {
        case .topic: "发个话题，大家都可以接话…"
        case .everyone: "问所有人…"
        case .member: "问\(recipientNames[0])…"
        case .members: "问选中的助手…"
        }
    }

    private var mention: (word: String, range: NSRange)? {
        guard focused, selection.length == 0, dismissedDraft != draft.text else { return nil }
        return HermesCompletion.reference(at: selection.location, in: draft.text)
    }

    private var candidates: [GroupRecipient] {
        guard let mention else { return [] }
        let query = String(mention.word.dropFirst())
        let people = members.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map { GroupRecipient.member($0.id) }
        if !members.isEmpty && (query.isEmpty || GroupRecipient.everyoneName.hasPrefix(query)) {
            return [.everyone] + people
        }
        return people
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            status
            if !candidates.isEmpty { suggestions }
            VStack(alignment: .leading, spacing: 6) {
                if !draft.attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 5) {
                            ForEach(draft.attachments) { file in
                                HStack(spacing: 5) {
                                    if let image = file.image,
                                        let thumbnail = NSImage(contentsOf: GroupDiscussionStore(root: store.root).imageURL(image)) {
                                        Image(nsImage: thumbnail).resizable().scaledToFill()
                                            .frame(width: 42, height: 42).clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    } else {
                                        Label(file.name, systemImage: "doc").lineLimit(1)
                                    }
                                    Button {
                                        draft.attachments.removeAll { $0.id == file.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("移除 \(file.name)")
                                }
                                .font(.system(size: 11))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(StudioPalette.selected, in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                ComposerEditor(text: $draft.text, focused: $focused, selection: $selection, height: $height,
                    focusRequest: focusRequest, placeholder: placeholder,
                    completion: nil, handle: handle, pasteImage: pasteImages)
                    .frame(height: height)
                toolbar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(focused ? StudioPalette.accent.opacity(0.42) : StudioPalette.outline)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: draft.text) { _, _ in highlighted = 0; dismissedDraft = nil }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            importFiles(.success(urls))
            return true
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.image, .plainText, .sourceCode, .json, .xml],
            allowsMultipleSelection: true) { result in importFiles(result) }
    }

    private var suggestions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(candidates.enumerated()), id: \.element) { index, recipient in
                        let role = members.first { $0.id == recipient.memberID }
                        Button { choose(recipient, replacingMention: true) } label: {
                            HStack(spacing: 8) {
                                if let role {
                                    RolePortrait(role: role, store: store, size: 22)
                                } else {
                                    RolePortrait(image: nil, symbol: "person.2.fill", size: 22)
                                }
                                Text("@\(role?.name ?? GroupRecipient.everyoneName)")
                                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 4)
                                if index == highlighted {
                                    Image(systemName: "return").font(.system(size: 10)).foregroundStyle(StudioPalette.muted)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(StudioRowButton(selected: index == highlighted))
                        .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                        .id(index)
                    }
                }
            }
            .frame(height: CGFloat(min(candidates.count, 5)) * 33)
            .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
        }
        .padding(4)
        .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(StudioPalette.line).allowsHitTesting(false) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("添加群聊图片或资料", systemImage: "paperclip") { choosingFiles = true }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .help("添加图片、UTF-8 文本、代码或 JSON 资料")
            recipientPicker
            Spacer(minLength: 4)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canSend ? StudioPalette.background : StudioPalette.muted)
                    .frame(width: 30, height: 30)
                    .background(canSend ? StudioPalette.ink : StudioPalette.selected, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("发送群聊消息")
            .help("回车发送 · Shift＋回车换行")
            .disabled(!canSend)
        }
        .font(.system(size: 12))
        .foregroundStyle(StudioPalette.muted)
    }

    private var recipientPicker: some View {
        let removed = draft.recipient.memberIDs.filter { id in !members.contains { $0.id == id } }
        return Button { choosingRecipients.toggle() } label: {
            HStack(spacing: 5) {
                if let speaker { RolePortrait(role: speaker, store: store, size: 17) }
                Text(recipientTitle).lineLimit(1).frame(maxWidth: 240)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 5)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioRowButton(selected: choosingRecipients))
        .foregroundStyle(StudioPalette.accent)
        .fixedSize()
        .accessibilityLabel("发给")
        .accessibilityValue(recipientTitle)
        .help("\(recipientTitle)\n点击选择或取消成员，也可以在输入框连续输入 @ 点名")
        .popover(isPresented: $choosingRecipients, arrowEdge: .top) {
            VStack(spacing: 4) {
                recipientOption("群聊话题", .topic)
                recipientOption("@\(GroupRecipient.everyoneName)", .everyone).disabled(members.isEmpty)
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(members) { role in recipientOption("@\(role.name)", .member(role.id)) }
                        ForEach(removed, id: \.self) { id in recipientOption("成员已移除", .member(id)) }
                    }
                }
                .frame(height: CGFloat(min(members.count + removed.count, 6)) * 29)
                Button("完成") {
                    choosingRecipients = false
                    focused = true
                    focusRequest = UUID()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: 198)
            .padding(8)
        }
    }

    private func recipientOption(_ title: String, _ recipient: GroupRecipient) -> some View {
        let checked = draft.recipient == recipient || recipient.memberID.map(draft.recipient.memberIDs.contains) == true
        return Button { choose(recipient, replacingMention: false) } label: {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if checked { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .font(.system(size: 12))
            .foregroundStyle(checked ? StudioPalette.accent : StudioPalette.ink)
            .padding(.horizontal, 7)
            .frame(height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioRowButton(selected: checked))
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func handle(_ key: ComposerKey) -> Bool {
        let matches = candidates
        switch key {
        case .send, .complete:
            if !matches.isEmpty {
                choose(matches[min(highlighted, matches.count - 1)], replacingMention: true)
                return true
            }
            if key == .send { send(); return true }
            return false
        case .up, .down:
            guard !matches.isEmpty else { return false }
            let step = key == .up ? matches.count - 1 : 1
            highlighted = (min(highlighted, matches.count - 1) + step) % matches.count
            return true
        case .dismiss:
            guard mention != nil else { return false }
            dismissedDraft = draft.text
            return true
        case .acceptInline:
            return false
        }
    }

    private func choose(_ recipient: GroupRecipient, replacingMention: Bool) {
        if replacingMention, let mention {
            draft.text = (draft.text as NSString).replacingCharacters(in: mention.range, with: "")
            selection = NSRange(location: mention.range.location, length: 0)
            focused = true
        }
        draft.recipient = draft.recipient.selecting(recipient, toggle: !replacingMention)
    }

    private func send() {
        guard canSend, submit(draft.recipient, draft.text, draft.attachments) else { return }
        draft = GroupComposerDraft()
    }

    private func pasteImages() -> Bool {
        guard let content = ClipboardImages.read(from: .general) else { return false }
        switch content {
        case .files(let urls): importFiles(.success(urls))
        case .pixels(let data):
            do {
                guard draft.attachments.count + data.count <= 4 else {
                    throw StudioError.message("一条消息最多可添加四份图片或资料。")
                }
                let images = try data.map { try ImagePayload.prepare(name: "剪贴板图片", data: $0) }
                let groupStore = GroupDiscussionStore(root: store.root)
                draft.attachments += try images.map { try groupStore.saveImage($0) }
            } catch { report(error.localizedDescription) }
        }
        return true
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard draft.attachments.count + urls.count <= 4 else {
                report("一条消息最多可添加四份图片或资料。")
                return
            }
            let files = try urls.map { url in
                let authorized = url.startAccessingSecurityScopedResource()
                defer { if authorized { url.stopAccessingSecurityScopedResource() } }
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                    return try GroupDiscussionStore(root: store.root).saveImage(ImagePayload.load(url))
                }
                return try GroupAttachment(file: url)
            }
            draft.attachments += files
        } catch {
            report(error.localizedDescription)
        }
    }
}
