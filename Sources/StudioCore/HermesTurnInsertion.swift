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
        let outcome: Substring?
        do {
            outcome = try gatewayOperation(Self.insertionProgram,
                request: ["session": sessionID, "text": text], home: home)
        } catch CapturedCommandError.timedOut {
            throw StudioError.message("Hermes 插入确认超时。消息仍在输入框，请先查看当前回复是否已收到补充。")
        }
        switch outcome {
        case "accepted": return
        case "ended": throw StudioError.message("当前回合已经结束，消息仍在输入框。")
        case "rejected": throw StudioError.message("Hermes 未能把消息插入当前回合，消息仍在输入框。")
        default: throw StudioError.message("无法确认 Hermes 当前回合的插入结果，消息仍在输入框。")
        }
    }

    func setTerminalApprovalBypass(_ enabled: Bool, sessionID: String, home: URL) throws {
        let outcome = try gatewayOperation(Self.approvalProgram,
            request: ["session": sessionID, "enabled": enabled], home: home)
        guard outcome == (enabled ? "enabled" : "disabled") else {
            throw outcome == "unsupported" ? HermesTerminalApprovalError.unsupported : .unconfirmed
        }
    }

    func gatewayOperation(_ program: String, request: [String: Any], home: URL,
        timeout: TimeInterval = 12) throws -> Substring? {
        let request = try JSONSerialization.data(withJSONObject: request)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let literal = try encoder.encode(program)
        // 用 Hermes 自己的 Python 客户端认证。参数以 JSON 传入，与程序源码分开。
        let input = "exec(\(String(decoding: literal, as: UTF8.self)))\n" + String(decoding: request, as: UTF8.self) + "\n"
        var environment = ["HERMES_HOME": home.path]
        try attachInstalledDependencies(to: home, environment: &environment)
        let files = FileManager.default
        let exchange = home.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(".studio-rpc-\(UUID())", isDirectory: true)
        try files.createDirectory(at: exchange, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: exchange) }
        let inputURL = exchange.appendingPathComponent("input")
        try Data(input.utf8).write(to: inputURL)
        let standardInput = try FileHandle(forReadingFrom: inputURL)
        defer { try? standardInput.close() }
        try files.removeItem(at: inputURL)
        // 启动器的子进程可能继续持有输出描述符，等管道 EOF 会绕过超时。
        let result = try captureCommandOutput(["--run-module", "code", "-q"], timeout: timeout,
            output: exchange.appendingPathComponent("output"), overrides: environment, standardInput: standardInput)
        let marker = "HERMES_STUDIO_GATEWAY="
        return result.output.split(whereSeparator: \.isNewline)
            .compactMap { line in line.range(of: marker).map { line[$0.upperBound...] } }.last
    }

    static let gatewayProgram = """
        import asyncio, json, sys
        from pathlib import Path
        from hermes_constants import get_hermes_home
        from hermes_cli.gateway_client import connect_gateway, GatewayRPCError
        from hermes_cli.gateway_runtime import attachable, discover_gateway_endpoint

        async def execute(request, operation):
            home = Path(get_hermes_home()).resolve()
            owner = await asyncio.to_thread(discover_gateway_endpoint, home, timeout=2)
            if not attachable(owner):
                return "unavailable"
            async with connect_gateway(endpoint=owner.endpoint) as client:
                return await operation(client, request)

        def respond(operation):
            result = asyncio.run(execute(json.loads(sys.stdin.readline()), operation))
            print("HERMES_STUDIO_GATEWAY=" + result, flush=True)

        """

    private static let insertionProgram = gatewayProgram + """

        async def insert(client, request):
            session = request["session"]
            try:
                state = await client.rpc("session.resume", session_id=session, omit_messages=True, _timeout=4)
                if not state.get("running") or state.get("session_id") != session:
                    return "ended"
                # 后端校验执行代数，回合在查询后结束时会拒绝这条插入。
                reply = await client.rpc("session.redirect", session_id=session, text=request["text"],
                                         execution_generation=state["execution_generation"], _timeout=4)
                return "accepted" if reply.get("status") == "redirected" else "rejected"
            except GatewayRPCError as error:
                return "ended" if str(error) in {"not_found", "stale_generation"} else "rejected"

        respond(insert)
        """

    private static let approvalProgram = gatewayProgram + """

        async def approval(client, request):
            session = request["session"]
            expected = "1" if request["enabled"] else "0"
            try:
                state = await client.rpc("config.get", session_id=session, key="yolo", _timeout=3)
                if state.get("value") != expected:
                    state = await client.rpc("config.set", session_id=session, key="yolo",
                                             value=expected, _timeout=4)
                if state.get("scope") == "session" and state.get("value") == expected:
                    return "enabled" if request["enabled"] else "disabled"
            except GatewayRPCError as error:
                if str(error) in {"invalid_params", "unknown_method", "method_not_found"}:
                    return "unsupported"
            return "unconfirmed"

        respond(approval)
        """
}
