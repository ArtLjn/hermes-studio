import Foundation

enum StudioBrand {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Hermes 暖光"

}
