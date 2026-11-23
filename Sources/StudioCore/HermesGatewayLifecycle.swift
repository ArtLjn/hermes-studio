import Darwin
import Foundation

enum HermesGatewayControl {
    struct Identity: Equatable, Sendable {
        let pid: pid_t
        let home: URL
        let started: UInt64?
    }

    static func identify(home: URL) -> Identity? {
        guard let reply = query(home: home, verb: "identify"),
            let pid = reply["pid"] as? Int, pid > 1,
            let path = reply["hermes_home"] as? String,
            URL(fileURLWithPath: path).resolvingSymlinksInPath() == home.resolvingSymlinksInPath() else { return nil }
        return Identity(pid: pid_t(pid), home: home, started: startStamp(pid_t(pid)))
    }

    static func retire(_ identity: Identity, force: Bool = false) {
        guard identify(home: identity.home) == identity else { return }
        if !force {
            guard let work = query(home: identity.home, verb: "active-work"),
                work["active_agents"] as? Int == 0,
                let items = work["active_work"] as? [Any], items.isEmpty else { return }
        }
        let reply = query(home: identity.home, verb: "pause-for-update", parameters: force ? ["force": true] : [:])
        if reply?["pid"] as? Int == Int(identity.pid) {
            let deadline = ContinuousClock.now + .seconds(force ? 3 : 2)
            while isSameProcess(identity), ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.05) }
        }
        // 应用退出或独占临时任务完成时，按启动身份核对后兜底结束进程。
        if force, isSameProcess(identity) {
            Darwin.kill(identity.pid, SIGTERM)
            let deadline = ContinuousClock.now + .seconds(1)
            while isSameProcess(identity), ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if isSameProcess(identity) { Darwin.kill(identity.pid, SIGKILL) }
        }
    }

    private static func isSameProcess(_ identity: Identity) -> Bool {
        guard let started = identity.started else { return false }
        return startStamp(identity.pid) == started
    }

    private static func startStamp(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v2()
        let code = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return code == 0 ? usage.ri_proc_start_abstime : nil
    }

    static func query(home: URL, verb: String, parameters: [String: Any] = [:]) -> [String: Any]? {
        let direct = home.appendingPathComponent("gateway.sock")
        let pointer = home.appendingPathComponent("gateway.sock.path")
        let path: String
        var metadata = stat()
        if lstat(direct.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK {
            path = direct.path
        } else {
            let fd = open(pointer.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(),
                    metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o077 == 0,
                    let data = try? handle.read(upToCount: 1024),
                    let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    value.hasPrefix("/") else { return nil }
                path = value
            } else {
                guard errno == ENOENT else { return nil }
                // 一次性草稿目录可能已删除；仍按 Hermes 的确定性地址核对网关身份。
                let name = HermesGatewayRendezvous.fallbackDirectory(for: home) + "/control.sock"
                let candidates = [FileManager.default.temporaryDirectory.appendingPathComponent(name).path, "/tmp/" + name]
                guard let candidate = candidates.first(where: { lstat($0, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFSOCK }) else { return nil }
                path = candidate
            }
        }
        guard lstat(path, &metadata) == 0, metadata.st_uid == getuid(),
            metadata.st_mode & S_IFMT == S_IFSOCK else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard connected == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
            var request = try? JSONSerialization.data(withJSONObject: ["verb": verb, "id": 1, "protocol": 1, "params": parameters])
        else { return nil }
        request.append(0x0A)
        let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { return nil }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 64 * 1024 {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            response.append(contentsOf: buffer.prefix(count))
            if response.contains(0x0A) { break }
        }
        guard let result = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
            result["ok"] as? Bool == true else { return nil }
        return result["result"] as? [String: Any]
    }
}

final class HermesProcessLifetime: @unchecked Sendable {
    static let shared = HermesProcessLifetime()
    private let lock = NSLock()
    private var closing = false
    private var connections: [ObjectIdentifier: Process] = [:]
    private var gateways: [URL: (identity: HermesGatewayControl.Identity, owned: Bool)] = [:]
    private struct LaunchAttempt { let previous: HermesGatewayControl.Identity? }
    private var attempts: [URL: LaunchAttempt] = [:]

    var isClosing: Bool { lock.withLock { closing } }

    func willConnect(home: URL, previous: HermesGatewayControl.Identity?) {
        lock.withLock { if attempts[home] == nil { attempts[home] = LaunchAttempt(previous: previous) } }
    }

    func launch(_ process: Process) throws {
        try lock.withLock {
            guard !closing else { throw CancellationError() }
            connections[ObjectIdentifier(process)] = process
            let previousHandler = process.terminationHandler
            process.terminationHandler = { [weak self] process in
                previousHandler?(process)
                _ = self?.lock.withLock { self?.connections.removeValue(forKey: ObjectIdentifier(process)) }
            }
            do { try process.run() }
            catch { connections[ObjectIdentifier(process)] = nil; throw error }
        }
    }

    func observe(home: URL, previous: HermesGatewayControl.Identity?) {
        guard let current = HermesGatewayControl.identify(home: home) else { return }
        lock.withLock {
            let owned = current != previous || (gateways[home]?.identity == current && gateways[home]?.owned == true)
            gateways[home] = (current, owned)
        }
    }

    func retireIdle(home: URL) {
        guard !isClosing else { return }
        if let identity = HermesGatewayControl.identify(home: home) { HermesGatewayControl.retire(identity) }
    }

    func finishTemporary(home: URL, root: URL) {
        defer { try? FileManager.default.removeItem(at: root) }
        if let attempt = lock.withLock({ attempts[home] }) {
            retireAfterStartup(home: home, attempt: attempt)
        }
        lock.withLock {
            attempts[home] = nil
            gateways[home] = nil
        }
    }

    private func retireAfterStartup(home: URL, attempt: LaunchAttempt) {
        // ACP 退出时，已派生的网关可能还在初始化控制套接字。
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            observe(home: home, previous: attempt.previous)
            if let gateway = lock.withLock({ gateways[home] }) {
                HermesGatewayControl.retire(gateway.identity, force: gateway.owned)
                return
            }
            if ContinuousClock.now >= deadline { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while true
    }

    func shutdown() {
        let processes = lock.withLock { () -> [Process] in closing = true; return Array(connections.values) }
        for process in processes where process.isRunning { process.terminate() }
        Thread.sleep(forTimeInterval: 0.25)
        let (homes, pending) = lock.withLock { (Array(gateways.values), attempts.filter { gateways[$0.key] == nil }) }
        let group = DispatchGroup()
        for gateway in homes {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                HermesGatewayControl.retire(gateway.identity, force: gateway.owned)
                group.leave()
            }
        }
        for (home, attempt) in pending {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                self.retireAfterStartup(home: home, attempt: attempt)
                group.leave()
            }
        }
        group.wait()
        for process in processes where process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}

extension HermesRuntime {
    public static func shutdownApplicationProcesses() async {
        await Task.detached { HermesProcessLifetime.shared.shutdown() }.value
    }
}
