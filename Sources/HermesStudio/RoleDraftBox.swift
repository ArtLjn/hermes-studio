import StudioCore
import SwiftUI

struct RoleDraftBox: View {
    @ObservedObject var studio: StudioModel
    @State private var error: String?
    @State private var pendingDeletion: Role?
    @State private var confirmsDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("角色草稿箱").font(.system(size: 26, weight: .semibold))
                Text("移入后可在 30 天内恢复角色、记忆和会话。")
                    .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
            }
            if studio.archivedRoles.isEmpty {
                Label("草稿箱为空", systemImage: "tray")
                    .font(.system(size: 13)).foregroundStyle(StudioPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 125)
                    .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 9))
            } else {
                    LazyVStack(spacing: 0) {
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
                                Button("删除", systemImage: "trash") {
                                    pendingDeletion = role
                                    confirmsDeletion = true
                                }
                                .buttonStyle(QuietButton())
                                .accessibilityLabel("删除\(role.name)")
                            }
                            .padding(.vertical, 10)
                            StudioRule()
                        }
                    }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(StudioPalette.accent) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { studio.refreshArchive() }
        .alert("删除角色？", isPresented: $confirmsDeletion, presenting: pendingDeletion) { role in
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("移到废纸篓", role: .destructive) {
                error = nil
                do { try studio.deleteArchivedRole(role.id) }
                catch { self.error = error.localizedDescription }
                pendingDeletion = nil
            }
        } message: { role in
            Text("「\(role.name)」及其本地记忆、对话和角色目录内的文件将移到 macOS 废纸篓。")
        }
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
