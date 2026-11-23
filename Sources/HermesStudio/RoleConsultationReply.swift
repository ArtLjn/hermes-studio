import StudioCore
import SwiftUI

struct RoleConsultationReply: View {
    let consultation: RoleConsultation
    let role: Role?
    let store: RoleStore
    var liveText: String?
    var quote: (() -> Void)?
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let role {
                    RolePortrait(role: role, store: store, size: 26)
                } else {
                    Image(systemName: "person.crop.circle").accessibilityHidden(true)
                }
                Text(role?.name ?? consultation.targetName).fontWeight(.semibold)
                Text("协作回复").foregroundStyle(StudioPalette.muted)
                Spacer(minLength: 6)
                if consultation.status == .answered, let quote {
                    Button("引用给当前助手", systemImage: "quote.bubble", action: quote)
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: 12))
            if let reply = liveText ?? consultation.answer, !reply.isEmpty {
                MarkdownReply(text: TextOnlyReply.parse(reply).text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if liveText == nil {
                HStack(spacing: 8) {
                    Text(statusLabel)
                    if let retry {
                        Button("重试", action: retry).buttonStyle(.link)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.muted)
            }
        }
    }

    private var statusLabel: String {
        switch consultation.status {
        case .pending: "这次提问未完成"
        case .failed: "未收到完整回复"
        case .stopped: "已停止提问"
        case .answered: "回复内容不可用"
        }
    }
}
