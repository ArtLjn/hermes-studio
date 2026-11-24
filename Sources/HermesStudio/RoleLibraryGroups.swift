import SwiftUI
import UniformTypeIdentifiers

enum RoleLibraryDrag: Codable, Transferable {
    case role(UUID)
    case group(String)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.hermesstudio.role-library-item"))
    }
}

extension View {
    @ViewBuilder
    func roleLibraryDragSource(_ roleID: UUID?) -> some View {
        if let roleID { draggable(RoleLibraryDrag.role(roleID)) }
        else { self }
    }
}

struct RoleLibraryDropZone: ViewModifier {
    let group: String?
    let receive: (RoleLibraryDrag, String?) -> Bool
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .background(targeted ? StudioPalette.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(StudioPalette.accent, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: RoleLibraryDrag.self) { items, _ in
                guard items.count == 1, let item = items.first else { return false }
                return receive(item, group)
            } isTargeted: { targeted = $0 }
    }
}

struct RoleLibraryGroupBar: View {
    let groups: [String]
    @Binding var selection: RoleLibraryFilter
    let create: () -> Void
    let rename: (String) -> Void
    let receive: (RoleLibraryDrag, String?) -> Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("分组")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioPalette.muted)
                .fixedSize()
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    filter(.all, symbol: "square.grid.2x2")
                    ForEach(groups, id: \.self) { group in
                        filter(.group(group), symbol: "folder")
                            .draggable(RoleLibraryDrag.group(group))
                            .help("\(group) · 点击筛选，拖动排序")
                            .modifier(RoleLibraryDropZone(group: group, receive: receive))
                            .contextMenu {
                                Button("重命名分组", systemImage: "pencil") { rename(group) }
                            }
                    }
                    filter(.ungrouped, symbol: "tray")
                        .modifier(RoleLibraryDropZone(group: nil, receive: receive))
                }
            }
            .scrollIndicators(.hidden)
            Button("新建分组", systemImage: "folder.badge.plus", action: create)
                .buttonStyle(QuietButton())
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(StudioPalette.raised.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
    }

    private func filter(_ filter: RoleLibraryFilter, symbol: String) -> some View {
        let selected = selection == filter
        return Button { selection = filter } label: {
            Label(filter.title, systemImage: symbol)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .frame(maxWidth: 172)
                .padding(.horizontal, 8)
                .frame(height: 29)
                .contentShape(Rectangle())
        }
        .buttonStyle(StudioRowButton(selected: selected))
        .foregroundStyle(selected ? StudioPalette.accent : StudioPalette.muted)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct RoleLibraryGroupEditor: View {
    let group: String?
    let save: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(group: String? = nil, save: @escaping (String) throws -> Void) {
        self.group = group
        self.save = save
        _name = State(initialValue: group ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group == nil ? "新建分组" : "重命名分组")
                .font(.system(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            TextField("例如：工作协作", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("分组名称")
                .focused($nameFocused)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(StudioPalette.accent) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(group == nil ? "创建" : "保存") {
                    do {
                        try save(name)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .defaultFocus($nameFocused, true)
        .padding(20)
        .frame(width: 340)
    }
}
