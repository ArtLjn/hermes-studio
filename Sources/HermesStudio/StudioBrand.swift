import AppKit
import SwiftUI

enum StudioBrand {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Hermes 暖光"

    static let logo: NSImage? = {
        let url = Bundle.main.url(forResource: "app-logo", withExtension: "png")
            ?? Bundle.module.url(forResource: "app-logo", withExtension: "png")
        return url.flatMap(NSImage.init(contentsOf:))
    }()
}
