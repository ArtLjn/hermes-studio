import StudioCore
import SwiftUI

struct ChatPane: View {
    @ObservedObject var studio: StudioModel
    @State private var composerFocused = true
    @State private var composerFocusRequest = UUID()
    @State private var handoffReview: RoleHandoffReview?
    @State private var dismissedHandoffID: UUID?

    private var pinnedHandoff: Message? {
        guard let request = studio.conversation?.messages.last(where: { $0.author == .user && $0.isGuidance != true }),
            request.id != dismissedHandoffID, request.handoff?.brief != nil else { return nil }
        return request
    }

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = studio.conversation {
                if let origin = conversation.handoffOrigin {
                    Button("查看\(origin.roleName)的来源对话", systemImage: "arrow.turn.up.left") {
                        studio.openHandoffConversation(origin.conversationID, roleID: origin.roleID)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .frame(maxWidth: StudioPalette.transcriptWidth, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                }
                transcript(conversation)
            } else if let role = studio.role {
                ChatWelcome(studio: studio, role: role, composer: composerArea) { prompt in
                    studio.draft = prompt
                    composerFocused = true
                    composerFocusRequest = UUID()
                }
            } else {
                Spacer()
            }
            if let error = studio.chatError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Button("关闭提示", systemImage: "xmark", action: studio.dismissChatError)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                }
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.accent)
                .padding(10)
                .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: StudioPalette.transcriptWidth)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)
            }
            if studio.conversation != nil || studio.role == nil {
                composerArea
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: studio.conversationID) { _, _ in composerFocused = true }
        .sheet(item: $handoffReview) { review in
            RoleHandoffReviewSheet(review: review, cancel: { handoffReview = nil }) {
                handoffReview = nil
                studio.sendHandoff(review)
            }
        }
    }

    private var composerArea: some View {
        VStack(spacing: 7) {
                if let request = pinnedHandoff, let handoff = request.handoff {
                    RoleHandoffCard(studio: studio, request: request, handoff: handoff, preparing: false,
                        review: { handoffReview = $0 }, dismiss: { dismissedHandoffID = request.id })
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 7))
                }
                if let permission = studio.activePermission {
                    let runtimeWorkspace = studio.role.map { studio.store.runtime(for: $0.id).appendingPathComponent("workspace") }
                    ToolPermissionCard(permission: permission, editPolicy: studio.runSettings?.editApproval?.value,
                        workspace: studio.project?.directory ?? runtimeWorkspace,
                        workspaceName: studio.project?.name ?? "角色工作区", stop: studio.stop) { option in
                        studio.respond(to: permission, option: option)
                    }
                    .id(permission.id)
                }
                ChatComposer(studio: studio, focused: $composerFocused, focusRequest: composerFocusRequest)
            }
            .frame(maxWidth: StudioPalette.transcriptWidth)
    }

    private func transcript(_ thread: Conversation) -> some View {
        let turns = ChatTurn.collect(thread.messages)
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(turns) { turn in
                            transcriptRow(turn, roleID: thread.roleID, isLast: turn.id == turns.last?.id)
                        }
                        Color.clear.frame(height: 1).id("chat-end")
                    }
                    .frame(maxWidth: StudioPalette.transcriptWidth)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: thread.messages.count) { _, _ in
                    if studio.isGeneratingHere { proxy.scrollTo("chat-end", anchor: .bottom) }
                }
                .onChange(of: thread.messages.last?.text.count) { _, _ in
                    if studio.isGeneratingHere { proxy.scrollTo("chat-end", anchor: .bottom) }
                }
                .onChange(of: turns.last.flatMap { studio.consultationText(for: $0.id) }) { _, text in
                    if text != nil { proxy.scrollTo("chat-end", anchor: .bottom) }
                }
                .onChange(of: studio.isGeneratingHere) { _, running in
                    if !running { proxy.scrollTo("chat-end", anchor: .bottom) }
                }
                .onChange(of: studio.activePermission?.id) { _, request in
                    if request != nil { proxy.scrollTo("chat-end", anchor: .bottom) }
                }
            }
        }
        .id(thread.id)
    }

    private func transcriptRow(_ turn: ChatTurn, roleID: UUID, isLast: Bool) -> some View {
        let liveText = studio.consultationText(for: turn.id)
        let active = studio.isConsultingHere ? liveText != nil : isLast
        let restoreRequest: (() -> Void)? = turn.canRestoreRequest ? {
            if studio.restoreUnansweredMessage(turn.id) {
                composerFocused = true
                composerFocusRequest = UUID()
            }
        } : nil
        return VStack(alignment: .leading, spacing: 10) {
            ChatTurnRow(turn: turn, role: studio.role, store: studio.store, roleID: roleID,
                activity: active ? studio.activity : nil, restoreRequest: restoreRequest,
                canRestoreRequest: studio.canRestoreMessage)
            if let request = turn.request, let handoff = request.handoff, request.id != pinnedHandoff?.id {
                RoleHandoffCard(studio: studio, request: request, handoff: handoff,
                    preparing: studio.isPreparingHandoff && isLast, review: { handoffReview = $0 })
            }
            if let request = turn.request, let consultation = request.consultation {
                let retry: (() -> Void)? = studio.isGeneratingHere
                    || !studio.roles.contains(where: { $0.id == consultation.targetRoleID }) ? nil : {
                        studio.retryConsultation(request.id)
                    }
                RoleConsultationReply(consultation: consultation, role: studio.consultationRole(consultation),
                    store: studio.store, liveText: liveText, quote: {
                        studio.quoteConsultation(request.id)
                        composerFocused = true
                        composerFocusRequest = UUID()
                    }, retry: retry)
            }
        }
    }

}
