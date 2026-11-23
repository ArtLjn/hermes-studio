import AppKit
import SwiftUI

struct ChatImagePreviewButton<Thumbnail: View>: View {
    let name: String
    let image: NSImage
    var fileURL: URL? = nil
    @ViewBuilder let thumbnail: () -> Thumbnail

    var body: some View {
        Button {
            ChatImagePreviewWindow.shared.show(name: name, image: image, fileURL: fileURL)
        } label: {
            thumbnail().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("放大图片 \(name)")
        .help("放大图片")
    }
}

@MainActor
private final class ChatImagePreviewWindow: NSObject, NSWindowDelegate {
    static let shared = ChatImagePreviewWindow()
    private var panel: ChatImagePanel?
    private var fileURL: URL?

    func show(name: String, image: NSImage, fileURL: URL?) {
        panel?.close()
        let source = NSApp.keyWindow ?? NSApp.mainWindow
        let available = source?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let target = source?.frame.size ?? CGSize(width: 900, height: 650)
        let size = CGSize(width: min(1080, target.width - 44, (available?.width ?? 1120) - 40),
            height: min(760, target.height - 60, (available?.height ?? 800) - 56))
        let panel = ChatImagePanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = name
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentMinSize = CGSize(width: 310, height: 230)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        let content = NSView()
        let picture = NSImageView(image: image)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.setAccessibilityLabel(name)
        picture.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(picture)
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            picture.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            picture.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            picture.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14)
        ])
        panel.contentView = content
        if let fileURL, let symbol = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil) {
            self.fileURL = fileURL
            let action = NSButton(image: symbol, target: self, action: #selector(openOriginal))
            action.isBordered = false
            action.toolTip = "在系统预览中打开"
            action.setAccessibilityLabel("在系统预览中打开")
            action.frame = CGRect(x: 0, y: 0, width: 34, height: 24)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = action
            accessory.layoutAttribute = .right
            panel.addTitlebarAccessoryViewController(accessory)
        }
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        fileURL = nil
    }

    @objc private func openOriginal() {
        if let fileURL { NSWorkspace.shared.open(fileURL) }
    }
}

private final class ChatImagePanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}
