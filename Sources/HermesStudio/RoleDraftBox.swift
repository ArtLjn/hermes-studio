import StudioCore
import SwiftUI

struct RoleDraftBox: View {
    @ObservedObject var studio: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("角色草稿箱").font(.system(size: 22, weight: .semibold))
                Text("移入后可在 30 天内恢复角色、记忆和会话。")
                    .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
            }
            if studio.archivedRoles.isEmpty {
                Label("草稿箱为空", systemImage: "tray")
                    .font(.system(size: 13)).foregroundStyle(StudioPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 125)
                    .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 9))
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(studio.archivedRoles) { role in
                            HStack(spacing: 10) {
                                RolePortrait(role: role, store: studio.store, size: 34)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(role.name).font(.system(size: 13, weight: .semibold))
                                    if let deadline = role.archiveDeadline {
                                        Text("可恢复至 \(deadline.formatted(.dateTime.month().day().hour().minute()))")
                                            .font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                                    }
                                }
                                Spacer()
                                Button("恢复", systemImage: "arrow.uturn.backward") { restore(role) }
                                    .buttonStyle(QuietButton())
                                    .accessibilityLabel("恢复\(role.name)")
                            }
                            .padding(9)
                            .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
                .frame(maxHeight: 305)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(StudioPalette.accent) }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton())
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(.regularMaterial)
        .onAppear { studio.refreshArchive() }
    }

    private func restore(_ role: Role) {
        error = nil
        do { try studio.restoreRole(role.id) }
        catch {
            self.error = error.localizedDescription
            studio.refreshArchive()
        }
    }
}
