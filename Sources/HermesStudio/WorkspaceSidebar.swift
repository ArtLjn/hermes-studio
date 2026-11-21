import SwiftUI

struct WorkspaceSidebar<Content: View>: View {
    @ObservedObject var studio: StudioModel
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let logo = StudioBrand.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 23, height: 23)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                }
                Text(StudioBrand.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 37)
            .padding(.bottom, 13)

            content
                .frame(maxHeight: .infinity, alignment: .topLeading)

            StudioRule()
            Button(action: studio.refreshRuntime) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(studio.available ? StudioPalette.connected : StudioPalette.muted)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(studio.available ? "本机 Hermes" : "未检测到 Hermes")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(StudioPalette.muted)
                .padding(.horizontal, 8)
                .frame(height: 31)
            }
            .buttonStyle(StudioRowButton())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .help(studio.modelName.isEmpty ? "重新检测本机 Hermes" : "\(studio.modelName) · 点击重新检测")
        }
        .frame(maxHeight: .infinity)
        .background(StudioPalette.sidebar.opacity(0.68))
    }
}

struct WorkspaceNavLabel: View {
    let title: String
    let symbol: String
    var selected = false

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(selected ? StudioPalette.accent : StudioPalette.muted)
                .frame(width: 17)
        }
        .font(.system(size: 12, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? StudioPalette.ink : StudioPalette.muted)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }
}
