import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ChatImage: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public let name: String
    public let mimeType: String

    var fileExtension: String {
        switch mimeType {
        case "image/jpeg": "jpg"
        case "image/webp": "webp"
        case "image/gif": "gif"
        default: "png"
        }
    }
}

public struct ImagePayload: Identifiable, Sendable {
    public let image: ChatImage
    public let data: Data
    public var id: UUID { image.id }
    public static let maxCount = 4
    private static let fileInputLimit = 24 * 1024 * 1024
    private static let rasterInputLimit = 96 * 1024 * 1024

    public static func load(_ url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let bytes = size.fileSize, bytes <= fileInputLimit else {
            throw StudioError.message("请选择 24 MB 以内的图片文件。")
        }
        return try prepare(name: url.lastPathComponent, data: Data(contentsOf: url))
    }

    public static func prepare(name: String, data: Data) throws -> Self {
        guard data.count <= rasterInputLimit else {
            throw StudioError.message("剪贴板图片超过 96 MB，请缩小后再试。")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let raster = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary) else {
            throw StudioError.message("无法读取这张图片。请使用 JPEG、PNG 或其他常见图片格式。")
        }
        let alpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(raster.alphaInfo)
        let type: UTType = alpha ? .png : .jpeg
        let encoded = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else {
            throw StudioError.message("无法处理这张图片。")
        }
        CGImageDestinationAddImage(dest, raster, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest), encoded.length <= 5 * 1024 * 1024 else {
            throw StudioError.message("图片处理后仍超过 5 MB，请缩小图片后重试。")
        }
        return Self(image: ChatImage(name: name, mimeType: alpha ? "image/png" : "image/jpeg"), data: encoded as Data)
    }
}

public struct ToolRun: Codable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let status: String?
    public let details: String?
    public let kind: String?

    public init(id: String, title: String?, status: String?, details: String?, kind: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.details = details
        self.kind = kind
    }

    public func updating(with next: ToolRun) -> ToolRun {
        ToolRun(id: id, title: next.title ?? title, status: next.status ?? status, details: next.details ?? details,
            kind: next.kind ?? kind)
    }

    public var isRunning: Bool { status == nil || status == "pending" || status == "in_progress" }

    public var category: String {
        if let kind, kind != "other" { return kind }
        let name = title?.split(separator: ":", maxSplits: 1).first?.lowercased() ?? ""
        switch name {
        case "terminal", "process": return "execute"
        case "read_file", "skill_view": return "read"
        case "search_files", "web_search": return "search"
        case "patch", "write_file": return "edit"
        default: return "other"
        }
    }
}
