import AppKit
import StudioCore
import SwiftUI

struct ChatMessageRow: View {
    let message: Message
    let role: Role?
    let store: RoleStore
    let roleID: UUID
    var showsAssistantHeader = true
    private var isUser: Bool { message.author == .user }

    var body: some View {
        VStack(alignment: .leading, spacing: isUser ? 5 : 9) {
            if isUser {
                if message.isGuidance == true || message.skill != nil { header }
            } else if message.author != .assistant || showsAssistantHeader {
                header
            }
            if let images = message.images, !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(images) { image in
                            attachment(image)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if !message.text.isEmpty {
                if message.author == .assistant {
                    MarkdownReply(text: message.text)
                } else {
                    Text(message.text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, isUser ? 13 : 0)
        .padding(.vertical, isUser ? 9 : 0)
        .background(isUser ? StudioPalette.raised.opacity(0.88) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .frame(maxWidth: isUser ? 520 : .infinity, alignment: isUser ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var header: some View {
        HStack(spacing: 7) {
            if message.author == .assistant, let role {
                RolePortrait(role: role, store: store, size: 26)
            } else if !isUser {
                Image(systemName: "sparkle")
                    .foregroundStyle(StudioPalette.accent)
                    .accessibilityHidden(true)
            }
            if !isUser || message.isGuidance == true {
                Text(isUser ? "追问" : role?.name ?? "Hermes")
                    .fontWeight(.semibold)
                    .foregroundStyle(isUser ? StudioPalette.muted : StudioPalette.ink)
            }
            if let skill = message.skill {
                Label(skill, systemImage: "puzzlepiece")
                    .font(.system(size: 10))
                    .foregroundStyle(StudioPalette.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(StudioPalette.selected, in: Capsule())
            }
            if !isUser {
                Spacer()
                if message.author == .assistant && !message.text.isEmpty {
                    CopyControl("复制回复", value: message.text)
                }
            }
        }
        .font(.system(size: isUser ? 11 : 12))
    }

    private func attachment(_ attachment: ChatImage) -> some View {
        let url = store.imageURL(attachment, for: roleID)
        return Button {
            NSWorkspace.shared.open(url)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 101)
                        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Label("图片不可用", systemImage: "photo")
                }
                Text(attachment.name)
                    .lineLimit(1)
                    .font(.system(size: 10))
                    .foregroundStyle(StudioPalette.muted)
            }
            .padding(6)
            .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开图片 \(attachment.name)")
    }
}

private struct MarkdownReply: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text).font(.system(size: 14)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inline(text).font(.system(size: level == 1 ? 22 : level == 2 ? 18 : 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        case .code(let language, let text):
            codeBlock(language, text: text)
        case .quote(let text):
            inline(text).font(.system(size: 13)).lineSpacing(4).foregroundStyle(StudioPalette.muted)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(StudioPalette.accent.opacity(0.65)).frame(width: 2) }
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.marker)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(StudioPalette.accent)
                            .frame(minWidth: 22, alignment: .trailing)
                        inline(item.text).font(.system(size: 14)).lineSpacing(4)
                    }
                }
            }
        case .table(let rows):
            table(rows)
        case .rule:
            Rectangle().fill(StudioPalette.line).frame(height: 1)
        }
    }

    private func inline(_ text: String) -> Text {
        let value = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(value ?? AttributedString(text))
    }

    private func codeBlock(_ language: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(language.isEmpty ? "代码" : language, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioPalette.muted)
                Spacer()
                CopyControl("复制代码", value: text)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(StudioPalette.sidebar)
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(3)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(11)
            }
        }
        .background(Color.black.opacity(0.23), in: RoundedRectangle(cornerRadius: 8))
    }

    private func table(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 1
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { row, values in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            inline(column < values.count ? values[column] : "")
                                .font(.system(size: 12, weight: row == 0 ? .semibold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .frame(minWidth: 58, maxWidth: 260, alignment: .leading)
                                .background(row == 0 ? StudioPalette.raised : .clear)
                                .overlay(alignment: .bottom) { Rectangle().fill(StudioPalette.line).frame(height: 1) }
                        }
                    }
                }
            }
            .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct ToolRunCard: View {
    let tool: ToolRun
    @State private var expanded = false

    private var finished: Bool { !tool.isRunning }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            let details = tool.details ?? (finished ? "Hermes 没有提供更多详情。" : "等待工具返回…")
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Spacer()
                    if tool.details != nil { CopyControl("复制工具输出", value: details) }
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(details).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 205)
            }
            .padding(.leading, 16)
        } label: {
            HStack(spacing: 7) {
                if finished {
                    Image(systemName: tool.status == "completed" ? "checkmark.circle" : "exclamationmark.circle")
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(tool.title ?? "Hermes 工具").lineLimit(1)
                Spacer()
                Text(tool.status == "completed" ? "已完成" : tool.status == "failed" ? "失败" : tool.status == "cancelled" ? "已停止" : finished ? "已结束" : "执行中")
                    .foregroundStyle(StudioPalette.muted)
            }
        }
        .font(.system(size: 12))
        .padding(.vertical, 4)
    }
}

private struct CopyControl: View {
    let label: String
    let value: String
    @State private var copied = false

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            copied = pasteboard.setString(value, forType: .string)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(StudioPalette.muted)
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(copied ? "已复制" : label)
        .onChange(of: value) { _, _ in copied = false }
    }
}
