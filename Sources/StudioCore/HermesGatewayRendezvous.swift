import CryptoKit
import Darwin
import Foundation

enum HermesGatewayRendezvous {
    static let copiedNames = ["gateway.sock", "gateway.sock.path", "gateway.pid", "gateway.lock"]

    static func cleanRelocatedPointer(in home: URL) throws {
        let runtime = home.resolvingSymlinksInPath()
        let parent = runtime.deletingLastPathComponent()
        let pointer = runtime.appendingPathComponent("gateway.sock.path")
        let pidFile = runtime.appendingPathComponent("gateway.pid")
        guard runtime.lastPathComponent == "runtime",
            UUID(uuidString: parent.lastPathComponent) != nil,
            parent.deletingLastPathComponent().lastPathComponent == "roles",
            isMissing(runtime.appendingPathComponent("gateway.sock")),
            let marker = readMarker(pointer, prohibitedPermissions: 0o077),
            let owner = readMarker(pidFile, prohibitedPermissions: 0o022),
            let record = try? JSONDecoder().decode(Owner.self, from: owner.data),
            record.home.hasPrefix("/"), record.pid > 1 else { return }

        let oldHome = URL(fileURLWithPath: record.home, isDirectory: true).resolvingSymlinksInPath()
        guard oldHome.path != runtime.path,
            Darwin.kill(record.pid, 0) == -1, errno == ESRCH,
            let path = String(data: marker.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            path.hasPrefix("/") else { return }
        let target = URL(fileURLWithPath: path)
        guard target.lastPathComponent == "control.sock",
            target.deletingLastPathComponent().lastPathComponent == fallbackDirectory(for: oldHome),
            isMissing(target) else { return }

        // 只处理迁移来的旧地址。已经重建的新地址仍由 Hermes 管理。
        var current = stat()
        guard lstat(pointer.path, &current) == 0,
            current.st_dev == marker.metadata.st_dev, current.st_ino == marker.metadata.st_ino else { return }
        do { try FileManager.default.removeItem(at: pointer) }
        catch CocoaError.fileNoSuchFile { }
    }

    static func fallbackDirectory(for home: URL) -> String {
        let digest = SHA256.hash(data: Data(home.resolvingSymlinksInPath().path.utf8))
        return "hermes-gw-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func isMissing(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == -1 && errno == ENOENT
    }

    private static func readMarker(_ url: URL, prohibitedPermissions: mode_t) -> (data: Data, metadata: stat)? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            (metadata.st_mode & S_IFMT) == S_IFREG,
            metadata.st_uid == getuid(),
            metadata.st_mode & prohibitedPermissions == 0,
            let data = try? handle.read(upToCount: 4097), data.count <= 4096 else { return nil }
        return (data, metadata)
    }

    private struct Owner: Decodable {
        let pid: pid_t
        let home: String

        enum CodingKeys: String, CodingKey {
            case pid
            case home = "hermes_home"
        }
    }
}
