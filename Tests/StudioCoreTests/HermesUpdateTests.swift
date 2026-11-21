import Foundation
import XCTest
@testable import StudioCore

final class HermesUpdateTests: XCTestCase {
    func testReadsInstalledAndAvailableVersionsWithoutInstalling() throws {
        let result = try check(output: "→ Update channel: stable\n→ Selected release available: stable v0.23.3 (caafe5389ae5)")
        XCTAssertEqual(result.installedVersion, "v0.22.5+2295.gaad60e1")
        XCTAssertEqual(result.status, .available(version: "v0.23.3"))
        XCTAssertEqual(try check(output: "⚕ Update available: 5 commits behind origin/main.").status,
            .available(version: nil))
    }

    func testDistinguishesCurrentVersionFromFailedAndUnavailableChecks() throws {
        XCTAssertEqual(try check(output: "✓ Up to date with the latest release (stable v0.22.5).").status, .upToDate)
        XCTAssertEqual(try check(output: "✓ Already up to date.").status, .upToDate)
        XCTAssertEqual(try check(output: "→ Holding at this build: stable v0.22.4 predates the gateway runtime.").status,
            .noUpdate)
        XCTAssertEqual(try check(output: "Manage updates from within the desktop app", exitCode: 2).status,
            .managedExternally)
        XCTAssertEqual(try check(output: "", exitCode: 2).status, .failed)
        XCTAssertEqual(try check(output: "✗ Could not resolve the stable source channel", exitCode: 1).status, .failed)
        XCTAssertEqual(try check(output: "→ Update channel: stable").status, .failed)
    }

    func testTimeoutReturnsInstalledVersion() throws {
        let result = try withRuntime(updateBody: "exec /bin/sleep 10") { runtime in
            runtime.checkForUpdates(timeout: 0.5)
        }
        XCTAssertEqual(result.installedVersion, "v0.22.5+2295.gaad60e1")
        XCTAssertEqual(result.status, .timedOut)
    }

    private func check(output: String, exitCode: Int = 0) throws -> HermesUpdateCheck {
        try withRuntime(updateBody: "printf '%s\\n' '\(output)'; exit \(exitCode)") { runtime in
            runtime.checkForUpdates(timeout: 5)
        }
    }

    private func withRuntime(updateBody: String, run: (HermesRuntime) -> HermesUpdateCheck) throws -> HermesUpdateCheck {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("hermes")
        let script = """
            #!/bin/sh
            case "$#:$1:$2" in
              '2:acp:--version') printf '%s\\n' '0.22.5+2295.gaad60e1' ;;
              '2:update:--check') \(updateBody) ;;
              *) exit 99 ;;
            esac
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return run(HermesRuntime(executable: executable))
    }
}
