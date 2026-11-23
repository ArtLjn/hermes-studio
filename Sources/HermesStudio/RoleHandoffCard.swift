import StudioCore
import SwiftUI

struct RoleHandoffCard: View {
    @ObservedObject var studio: StudioModel
    let request: Message
    let handoff: RoleHandoff
    let preparing: Bool
    let review: (RoleHandoffReview) -> Void
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .accessibilityHidden(true)
            if preparing {
                Text(handoff.isQuestion == true ? "正在拟问题…" : "正在整理交接摘要…")
            } else if handoff.isQuestion == true, studio.hasSentQuestion(request.id) {
                Text("问题已发送，回复在当前对话")
            } else if let target = studio.roles.first(where: { $0.id == handoff.targetRoleID }) {
                if let destination = studio.handoffDestination(for: request) {
                    Text(studio.handoffReceiptStatus(for: destination, recipient: target.name))
                    if destination.archivedAt == nil {
                        Button {
                            studio.openHandoffConversation(destination.id, roleID: target.id)
                        } label: {
                            Text("打开接手对话").fontWeight(.semibold).foregroundStyle(StudioPalette.accent)
                        }
                        .buttonStyle(.link)
                    }
                } else if handoff.brief != nil {
                    Text(handoff.isQuestion == true ? "问题已拟好 · 待发送" : "交接摘要已准备 · 待发送")
                    Button {
                        if let prepared = studio.reviewHandoff(request) { review(prepared) }
                    } label: {
                        Text(handoff.isQuestion == true ? "审阅问题" : "审阅并发送给\(target.name)")
                            .fontWeight(.semibold)
                            .foregroundStyle(StudioPalette.accent)
                    }
                    .buttonStyle(.link)
                    .disabled(handoff.isQuestion == true && studio.isGeneratingHere)
                } else {
                    Text(handoff.isQuestion == true ? "问题未拟好，可以重新发起" : "交接摘要未完成，可以重新发起")
                }
            } else {
                Text("接收助手已不可用")
            }
            if let dismiss {
                Spacer(minLength: 4)
                Button("收起协作状态", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(StudioPalette.muted)
    }
}

struct RoleHandoffReviewSheet: View {
    let review: RoleHandoffReview
    let cancel: () -> Void
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(review.isQuestion ? "向\(review.target.name)提问" : "交接给\(review.target.name)")
                .font(.headline)
            Text(review.isQuestion
                ? "接收助手会收到下面的问题，回复会回到当前对话。"
                : "确认后，接收助手将在新对话中按下面的内容接手。")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(review.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 170, maxHeight: 330)
            Divider()
            HStack {
                Spacer()
                Button("返回", action: cancel).keyboardShortcut(.cancelAction)
                Button(review.isQuestion ? "发送问题" : "确认交接", action: send)
            }
        }
        .padding(22)
        .frame(width: 530)
    }
}
