import StudioCore
import SwiftUI

struct ChatWelcome<Composer: View>: View {
    @ObservedObject var studio: StudioModel
    let role: Role
    let composer: Composer
    let insert: (String) -> Void
    @State private var result: (Context, [String])?
    @State private var request: (context: Context, id: UUID)?

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
        let context = studio.available && studio.roleID == role.id && role.terminalSource == nil
            ? Context(role: role, project: studio.project,
                memory: studio.roleFiles[.memory, default: ""], user: studio.roleFiles[.user, default: ""])
            : nil
        let personalized = result.flatMap { $0.0 == context ? $0.1 : nil } ?? []

        GeometryReader { geometry in
            let compact = geometry.size.width < 440
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introduction(compact: compact)
                    composer
                    ChatWelcomeRecommendations(template: role.template, personalized: personalized,
                        loading: request?.context == context && request != nil, compact: compact,
                        roleSummary: role.summary, insert: insert)
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, compact ? 18 : 28)
                .padding(.vertical, compact ? 22 : 30)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
        .task(id: context) {
            guard let context, context.hasMemory, result?.0 != context else { return }
            let id = UUID()
            request = (context, id)
            defer { if request?.id == id { request = nil } }
            let suggestions = (try? await studio.suggestConversationStarters(role: context.role, memory: context.memory,
                user: context.user, projectName: context.project?.name)) ?? []
            guard !Task.isCancelled, request?.id == id else { return }
            result = (context, suggestions)
        }
    }

    private func introduction(compact: Bool) -> some View {
        let summary = role.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .center, spacing: 12) {
            RolePortrait(role: role, store: studio.store, size: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(role.name)
                    .font(.system(size: compact ? 20 : 23, weight: .medium))
                    .foregroundStyle(StudioPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(StudioPalette.muted)
                        .lineLimit(1)
                        .help(summary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatWelcomeRecommendations: View {
    let template: RoleTemplate
    let personalized: [String]
    let loading: Bool
    let compact: Bool
    var roleSummary: String = ""
    let insert: (String) -> Void

    private struct Item: Identifiable {
        let title: String
        let detail: String?
        let icon: String
        let prompt: String

        var id: String { prompt }
    }

    var body: some View {
        let items = personalized.isEmpty ? defaults : personalized.map {
            Item(title: $0, detail: nil, icon: "text.bubble", prompt: $0)
        }
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(personalized.isEmpty ? "从这里开始" : "接着聊")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioPalette.muted)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if loading && personalized.isEmpty {
                    ProgressView().controlSize(.mini)
                        .help("正在准备与角色记忆相关的开场建议")
                }
            }
            .padding(.horizontal, 2)

            if personalized.isEmpty && !compact {
                HStack(spacing: 8) {
                    ForEach(items) { item in row(item) }
                }
            } else {
                VStack(spacing: 3) {
                    ForEach(items) { item in row(item) }
                }
            }
        }
    }

    private func row(_ item: Item) -> some View {
        Button {
            insert(item.prompt)
        } label: {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.muted)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.muted)
                    .lineLimit(personalized.isEmpty ? 1 : 3)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                if !personalized.isEmpty {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioPalette.muted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(WelcomeRecommendationButtonStyle())
        .help(item.prompt)
        .accessibilityLabel(item.detail.map { "\(item.title)，\($0)" } ?? item.title)
        .accessibilityHint("填入消息输入框")
    }

    private var defaults: [Item] {
        if ["服务器", "运维", "Linux", "SRE"].contains(where: roleSummary.localizedCaseInsensitiveContains) {
            return [
                Item(title: "排查连接问题", detail: nil, icon: "network",
                    prompt: "帮我排查这个连接问题，先确认现象和需要核对的证据："),
                Item(title: "检查资源占用", detail: nil, icon: "cpu",
                    prompt: "帮我分析服务器的资源占用，先从哪些信息看起？"),
                Item(title: "复核变更方案", detail: nil, icon: "checkmark.shield",
                    prompt: "帮我复核这份变更方案，重点检查风险和回滚步骤：")
            ]
        }
        if ["女朋友", "陪伴", "闲聊"].contains(where: roleSummary.contains) {
            return [
                Item(title: "聊聊今天", detail: nil, icon: "sun.max", prompt: "今天有件事想跟你聊聊。"),
                Item(title: "分享一件小事", detail: nil, icon: "text.bubble", prompt: "想跟你分享一件小事。"),
                Item(title: "随便聊聊", detail: nil, icon: "cup.and.saucer", prompt: "现在想找你随便聊聊。")
            ]
        }
        return switch template {
        case .engineering:
            [
                Item(title: "拆解需求", detail: "明确最小交付范围和实现顺序", icon: "list.bullet.indent",
                    prompt: "帮我把这个需求拆成最小可交付版本："),
                Item(title: "排查故障", detail: "从报错和现有证据找出下一步", icon: "wrench.and.screwdriver",
                    prompt: "帮我分析这个故障，列出优先排查的证据："),
                Item(title: "梳理回归测试", detail: "根据改动找出最值得验证的用例", icon: "checkmark.circle",
                    prompt: "请根据下面的改动梳理关键回归用例：")
            ]
        case .writing:
            [
                Item(title: "起草说明", detail: "把零散要点写成一份清楚的更新说明", icon: "square.and.pencil",
                    prompt: "请把这些要点写成一份清晰简短的更新说明："),
                Item(title: "润色段落", detail: "保留原意，让措辞更自然", icon: "text.quote",
                    prompt: "帮我把这段文字改得更自然，保留原意："),
                Item(title: "精简文字", detail: "删去重复，保留读者需要的事实", icon: "line.3.horizontal.decrease",
                    prompt: "帮我压缩下面的文字，保留读者需要的事实：")
            ]
        case .general, .blank:
            [
                Item(title: "整理待办", detail: "排出优先级，明确每件事的下一步", icon: "checklist",
                    prompt: "帮我梳理下面这些待办，排出优先级和下一步："),
                Item(title: "整理会议纪要", detail: "从会议记录提取决策和待办", icon: "doc.text",
                    prompt: "请根据下面的记录整理会议纪要，列出决策和待办："),
                Item(title: "设定协作偏好", detail: "告诉助手以后怎样与你配合", icon: "slider.horizontal.3",
                    prompt: "请记住我在协作时的这些偏好：")
            ]
        }
    }
}

private struct WelcomeRecommendationButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.09 : hovered ? 0.055 : 0.018),
                in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
    }
}
