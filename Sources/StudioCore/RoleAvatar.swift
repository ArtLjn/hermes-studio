import Foundation

public enum RoleIllustration: String, CaseIterable, Codable, Identifiable, Sendable {
    case nuannuan, sunrise, lavender, booklight
    case fox, cat, owl

    public static let people: [Self] = [.nuannuan, .sunrise, .lavender, .booklight]
    public static let animals: [Self] = [.fox, .cat, .owl]

    public var id: Self { self }

    public var label: String {
        switch self {
        case .nuannuan: "暖光短发"
        case .sunrise: "晨光卷发"
        case .lavender: "暮紫长发"
        case .booklight: "书灯倩影"
        case .fox: "狐狸"
        case .cat: "猫"
        case .owl: "猫头鹰"
        }
    }

    public init?(template: RoleTemplate) {
        switch template {
        case .general: self = .fox
        case .engineering: self = .cat
        case .writing: self = .owl
        case .blank: return nil
        }
    }
}

public enum RoleAvatar: Codable, Equatable, Sendable {
    case illustration(RoleIllustration)
    case custom(ChatImage)
    case symbol
}
