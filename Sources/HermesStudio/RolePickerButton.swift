import StudioCore
import SwiftUI

struct RolePickerButton: View {
    let roles: [Role]
    let selected: Role?
    let store: RoleStore
    var compact = false
    var selectTerminal: (() -> Void)?
    let select: (Role) -> Void
    @State private var showing = false

    private var name: String { selected?.name ?? "终端 Hermes" }

    var body: some View {
        Button { showing.toggle() } label: {
            if compact {
                portrait(selected, size: 23)
                    .frame(width: 36, height: 34)
            } else {
                HStack(spacing: 8) {
                    portrait(selected, size: 21)
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
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
        .accessibilityValue(name)
        .help("切换角色")
        .popover(isPresented: $showing, arrowEdge: compact ? .leading : .top) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(roles) { role in
                        option(role.name, role: role, checked: selected?.id == role.id) {
                            if selected?.id != role.id { select(role) }
                        }
                    }
                    if let selectTerminal {
                        option("终端 Hermes", role: nil, checked: selected == nil, action: selectTerminal)
                    }
                }
            }
            .frame(width: 198, height: CGFloat(min(roles.count + (selectTerminal == nil ? 0 : 1), 7)) * 33)
            .padding(6)
            .background(StudioPalette.sidebar)
        }
    }

    @ViewBuilder
    private func portrait(_ role: Role?, size: CGFloat) -> some View {
        if let role { RolePortrait(role: role, store: store, size: size) }
        else { RolePortrait(image: nil, symbol: "terminal", size: size) }
    }

    private func option(_ title: String, role: Role?, checked: Bool, action: @escaping () -> Void) -> some View {
        Button {
            showing = false
            action()
        } label: {
            HStack(spacing: 8) {
                portrait(role, size: 19)
                Text(title).lineLimit(1)
                Spacer(minLength: 3)
                if checked {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(StudioPalette.ink)
            .font(.system(size: 12))
            .padding(.horizontal, 7)
            .frame(height: 31)
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioRowButton())
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
