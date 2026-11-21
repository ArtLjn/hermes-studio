import StudioCore
import SwiftUI

struct ChatWelcome: View {
    @ObservedObject var studio: StudioModel
    let role: Role
    let insert: (String) -> Void
    @State private var result: (Context, [String])?
    @State private var hovered: String?

    private struct Context: Equatable {
        let role: Role
        let project: StudioProject?
        let memory: String
        let user: String

        var hasMemory: Bool {
            [memory, user].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    var body: some View {
        let context = studio.available && studio.roleID == role.id && role.terminalSource == nil ? Context(role: role, project: studio.project,
            memory: studio.roleFiles[.memory, default: ""], user: studio.roleFiles[.user, default: ""]) : nil
        let personalized = result.flatMap { $0.0 == context ? $0.1 : nil } ?? []

        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introduction
                    VStack(alignment: .leading, spacing: 10) {
                        Text(personalized.isEmpty ? "从这里开始" : "根据角色记忆推荐")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(StudioPalette.muted)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 9)], alignment: .leading, spacing: 9) {
                            if personalized.isEmpty {
                                ForEach(defaults, id: \.title) { item in
                                    shortcut(item.title, icon: item.icon, prompt: item.prompt)
                                }
                            } else {
                                ForEach(personalized, id: \.self) { question in
                                    shortcut(question, icon: "sparkle", prompt: question)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: StudioPalette.transcriptWidth)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
        .task(id: context) {
            guard let context, context.hasMemory, result?.0 != context else { return }
            let suggestions = (try? await studio.suggestConversationStarters(role: context.role, memory: context.memory,
                user: context.user, projectName: context.project?.name)) ?? []
            guard !Task.isCancelled else { return }
            result = (context, suggestions)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                RolePortrait(role: role, store: studio.store, size: 31)
                Text(role.name).font(.system(size: 24, weight: .semibold)).accessibilityAddTraits(.isHeader)
            }
            Text(greeting)
                .font(.system(size: 13))
                .foregroundStyle(StudioPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcut(_ title: String, icon: String, prompt: String) -> some View {
        let active = hovered == title
        return Button { insert(prompt) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(StudioPalette.muted)
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.down.left").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(active ? StudioPalette.ink : StudioPalette.muted)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(active ? StudioPalette.selected : StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(active ? StudioPalette.outline : StudioPalette.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = title }
            else if hovered == title { hovered = nil }
        }
        .help(prompt)
        .accessibilityHint("填入消息输入框")
    }

    private var greeting: String {
        switch role.template {
        case .engineering: "遇到什么开发问题了？把需求、代码或报错发给我，我们一起看看。"
        case .writing: "今天想写什么？可以从一个想法、一段原稿，或一句还没写顺的话开始。"
        case .general: "你好，今天想做些什么？把手头的事发给我，我们一起理顺。"
        case .blank: "你好！把你想处理的事发给我，我们从那里开始。"
        }
    }

    private var defaults: [(title: String, icon: String, prompt: String)] {
        switch role.template {
        case .engineering:
            [
                ("拆解需求", "list.bullet", "帮我把这个需求拆成最小可交付版本："),
                ("排查故障", "magnifyingglass", "帮我分析这个故障，列出优先排查的证据："),
                ("梳理测试", "checklist", "请根据下面的改动梳理关键回归用例：")
            ]
        case .writing:
            [
                ("起草说明", "square.and.pencil", "请把这些要点写成一份清晰简短的更新说明："),
                ("润色段落", "pencil", "帮我把这段文字改得更自然，保留原意："),
                ("精简文字", "text.alignleft", "帮我压缩下面的文字，保留读者需要的事实：")
            ]
        case .general, .blank:
            [
                ("整理待办", "checklist", "帮我梳理下面这些待办，排出优先级和下一步："),
                ("整理会议纪要", "doc.text", "请根据下面的记录整理会议纪要，列出决策和待办："),
                ("设定协作偏好", "slider.horizontal.3", "请记住我在协作时的这些偏好：")
            ]
        }
    }
}
