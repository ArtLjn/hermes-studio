import StudioCore
import SwiftUI

struct RolePickerButton: View {
    let roles: [Role]
    let selected: Role?
    let store: RoleStore
    var compact = false
    var selectTerminal: (() -> Void)?
    var runningConversations: [StudioModel.RunningConversation] = []
    var selectedConversationID: UUID?
    var openRunningConversation: ((StudioModel.RunningConversation) -> Void)?
    let select: (Role) -> Void
    @State private var showing = false

    private var name: String { selected?.name ?? "终端 Hermes" }

    var body: some View {
        let byRole = Dictionary(grouping: runningConversations, by: \.role.id)
        let selectedRuns = selected.flatMap { byRole[$0.id] } ?? []
        let indicatedRuns = compact ? runningConversations : selectedRuns
        Button { showing.toggle() } label: {
            if compact {
                portrait(selected, size: 23)
                    .frame(width: 36, height: 34)
                    .overlay(alignment: .topTrailing) {
                        if !indicatedRuns.isEmpty {
                            activity(indicatedRuns)
                                .background(StudioPalette.sidebar, in: Circle())
                                .offset(x: 2, y: -1)
                        }
                    }
            } else {
                HStack(spacing: 8) {
                    portrait(selected, size: 21)
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    activity(indicatedRuns, showsCount: true)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(StudioPalette.muted)
                        .accessibilityHidden(true)
                }
                .frame(height: 30)
                .padding(.horizontal, 5)
            }
        }
        .buttonStyle(StudioRowButton(selected: showing))
        .foregroundStyle(StudioPalette.ink)
        .accessibilityLabel("选择对话角色")
        .accessibilityValue(indicatedRuns.isEmpty ? name : "\(name)，\(indicatedRuns.count) 条对话进行中")
        .help("切换角色")
        .popover(isPresented: $showing, arrowEdge: compact ? .leading : .top) {
            VStack(spacing: 4) {
                if let openRunningConversation, !runningConversations.isEmpty {
                    RunningConversationList(conversations: runningConversations, selectedID: selectedConversationID, store: store) {
                        showing = false
                        openRunningConversation($0)
                    }
                    StudioRule()
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(roles) { role in
                            option(role.name, role: role, checked: selected?.id == role.id, running: byRole[role.id] ?? []) {
                                if selected?.id != role.id { select(role) }
                            }
                        }
                        if let selectTerminal {
                            option("终端 Hermes", role: nil, checked: selected == nil, action: selectTerminal)
                        }
                    }
                }
                .frame(height: CGFloat(min(roles.count + (selectTerminal == nil ? 0 : 1), 7)) * 33)
            }
            .frame(width: 198)
            .padding(6)
            .background(StudioPalette.sidebar)
        }
    }

    @ViewBuilder
    private func portrait(_ role: Role?, size: CGFloat) -> some View {
        if let role { RolePortrait(role: role, store: store, size: size) }
        else { RolePortrait(image: nil, symbol: "terminal", size: size) }
    }

    @ViewBuilder
    private func activity(_ running: [StudioModel.RunningConversation], showsCount: Bool = false) -> some View {
        if !running.isEmpty {
            HStack(spacing: 2) {
                ConversationActivityIndicator(awaitingApproval: running.allSatisfy { $0.status == .awaitingApproval })
                if showsCount, running.count > 1 {
                    Text(running.count, format: .number)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(StudioPalette.muted)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func option(_ title: String, role: Role?, checked: Bool,
        running: [StudioModel.RunningConversation] = [], action: @escaping () -> Void) -> some View {
        Button {
            showing = false
            action()
        } label: {
            HStack(spacing: 8) {
                portrait(role, size: 19)
                Text(title).lineLimit(1)
                Spacer(minLength: 3)
                activity(running, showsCount: true)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(checked ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(StudioPalette.ink)
            .font(.system(size: 12))
            .padding(.horizontal, 7)
            .frame(height: 31)
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioRowButton())
        .accessibilityLabel(title)
        .accessibilityValue(running.isEmpty ? "" : "\(running.count) 条对话进行中")
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
