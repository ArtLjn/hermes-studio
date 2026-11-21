import Darwin
import Foundation

extension HermesRuntime {
    public func insertIntoRunningTurn(_ text: String, sessionID: String, home: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try performInsertion(text, sessionID: sessionID, home: home)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performInsertion(_ text: String, sessionID: String, home: URL) throws {
        let request = try JSONSerialization.data(withJSONObject: ["session": sessionID, "text": text])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let literal = try encoder.encode(Self.insertionProgram)
        // Hermes 的启动器加载其自身的 Python 环境。消息作为 JSON 读入，与程序源码分开。
        let input = "exec(\(String(decoding: literal, as: UTF8.self)))\n" + String(decoding: request, as: UTF8.self) + "\n"
        var environment = ["HERMES_HOME": home.path]
        try attachInstalledDependencies(to: home, environment: &environment)
        let process = process(arguments: ["--run-module", "code", "-q"], overrides: environment)
        let source = Pipe()
        let output = Pipe()
        process.standardInput = source
        process.standardOutput = output
        _ = fcntl(source.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: deadline)
        defer {
            deadline.cancel()
            if process.isRunning { process.terminate() }
        }
        try source.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try source.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let marker = "HERMES_STUDIO_INSERT="
        let outcome = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .compactMap { line in line.range(of: marker).map { line[$0.upperBound...] } }.last
        switch outcome {
        case "accepted": return
        case "ended": throw StudioError.message("当前回合已经结束，消息仍在输入框。")
        case "rejected": throw StudioError.message("Hermes 未能把消息插入当前回合，消息仍在输入框。")
        default: throw StudioError.message("无法确认 Hermes 当前回合的插入结果，消息仍在输入框。")
        }
    }

    private static let insertionProgram = """
        import asyncio, json, sys
        from pathlib import Path
        from hermes_constants import get_hermes_home
        from hermes_cli.gateway_client import connect_gateway, GatewayRPCError
        from hermes_cli.gateway_runtime import attachable, discover_gateway_endpoint

        async def insert(request):
            home = Path(get_hermes_home()).resolve()
            owner = await asyncio.to_thread(discover_gateway_endpoint, home, timeout=2)
            if not attachable(owner):
                return "unavailable"
            session = request["session"]
            try:
                async with connect_gateway(endpoint=owner.endpoint) as client:
                    state = await client.rpc("session.resume", session_id=session, omit_messages=True, _timeout=4)
                    if not state.get("running") or state.get("session_id") != session:
                        return "ended"
                    # 后端校验执行代数，回合在查询后结束时会拒绝这条插入。
                    reply = await client.rpc("session.redirect", session_id=session, text=request["text"],
                                             execution_generation=state["execution_generation"], _timeout=4)
                    return "accepted" if reply.get("status") == "redirected" else "rejected"
            except GatewayRPCError as error:
                return "ended" if str(error) in {"not_found", "stale_generation"} else "rejected"

        result = asyncio.run(insert(json.loads(sys.stdin.readline())))
        print("HERMES_STUDIO_INSERT=" + result, flush=True)
        """
}
