import AppKit
import ImageIO
import SwiftUI

struct WallpaperSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var desktop = DesktopWallpaper()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DesktopMaterial(transparent: !reduceTransparency, observe: desktop.attach)
                StudioPalette.background.opacity(reduceTransparency ? 1 : 0.74)
                if !reduceTransparency, let image = desktop.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width + 150, height: geometry.size.height + 150)
                        .clipped()
                        .blur(radius: 74, opaque: true)
                        .saturation(0.42)
                        .opacity(0.24)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: reduceTransparency) {
            guard !reduceTransparency else { return }
            while !Task.isCancelled {
                desktop.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
}

@MainActor
private final class DesktopWallpaper: ObservableObject {
    @Published private(set) var image: CGImage?
    private weak var window: NSWindow?
    private var source: Source?

    private struct Source: Equatable {
        let url: URL
        let modified: Date?
    }

    func attach(_ window: NSWindow?) {
        self.window = window
        refresh()
    }

    func refresh() {
        let next = (window?.screen ?? NSScreen.main)
            .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            .map { url in
                Source(url: url, modified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            }
        guard next != source else { return }
        source = next
        image = next.flatMap { thumbnail(at: $0.url) }
    }

    private func thumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private struct DesktopMaterial: NSViewRepresentable {
    let transparent: Bool
    let observe: (NSWindow?) -> Void

    func makeNSView(context: Context) -> DesktopEffectView {
        let view = DesktopEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.observe = observe
        view.transparent = transparent
        return view
    }

    func updateNSView(_ view: DesktopEffectView, context: Context) {
        if view.transparent != transparent { view.transparent = transparent }
    }
}

private final class DesktopEffectView: NSVisualEffectView {
    var observe: ((NSWindow?) -> Void)?
    var transparent = true {
        didSet { updateWindow() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            observe?(window)
        }
    }

    private func updateWindow() {
        alphaValue = transparent ? 1 : 0
        window?.isOpaque = !transparent
        window?.backgroundColor = transparent ? .clear : NSColor(StudioPalette.background)
    }
}
