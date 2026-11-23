import Darwin
import Foundation
import XCTest
@testable import StudioCore

final class RuntimeLifecycleTests: XCTestCase {
    func testTemporaryTaskWaitsForLateGatewayAndRetiresItBeforeRemovingDirectory() throws {
        let lifetime = HermesProcessLifetime()
        let (home, process) = try gateway(busy: true, startupDelay: 0.4)
        defer {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: home)
        }
        XCTAssertNil(HermesGatewayControl.identify(home: home))
        lifetime.willConnect(home: home, previous: nil)
        lifetime.finishTemporary(home: home, root: home)
        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testIdleGatewayRetiresButBusyGatewayAndWrongHomeArePreserved() throws {
        for busy in [false, true] {
            let (home, process) = try gateway(busy: busy)
            defer { if process.isRunning { process.terminate() }; try? FileManager.default.removeItem(at: home) }
            let identity = try XCTUnwrap(HermesGatewayControl.identify(home: home))
            let other = home.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try MCPStore.writePrivate(Data(home.appendingPathComponent("gateway.sock").path.utf8),
                to: other.appendingPathComponent("gateway.sock.path"))
            XCTAssertNil(HermesGatewayControl.identify(home: other))
            HermesGatewayControl.retire(identity)
            if busy {
                XCTAssertTrue(process.isRunning)
                XCTAssertFalse(try String(contentsOf: home.appendingPathComponent("calls")).contains("pause-for-update"))
            } else {
                process.waitUntilExit()
                XCTAssertTrue(try String(contentsOf: home.appendingPathComponent("calls")).contains("pause-for-update"))
            }
        }
    }

    func testQuitStopsOwnedGatewayButLeavesBorrowedBusyGateway() throws {
        for owned in [false, true] {
            let (home, process) = try gateway(busy: true)
            defer { if process.isRunning { process.terminate() }; try? FileManager.default.removeItem(at: home) }
            let lifetime = HermesProcessLifetime()
            let identity = try XCTUnwrap(HermesGatewayControl.identify(home: home))
            lifetime.observe(home: home, previous: owned ? nil : identity)
            lifetime.shutdown()
            XCTAssertEqual(process.isRunning, !owned)
            if owned {
                XCTAssertTrue(try String(contentsOf: home.appendingPathComponent("calls")).contains("force"))
            }
        }
    }

    func testQuitFindsAnOwnedGatewayStillStarting() throws {
        let lifetime = HermesProcessLifetime()
        let (home, process) = try gateway(busy: true, startupDelay: 0.6)
        defer { if process.isRunning { process.terminate() }; try? FileManager.default.removeItem(at: home) }
        lifetime.willConnect(home: home, previous: nil)
        lifetime.shutdown()
        XCTAssertFalse(process.isRunning)
    }

    func testRuntimeReadsOneConfigurationSnapshotAndDoesNotPersistCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("hermes-fixture")
        let script = #"""
            #!/bin/sh
            [ "$1 $2" = '--run-module code' ] || exit 1
            cd -- "$(dirname -- "$0")" || exit 1
            printf 'batch\n' >> calls
            printf '>>> STUDIO_CONFIG '
            /bin/cat snapshot.json
            """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let secret = "configuration-test-credential"
        for name in ["first-model", "second-model"] {
            let snapshot: [String: Any] = ["model": ["provider": "openai", "default": name, "api_key": secret],
                "OPENAI_API_KEY": secret, "web": ["enabled": true], "security.fake_ip_ranges": ["198.18.0.0/15"]]
            try JSONSerialization.data(withJSONObject: snapshot).write(to: root.appendingPathComponent("snapshot.json"))
            let environment = try runtime.prepare(home: root, withVision: false, skillIDs: nil, draft: false)
            let configText = try String(contentsOf: root.appendingPathComponent("config.yaml"), encoding: .utf8)
            XCTAssertTrue(configText.contains(name))
            XCTAssertTrue(configText.contains("198.18.0.0"))
            XCTAssertTrue(configText.contains("${HERMES_STUDIO_INFERENCE_1}"))
            XCTAssertFalse(configText.contains(secret))
            XCTAssertEqual(environment["OPENAI_API_KEY"], secret)
            XCTAssertEqual(environment["HERMES_STUDIO_INFERENCE_1"], secret)
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8), "batch\nbatch\n")
    }

    func testSessionMCPUsesACPTransportAndGroupGenerationHasBoundedBudget() throws {
        var connection = MCPServer.Connection()
        connection.name = "group_tools"
        connection.endpoint = "/test/mcp"
        connection.arguments = ["thread-a", "turn-b"]
        connection.variables = ["SCOPE": "a"]
        let payload = connection.acpSpecification
        XCTAssertEqual(payload["command"] as? String, "/test/mcp")
        XCTAssertEqual(payload["env"] as? [[String: String]], [["name": "SCOPE", "value": "a"]])
        XCTAssertEqual(HermesGenerationBudget.chat.outputTokens, 512)
        XCTAssertEqual(HermesGenerationBudget.idle.iterations, 1)
        XCTAssertLessThan(HermesGenerationBudget.chat.iterations, HermesGenerationBudget.tools.iterations)
    }

    private func gateway(busy: Bool, startupDelay: Double = 0) throws -> (URL, Process) {
        let home = URL(fileURLWithPath: "/tmp/hs-gw-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let script = home.appendingPathComponent("fixture.py")
        try Data(Self.gatewayFixture.utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", script.path, home.path, busy ? "1" : "0", String(startupDelay)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if startupDelay > 0 { return (home, process) }
        let deadline = Date().addingTimeInterval(3)
        while HermesGatewayControl.identify(home: home) == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard HermesGatewayControl.identify(home: home) != nil else {
            process.terminate()
            throw StudioError.message("模拟网关没有就绪。")
        }
        return (home, process)
    }

    private static let gatewayFixture = #"""
    import json, os, socket, sys, time
    from pathlib import Path
    home = Path(sys.argv[1])
    busy = sys.argv[2] == "1"
    time.sleep(float(sys.argv[3]))
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(home / "gateway.sock"))
    server.listen(8)
    while True:
        connection, _ = server.accept()
        with connection:
            request = json.loads(connection.makefile("r").readline())
            verb = request["verb"]
            with (home / "calls").open("a") as log:
                log.write(json.dumps(request) + "\n")
            if verb == "identify":
                result = {"pid": os.getpid(), "hermes_home": str(home)}
            elif verb == "active-work":
                result = {"active_agents": int(busy), "active_work": [{}] if busy else []}
            else:
                result = {"pid": os.getpid(), "pausing": True}
            connection.sendall((json.dumps({"ok": True, "result": result}) + "\n").encode())
        if verb == "pause-for-update":
            break
    """#
}
