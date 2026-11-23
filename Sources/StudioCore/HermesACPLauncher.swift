import Foundation

final class HermesACPLauncher: @unchecked Sendable {
    private enum Command {
        case unresolved
        case native
        case compact(URL, [String])
    }

    private let lock = NSLock()
    private var command = Command.unresolved

    func configure(_ process: Process, runtime: HermesRuntime) -> Bool {
        lock.withLock {
            if case .unresolved = command { command = Self.resolve(runtime) }
            guard case let .compact(executable, arguments) = command else { return false }
            process.executableURL = executable
            process.arguments = arguments
            return true
        }
    }

    func useNative() {
        lock.withLock { command = .native }
    }

    private static func resolve(_ runtime: HermesRuntime) -> Command {
        let probe = runtime.process(arguments: ["--print-runtime-command"])
        let output = Pipe()
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = output
        guard (try? HermesProcessLifetime.shared.launch(probe)) != nil else { return .native }
        let timeout = DispatchWorkItem { if probe.isRunning { probe.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(3), execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let entry = "runpy.run_module('hermes_cli.main', run_name='__main__', alter_sys=True)"
        guard probe.terminationStatus == 0, let args = try? JSONDecoder().decode([String].self, from: data),
            args.count == 4, args[0].hasPrefix("/"), args[1] == "-I", args[2] == "-c", args[3].hasSuffix(entry),
            FileManager.default.isExecutableFile(atPath: args[0]) else { return .native }
        // 复用 Hermes 发布的运行命令，适配只作用于暖光启动的 ACP 子进程。
        let bootstrap = args[3].dropLast(entry.count) + "exec(\(String(reflecting: program))); " + entry
        return .compact(URL(fileURLWithPath: args[0]), ["-I", "-B", "-c", String(bootstrap), "acp"])
    }

    private static let program = """
        import asyncio

        def studio_install_catalog():
            try:
                from acp.schema import InitializeResponse
                from acp_adapter import gateway_session_meta as meta
                from acp_adapter.auth import detect_provider
                from acp_adapter.gateway_server import GatewayACPAgent
                from acp_adapter.model_catalog import fallback_model_state
                full_catalog = meta.model_state
                initialize = GatewayACPAgent.initialize
                extension = GatewayACPAgent.ext_method
                if 'field_meta' not in InitializeResponse.model_fields:
                    return
                if not all(callable(getattr(GatewayACPAgent, name, None)) for name in ('_client', '_held_session')):
                    return
            except (ImportError, AttributeError):
                return

            def current_model(info):
                model = str(info.get('model') or '').strip()
                provider = info.get('provider') or detect_provider() or 'openrouter'
                return fallback_model_state(model, provider)

            async def initialize_studio(self, **kwargs):
                response = await initialize(self, **kwargs)
                response.field_meta = {**(response.field_meta or {}), 'studioModelCatalog': 1}
                return response

            async def studio_extension(self, method, params):
                if method != 'studio/model_catalog':
                    return await extension(self, method, params)
                session_id = self._held_session(params.get('sessionId'))
                info = await (await self._client()).rpc('session.info', session_id=session_id)
                catalog = await asyncio.to_thread(full_catalog, info)
                return {'models': catalog.model_dump(by_alias=True)} if catalog is not None else {}

            meta.model_state = current_model
            GatewayACPAgent.initialize = initialize_studio
            GatewayACPAgent.ext_method = studio_extension

        studio_install_catalog()
        """
}
