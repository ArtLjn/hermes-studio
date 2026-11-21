import StudioCore
import SwiftUI

struct ChatTurnRow: View {
    let turn: ChatTurn
    let role: Role?
    let store: RoleStore
    let roleID: UUID
    let activity: String?
    @State private var showingProcess = false

    var body: some View {
        let running = activity != nil
        let content = turn.presentation(running: running)
        let olderFollowUps = turn.messages.filter { $0.isGuidance == true }
        let execution = content.process.filter { !$0.messages.contains(where: { $0.isGuidance == true }) }
        VStack(alignment: .leading, spacing: 15) {
            if let request = turn.request { row(request) }
            ForEach(olderFollowUps) { row($0) }
            if !execution.isEmpty {
                if running {
                    process(execution)
                } else {
                    DisclosureGroup(isExpanded: $showingProcess) {
                        process(execution)
                            .padding(.top, 9)
                    } label: {
                        Label(processLabel, systemImage: "clock")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(StudioPalette.muted)
                    }
                }
            }
            ForEach(content.reply) { message in
                row(message, showsAssistantHeader: message.id == content.reply.first?.id)
            }
            if let activity, !activity.isEmpty, !content.process.flatMap(\.tools).contains(where: \.isRunning) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(activity)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .foregroundStyle(StudioPalette.muted)
            }
        }
        .onChange(of: running, initial: true) { _, running in
            if !running { showingProcess = content.reply.isEmpty }
        }
    }

    private var processLabel: String {
        guard let seconds = turn.request?.workDuration, seconds >= 1 else { return "执行过程" }
        let duration = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        return "执行过程 · \(duration)"
    }

    private func row(_ message: Message, showsAssistantHeader: Bool = true) -> some View {
        ChatMessageRow(message: message, role: role, store: store, roleID: roleID,
            showsAssistantHeader: showsAssistantHeader)
    }

    private func process(_ activities: [ChatTurn.Activity]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(activities) { activity in
                if activity.tools.isEmpty {
                    ForEach(activity.messages) { row($0, showsAssistantHeader: false) }
                } else {
                    ToolActivityRow(tools: activity.tools)
                }
            }
        }
    }
}

private struct ToolActivityRow: View {
    let tools: [ToolRun]
    @State private var expanded = false

    private var summary: String {
        let counts = Dictionary(grouping: tools, by: \.category).mapValues(\.count)
        let actions = [("read", "读取"), ("search", "搜索"), ("edit", "编辑"), ("delete", "删除"),
            ("move", "移动"), ("execute", "运行命令"), ("fetch", "访问网页")]
        let known = actions.compactMap { kind, label in counts[kind].map { "\(label) \($0) 次" } }
        let others = tools.count - actions.reduce(0) { $0 + (counts[$1.0] ?? 0) }
        return (known + (others > 0 ? ["调用工具 \(others) 次"] : [])).joined(separator: " · ")
    }

    var body: some View {
        let running = tools.filter(\.isRunning).count
        let failed = tools.filter { $0.status == "failed" }.count
        let stopped = tools.filter { $0.status == "cancelled" }.count
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(tools, id: \.id) { ToolRunCard(tool: $0) }
            }
            .padding(.leading, 8)
            .padding(.top, 5)
        } label: {
            HStack(spacing: 7) {
                if running > 0 {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "wrench.and.screwdriver")
                        .accessibilityHidden(true)
                }
                Text(summary).lineLimit(1)
                Spacer(minLength: 6)
                if running > 0 { Text("\(running) 项执行中") }
                if failed > 0 { Text("\(failed) 项失败").foregroundStyle(StudioPalette.accent) }
                if stopped > 0 { Text("\(stopped) 项停止") }
            }
            .font(.system(size: 12))
            .foregroundStyle(StudioPalette.muted)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(StudioPalette.raised.opacity(0.48), in: RoundedRectangle(cornerRadius: 7))
    }
}
