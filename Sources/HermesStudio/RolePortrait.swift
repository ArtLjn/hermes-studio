import AppKit
import StudioCore
import SwiftUI

struct RolePortrait: View {
    let image: NSImage?
    let symbol: String
    let tint: Color
    let size: CGFloat

    init(role: Role, store: RoleStore, size: CGFloat) {
        let avatar = role.avatar ?? RoleIllustration(template: role.template).map(RoleAvatar.illustration)
        image = switch avatar {
        case .illustration(let portrait): Self.illustration(portrait)
        case .custom(let file): NSImage(contentsOf: store.imageURL(file, for: role.id))
        case .symbol, nil: nil
        }
        symbol = roleSymbol(role)
        tint = roleTint(role)
        self.size = size
    }

    init(image: NSImage?, symbol: String, tint: Color = StudioPalette.accent, size: CGFloat) {
        self.image = image
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tint.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        .accessibilityHidden(true)
    }

    static func illustration(_ item: RoleIllustration) -> NSImage? {
        illustrations[item]
    }

    private static let illustrations: [RoleIllustration: NSImage] = Dictionary(uniqueKeysWithValues:
        RoleIllustration.allCases.compactMap { item in
            let url = Bundle.main.url(forResource: item.rawValue, withExtension: "jpg", subdirectory: "Avatars")
                ?? Bundle.module.url(forResource: item.rawValue, withExtension: "jpg", subdirectory: "Avatars")
            return url.flatMap(NSImage.init(contentsOf:)).map { (item, $0) }
        })
}
