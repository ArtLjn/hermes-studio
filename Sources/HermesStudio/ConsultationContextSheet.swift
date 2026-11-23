import StudioCore
import SwiftUI

struct ConsultationContextExcerpt: View {
    let entry: RoleConsultation.ContextEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.speaker)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioPalette.muted)
            Text(entry.text).font(.system(size: 12)).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConsultationContextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let review: ConsultationContextReview
    let store: RoleStore
    let confirm: (Set<UUID>) -> Void
    @State private var selection: Set<UUID>

    init(review: ConsultationContextReview, store: RoleStore, confirm: @escaping (Set<UUID>) -> Void) {
        self.review = review
        self.store = store
        self.confirm = confirm
        _selection = State(initialValue: review.selectedIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RolePortrait(role: review.target, store: store, size: 26)
                Text("选要附给\(review.target.name)的前文").font(.headline)
            }
            Text("发送问题时，会附上勾选的文字。")
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(review.entries) { entry in
                        Toggle(isOn: Binding(get: { selection.contains(entry.id) }, set: {
                            if $0 { selection.insert(entry.id) } else { selection.remove(entry.id) }
                        })) {
                            ConsultationContextExcerpt(entry: entry)
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        if entry.id != review.entries.last?.id { StudioRule().padding(.leading, 30) }
                    }
                }
                .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 7))
            }
            .frame(minHeight: 120, maxHeight: 315)
            StudioRule()
            HStack {
                Button("仅发送问题") {
                    confirm([])
                    dismiss()
                }
                Spacer()
                Button("返回") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("附带 \(selection.count) 条") {
                    confirm(selection)
                    dismiss()
                }
                .disabled(selection.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}
