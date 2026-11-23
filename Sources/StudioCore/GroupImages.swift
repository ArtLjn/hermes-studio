import Foundation

extension GroupDiscussionStore {
    public func imageURL(_ image: ChatImage) -> URL {
        root.appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(image.id.uuidString).appendingPathExtension(image.fileExtension)
    }

    public func saveImage(_ payload: ImagePayload) throws -> GroupAttachment {
        let file = imageURL(payload.image)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.data.write(to: file, options: .atomic)
        return GroupAttachment(image: payload.image)
    }

    public func images(in discussion: GroupDiscussion, for turn: GroupTurn) throws -> [ImagePayload] {
        try discussion.attachments(for: turn).compactMap { attachment in
            guard let image = attachment.image else { return nil }
            let file = imageURL(image)
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5 * 1024 * 1024 else {
                throw StudioError.message("群聊图片不可用，请重新发送。")
            }
            return ImagePayload(image: image, data: try Data(contentsOf: file))
        }
    }
}
