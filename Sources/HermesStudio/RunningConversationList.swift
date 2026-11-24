import StudioCore
import SwiftUI

struct RunningConversationList: View {
    let conversations: [StudioModel.RunningConversation]
    let selectedID: UUID?
    let store: RoleStore
    let open: (StudioModel.RunningConversation) -> Void

    private let rowHeight: CGFloat = 36
    private let visibleRows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("进行中").accessibilityAddTraits(.isHeader)
                Spacer()
                Text(conversations.count, format: .number)
                    .monospacedDigit()
                    .accessibilityLabel("\(conversations.count) 条对话")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(StudioPalette.muted)
            .padding(.horizontal, 8)
            .frame(height: 24)

            if conversations.count > visibleRows {
                ScrollView { rows }
                    .frame(height: rowHeight * CGFloat(visibleRows))
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(conversations) { conversation in
                let selected = conversation.id == selectedID
                Button { open(conversation) } label: {
                    HStack(spacing: 8) {
                        RolePortrait(role: conversation.role, store: store, size: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .foregroundStyle(StudioPalette.ink)
                            Text(conversation.role.name)
                                .font(.system(size: 10))
                                .foregroundStyle(StudioPalette.muted)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        ConversationActivityIndicator(awaitingApproval: conversation.status == .awaitingApproval)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioRowButton(selected: selected))
                .accessibilityLabel("\(conversation.role.name)，\(conversation.title)")
                .accessibilityValue(conversation.status.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help("\(conversation.role.name) · \(conversation.title) · \(conversation.status.label)")
            }
        }
    }
}

struct ConversationActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var awaitingApproval = false

    var body: some View {
        Group {
            if awaitingApproval {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            } else if reduceMotion {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(StudioPalette.accent)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}
