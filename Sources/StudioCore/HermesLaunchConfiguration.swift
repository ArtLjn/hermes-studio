import Foundation

extension HermesRuntime {
    /// 由已安装的 Hermes 解析默认配置与环境变量，每次准备时读取最新值。
    func launchConfiguration(credentialKeys: Set<String>) -> [String: Any]? {
        guard let keys = try? JSONEncoder().encode(credentialKeys.sorted()) else { return nil }
        let script = """
            import json, os, sys
            sys.dont_write_bytecode = True
            from hermes_cli.profiles import resolve_profile_env
            os.environ['HERMES_HOME'] = resolve_profile_env('default')
            from hermes_cli.config import load_config, get_env_value
            config = load_config()
            snapshot = {key: config.get(key) for key in ('model', 'custom_providers', 'skills', 'web', 'browser')}
            snapshot['auxiliary.vision'] = (config.get('auxiliary') or {}).get('vision')
            snapshot['security.fake_ip_ranges'] = (config.get('security') or {}).get('fake_ip_ranges')
            for key in \(String(decoding: keys, as: UTF8.self)):
                snapshot[key] = get_env_value(key)
            print('STUDIO_CONFIG ' + json.dumps(snapshot), flush=True)
            """
        // 通过启动器的模块入口使用同一套 Hermes 依赖，凭据只通过管道返回。
        let command = process(arguments: ["--run-module", "code"])
        let input = Pipe()
        let output = Pipe()
        command.standardInput = input
        command.standardOutput = output
        let statement = "exec(\(String(reflecting: script)))\n"
        try? input.fileHandleForWriting.write(contentsOf: Data(statement.utf8))
        try? input.fileHandleForWriting.close()
        guard (try? HermesProcessLifetime.shared.launch(command)) != nil else { return nil }
        let timeout = DispatchWorkItem {
            if command.isRunning { command.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(5), execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        let marker = "STUDIO_CONFIG "
        guard command.terminationStatus == 0,
            let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first(where: { $0.contains(marker) }),
            let range = line.range(of: marker),
            let snapshot = (try? JSONSerialization.jsonObject(with: Data(line[range.upperBound...].utf8))) as? [String: Any],
            snapshot["model"] != nil else { return nil }
        return snapshot
    }
}
