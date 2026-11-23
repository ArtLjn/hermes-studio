import Foundation

public struct GroupToolPermissions: Codable, Equatable, Sendable {
    public var terminal = true
    public var files = true
    public var web = true
    public var browser = true
    public var externalMCP = true
    public var skills = true
    public var invitations = true
    public var sharedLinks = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case terminal, files, web, browser, externalMCP, skills, invitations, sharedLinks
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        terminal = try values.decodeIfPresent(Bool.self, forKey: .terminal) ?? true
        files = try values.decodeIfPresent(Bool.self, forKey: .files) ?? true
        web = try values.decodeIfPresent(Bool.self, forKey: .web) ?? true
        browser = try values.decodeIfPresent(Bool.self, forKey: .browser) ?? true
        externalMCP = try values.decodeIfPresent(Bool.self, forKey: .externalMCP) ?? true
        skills = try values.decodeIfPresent(Bool.self, forKey: .skills) ?? true
        invitations = try values.decodeIfPresent(Bool.self, forKey: .invitations) ?? true
        sharedLinks = try values.decodeIfPresent(Bool.self, forKey: .sharedLinks) ?? true
    }

    public var toolsets: [String]? {
        guard !(terminal && files && web && browser && externalMCP && skills) else { return nil }
        var result: [String] = []
        if terminal { result.append("terminal") }
        if files { result.append("file") }
        if web { result.append("web") }
        if browser { result.append("browser") }
        if skills { result.append("skills") }
        return result
    }

    public func restricted(by member: Self?) -> Self {
        guard let member else { return self }
        var result = self
        result.terminal = terminal && member.terminal
        result.files = files && member.files
        result.web = web && member.web
        result.browser = browser && member.browser
        result.externalMCP = externalMCP && member.externalMCP
        result.skills = skills && member.skills
        result.invitations = invitations && member.invitations
        result.sharedLinks = sharedLinks && member.sharedLinks
        return result
    }
}
