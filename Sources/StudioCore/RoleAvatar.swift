import Foundation

public enum RoleIllustration: String, CaseIterable, Codable, Identifiable, Sendable {
    case nuannuan, sunrise, lavender, booklight
    case mistBlueBob, roseBraid, sageGlasses, apricotCurls
    case mauveWaves, butterHalfUp, pearlBob, jadeBun
    case fox, cat, owl

    public static let people: [Self] = [
        .nuannuan, .sunrise, .lavender, .booklight,
        .mistBlueBob, .roseBraid, .sageGlasses, .apricotCurls,
        .mauveWaves, .butterHalfUp, .pearlBob, .jadeBun
    ]
    public static let animals: [Self] = [.fox, .cat, .owl]

    public var id: Self { self }

    public var label: String {
        switch self {
        case .nuannuan: "暖光短发"
        case .sunrise: "晨光卷发"
        case .lavender: "暮紫长发"
        case .booklight: "书灯倩影"
        case .mistBlueBob: "雾蓝短发"
        case .roseBraid: "豆沙粉侧辫"
        case .sageGlasses: "鼠尾草绿圆框眼镜"
        case .apricotCurls: "焦糖杏卷发"
        case .mauveWaves: "烟紫波浪长发"
        case .butterHalfUp: "奶油黄半扎发"
        case .pearlBob: "珍珠耳钉短发"
        case .jadeBun: "青绿盘发"
        case .fox: "狐狸"
        case .cat: "猫"
        case .owl: "猫头鹰"
        }
    }

    var matchingDescription: String {
        switch self {
        case .nuannuan: "亲切、柔和、自然"
        case .sunrise: "开朗、有活力、暖色"
        case .lavender: "安静、温柔、带梦幻感"
        case .booklight: "复古、文艺、红棕色与眼镜"
        case .mistBlueBob: "清爽、冷静、蓝色"
        case .roseBraid: "甜美、柔和、粉色"
        case .sageGlasses: "知性、随和、绿针织与圆框眼镜"
        case .apricotCurls: "轻松、温暖、杏橘色"
        case .mauveWaves: "沉静、柔和、灰紫色"
        case .butterHalfUp: "明快、友好、奶油黄色"
        case .pearlBob: "利落、典雅、酒红色与珍珠耳钉"
        case .jadeBun: "从容、自然、青绿与盘发"
        case .fox: "机灵、好奇的动物插画"
        case .cat: "安静、独立的动物插画"
        case .owl: "沉稳、博学的动物插画"
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
