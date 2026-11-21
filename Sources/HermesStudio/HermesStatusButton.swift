import StudioCore
import SwiftUI

struct HermesStatusButton: View {
    @ObservedObject var studio: StudioModel
    @State private var presented = false

    private var updateAvailable: Bool {
        if case .available = studio.hermesUpdate?.status { return true }
        return false
    }

    var body: some View {
        Button {
            if !presented { studio.checkForHermesUpdates() }
            presented.toggle()
        } label: {
            Image(systemName: updateAvailable ? "arrow.down.circle" : "terminal")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(updateAvailable ? StudioPalette.accent : StudioPalette.muted)
                .frame(width: 36, height: 34)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(studio.available ? StudioPalette.connected : StudioPalette.muted)
                        .frame(width: 6, height: 6)
                        .padding(4)
                        .accessibilityHidden(true)
                }
        }
        .buttonStyle(StudioRowButton(selected: presented))
        .accessibilityLabel(studio.available ? "本机 Hermes，检测更新" : "未检测到本机 Hermes")
        .accessibilityValue(updateAvailable ? "有可用更新" : "")
        .help(helpText)
        .popover(isPresented: $presented, attachmentAnchor: .point(UnitPoint(x: 0.7, y: 0)), arrowEdge: .top) {
            HermesUpdatePopover(studio: studio)
        }
    }

    private var helpText: String {
        guard studio.available else { return "重新检测本机 Hermes" }
        return studio.modelName.isEmpty ? "检测 Hermes CLI 更新" : "\(studio.modelName) · 检测 Hermes CLI 更新"
    }
}

private struct HermesUpdatePopover: View {
    @ObservedObject var studio: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hermes CLI 更新")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if let version = studio.hermesUpdate?.installedVersion {
                Text("当前版本 \(version)").foregroundStyle(StudioPalette.muted)
            }
            if !studio.available {
                Text("未检测到本机 Hermes")
            } else if studio.checkingHermesUpdate {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("正在检测更新…")
                }
            } else if let status = studio.hermesUpdate?.status {
                result(status)
            }
            StudioRule()
            HStack(spacing: 8) {
                Button("重新检测本机") {
                    studio.refreshRuntime()
                    studio.checkForHermesUpdates()
                }
                .buttonStyle(QuietButton())
                .disabled(!studio.canRefreshRuntime || studio.checkingHermesUpdate)
                if studio.available {
                    Button("再次检测更新", action: studio.checkForHermesUpdates)
                        .buttonStyle(QuietButton())
                        .disabled(studio.checkingHermesUpdate)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(StudioPalette.ink)
        .padding(14)
        .frame(width: 266, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func result(_ status: HermesUpdateCheck.Status) -> some View {
        switch status {
        case .available(let version):
            Text(version.map { "发现新版本 \($0)" } ?? "发现新版本")
                .fontWeight(.semibold)
            Text("在终端运行 `hermes update`，完成后重启暖光。")
                .foregroundStyle(StudioPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .upToDate:
            Text("已是最新版本")
        case .noUpdate:
            Text("当前没有可用更新")
        case .managedExternally:
            Text("请通过安装 Hermes 时使用的工具检测更新。")
        case .failed:
            Text("无法检测更新。请检查网络，或在终端运行 `hermes update --check` 查看详情。")
        case .timedOut:
            Text("检测超时。请检查网络后重试。")
        }
    }
}
