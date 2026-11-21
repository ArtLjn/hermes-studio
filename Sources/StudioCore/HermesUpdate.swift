import Foundation

public struct HermesUpdateCheck: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case available(version: String?)
        case upToDate
        case noUpdate
        case managedExternally
        case failed
        case timedOut
    }

    public let installedVersion: String?
    public let status: Status
}

extension HermesRuntime {
    public func checkForUpdates() async -> HermesUpdateCheck {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: checkForUpdates(timeout: 30))
            }
        }
    }

    func checkForUpdates(timeout: TimeInterval) -> HermesUpdateCheck {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            return HermesUpdateCheck(installedVersion: nil, status: .failed)
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let version = try? updateCommand(["acp", "--version"], timeout: min(timeout, 5),
            output: directory.appendingPathComponent("version"))
        let installedVersion = version.flatMap { $0.code == 0 ? Self.version(in: $0.output) : nil }
        let status: HermesUpdateCheck.Status
        do {
            let result = try updateCommand(["update", "--check"], timeout: timeout,
                output: directory.appendingPathComponent("check"))
            status = Self.updateStatus(code: result.code, output: result.output)
        } catch UpdateCommandError.timedOut {
            status = .timedOut
        } catch {
            status = .failed
        }
        return HermesUpdateCheck(installedVersion: installedVersion, status: status)
    }

    private enum UpdateCommandError: Error {
        case failed
        case timedOut
    }

    private func updateCommand(_ arguments: [String], timeout: TimeInterval, output: URL) throws -> (code: Int32, output: String) {
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw UpdateCommandError.failed }
        let handle = try FileHandle(forUpdating: output)
        defer { try? handle.close() }

        let command = process(arguments: arguments, overrides: ["GIT_TERMINAL_PROMPT": "0", "NO_COLOR": "1"])
        command.standardInput = FileHandle.nullDevice
        command.standardOutput = handle
        let exited = DispatchSemaphore(value: 0)
        command.terminationHandler = { _ in exited.signal() }
        try command.run()
        guard exited.wait(timeout: .now() + timeout) == .success else {
            if command.isRunning { command.terminate() }
            throw UpdateCommandError.timedOut
        }
        guard command.terminationReason == .exit else { throw UpdateCommandError.failed }

        let end = try handle.seekToEnd()
        let bytes: UInt64 = 65_536
        try handle.seek(toOffset: end - min(end, bytes))
        let data = try handle.read(upToCount: Int(bytes)) ?? Data()
        return (command.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func updateStatus(code: Int32, output: String) -> HermesUpdateCheck.Status {
        if code == 2, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .managedExternally }
        guard code == 0 else { return .failed }

        for line in output.split(whereSeparator: \.isNewline) {
            let verdict = line.drop(while: { !$0.isLetter }).lowercased()
            if verdict.hasPrefix("selected release available:") || verdict.hasPrefix("update available") {
                return .available(version: version(in: line))
            }
            if verdict.hasPrefix("already up to date") || verdict.hasPrefix("up to date with the latest release") {
                return .upToDate
            }
            if verdict.hasPrefix("no newer release") || verdict.hasPrefix("holding at this build")
                || verdict.hasPrefix("this checkout is newer than the selected release") {
                return .noUpdate
            }
        }
        return .failed
    }

    private static func version(in output: some StringProtocol) -> String? {
        let pattern = #"\bv?[0-9]+(?:\.[0-9]+){2}(?:[-+][0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)*\b"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        let version = String(output[range])
        return version.hasPrefix("v") ? version : "v\(version)"
    }
}
