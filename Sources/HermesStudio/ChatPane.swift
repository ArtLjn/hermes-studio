import StudioCore
import SwiftUI

struct ChatPane: View {
    @ObservedObject var studio: StudioModel
    @State private var composerFocused = true
    @State private var composerFocusRequest = UUID()

    var body: some View {
        VStack(spacing: 0) {
            if let conversation = studio.conversation {
                transcript(conversation)
            } else if let role = studio.role {
                ChatWelcome(studio: studio, role: role) { prompt in
                    studio.draft = prompt
                    composerFocused = true
                    composerFocusRequest = UUID()
                }
            } else {
                Spacer()
            }
            if let error = studio.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Button("关闭提示", systemImage: "xmark") {
                        studio.error = nil
                    }
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
            ChatComposer(studio: studio, focused: $composerFocused, focusRequest: composerFocusRequest)
                .frame(maxWidth: StudioPalette.transcriptWidth)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: studio.conversationID) { _, _ in composerFocused = true }
        .sheet(item: Binding(get: { studio.activePermission }, set: { _ in })) { permission in
            ToolPermissionSheet(permission: permission) { option in studio.respond(to: permission, option: option) }
                .interactiveDismissDisabled()
        }
    }

    private func transcript(_ thread: Conversation) -> some View {
        let turns = ChatTurn.collect(thread.messages)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(turns) { turn in
                        ChatTurnRow(turn: turn, role: studio.role, store: studio.store, roleID: thread.roleID,
                            activity: studio.isGeneratingHere && turn.id == turns.last?.id ? studio.activity : nil)
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                }
                .frame(maxWidth: StudioPalette.transcriptWidth)
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: thread.id, initial: true) { _, _ in proxy.scrollTo("chat-end", anchor: .bottom) }
            .onChange(of: thread.messages.count) { _, _ in
                if studio.isGeneratingHere { proxy.scrollTo("chat-end", anchor: .bottom) }
            }
            .onChange(of: thread.messages.last?.text.count) { _, _ in
                if studio.isGeneratingHere { proxy.scrollTo("chat-end", anchor: .bottom) }
            }
            .onChange(of: studio.isGeneratingHere) { _, running in
                if !running { proxy.scrollTo("chat-end", anchor: .bottom) }
            }
        }
    }

}
