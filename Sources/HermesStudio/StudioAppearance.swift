import SwiftUI

enum StudioPalette {
    static let background = Color(red: 0.087, green: 0.087, blue: 0.091)
    static let sidebar = Color(red: 0.11, green: 0.11, blue: 0.115)
    static let raised = Color(red: 0.15, green: 0.15, blue: 0.156)
    static let selected = Color(red: 0.21, green: 0.21, blue: 0.224)
    static let line = Color.white.opacity(0.085)
    static let outline = Color.white.opacity(0.17)
    static let ink = Color(red: 0.951, green: 0.951, blue: 0.959)
    static let muted = Color(red: 0.698, green: 0.698, blue: 0.726)
    static let accent = Color(red: 0.67, green: 0.74, blue: 0.88)
    static let connected = Color(red: 0.47, green: 0.78, blue: 0.66)

    static let sidebarWidth: CGFloat = 220
    static let sidebarRailWidth: CGFloat = 52
    static let toolbarHeight: CGFloat = 56
    static let transcriptWidth: CGFloat = 740
}

struct StudioRule: View {
    var body: some View {
        Rectangle()
            .fill(StudioPalette.line)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

struct StudioRowButton: ButtonStyle {
    var selected = false
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected || configuration.isPressed ? StudioPalette.selected
                        : hovered ? StudioPalette.line : .clear)
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

struct StudioIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioPalette.muted)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(StudioRowButton())
        .accessibilityLabel(title)
        .help(title)
    }
}

struct StudioPrimaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 33)
                .foregroundStyle(StudioPalette.background)
                .background(StudioPalette.ink, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

struct QuietButton: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(hovered || configuration.isPressed ? StudioPalette.selected : StudioPalette.raised,
                in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(StudioPalette.ink)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}
