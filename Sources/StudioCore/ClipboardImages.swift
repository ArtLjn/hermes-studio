import AppKit
import UniformTypeIdentifiers

public enum ClipboardImages {
    case files([URL])
    case pixels([Data])

    public static func canRead(from clipboard: NSPasteboard) -> Bool {
        clipboard.types?.contains { $0 == .fileURL || isImageType($0) } == true
    }

    public static func read(from clipboard: NSPasteboard) -> Self? {
        let files = (clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { url in
                url.isFileURL && ((try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
                    || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true)
            }
        if !files.isEmpty { return .files(files) }
        let preferred: [NSPasteboard.PasteboardType] = [.png, NSPasteboard.PasteboardType(UTType.jpeg.identifier), .tiff]
        let images = (clipboard.pasteboardItems ?? []).prefix(ImagePayload.maxCount + 1).compactMap { item in
            let ordered = (preferred + item.types).filter(isImageType)
            return ordered.lazy.compactMap { item.data(forType: $0) }.first(where: { !$0.isEmpty })
        }
        return images.isEmpty ? nil : .pixels(images)
    }

    private static func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
        UTType(type.rawValue)?.conforms(to: .image) == true
    }
}
