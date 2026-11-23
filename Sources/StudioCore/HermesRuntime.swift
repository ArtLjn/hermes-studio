import Foundation

public struct HermesRuntime: Sendable {
    public let executable: URL
    let workers: ACPWorkerPool
    let acpLauncher = HermesACPLauncher()
    let completionWorker = HermesCompletionWorker()

    public init(executable: URL, idleTimeout: TimeInterval = 120, idleCapacity: Int = 2) {
        self.executable = executable
        workers = ACPWorkerPool(idleTimeout: idleTimeout, idleCapacity: idleCapacity)
    }

    public static func discover() -> Self? {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [env["HERMES_STUDIO_EXECUTABLE"], "\(home)/.local/bin/hermes", "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
            .compactMap { $0 }
            + (env["PATH"] ?? "").split(separator: ":").map { "\($0)/hermes" }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map { Self(executable: URL(fileURLWithPath: $0)) }
    }

    func process(arguments: [String], directory: URL? = nil, overrides: [String: String] = [:]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env.merge(overrides) { _, new in new }
        process.environment = env
        process.standardError = FileHandle.nullDevice
        return process
    }

    enum CapturedCommandError: Error { case failed, timedOut }

    func captureCommandOutput(_ arguments: [String], timeout: TimeInterval, output: URL,
        directory: URL? = nil, overrides: [String: String] = [:],
        standardInput: FileHandle = .nullDevice) throws -> (code: Int32, output: String) {
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CapturedCommandError.failed
        }
        let handle = try FileHandle(forUpdating: output)
        defer { try? handle.close() }

        let environment = ["GIT_TERMINAL_PROMPT": "0", "NO_COLOR": "1"].merging(overrides) { _, value in value }
        let command = process(arguments: arguments, directory: directory, overrides: environment)
        command.standardInput = standardInput
        command.standardOutput = handle
        let exited = DispatchSemaphore(value: 0)
        command.terminationHandler = { _ in exited.signal() }
        try HermesProcessLifetime.shared.launch(command)
        guard exited.wait(timeout: .now() + timeout) == .success else {
            if command.isRunning { command.terminate() }
            throw CapturedCommandError.timedOut
        }
        guard command.terminationReason == .exit else { throw CapturedCommandError.failed }

        let end = try handle.seekToEnd()
        let bytes: UInt64 = 65_536
        try handle.seek(toOffset: end - min(end, bytes))
        let data = try handle.read(upToCount: Int(bytes)) ?? Data()
        return (command.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public func currentModel() throws -> String {
        let model = try config("model", raw: false)
        return (model as? [String: Any])?["default"] as? String ?? model as? String ?? ""
    }

    func prepare(home: URL, withVision: Bool, skillIDs: Set<String>?, draft: Bool,
        mcpServers: [MCPServer.Connection] = [], proxyRange: String? = nil,
        toolsets: [String]? = nil, budget: HermesGenerationBudget? = nil) throws -> [String: String] {
        try HermesGatewayRendezvous.cleanRelocatedPointer(in: home)
        let snapshot = launchConfiguration(credentialKeys: Set(Self.providerKeys.values.flatMap { $0 }))
        let modelValue = try snapshot.map { $0["model"] ?? "" } ?? config("model")
        let setting: (String) -> Any? = { key in
            if let snapshot { return snapshot[key] }
            return try? config(key, raw: key != "skills")
        }
        var model = modelValue as? [String: Any] ?? ["default": modelValue as? String ?? ""]
        guard let name = model["default"] as? String, !name.isEmpty else {
            throw StudioError.message("请先在 Hermes 中设置默认模型。")
        }

        let provider = (model["provider"] as? String ?? "").lowercased()
        let vision = withVision ? setting("auxiliary.vision") as? [String: Any] : nil
        let visionProvider = (vision?["provider"] as? String ?? "").lowercased()
        let custom = setting("custom_providers") as? [[String: Any]] ?? []
        let names = [provider, visionProvider].map { $0.replacingOccurrences(of: "custom:", with: "", options: .anchored) }
        var selected = custom.filter {
            guard let name = ($0["name"] as? String)?.lowercased() else { return false }
            return names.contains(name)
        }
        if selected.isEmpty, let base = model["base_url"] as? String, !base.isEmpty,
            let entry = custom.first(where: { ($0["base_url"] as? String) == base }) {
            selected.append(entry)
        }
        var env = ["HERMES_HOME": home.path]
        try attachInstalledDependencies(to: home, environment: &env)
        let credentialKeys = Set((Self.providerKeys[provider] ?? []) + (Self.providerKeys[visionProvider] ?? []))
        for key in credentialKeys {
            if let value = setting(key) as? String, !value.isEmpty {
                env[key] = value
            }
        }
        var credentialIndex = 0
        func variable(_ value: String) -> String {
            credentialIndex += 1
            let key = "HERMES_STUDIO_INFERENCE_\(credentialIndex)"
            env[key] = value
            return "${\(key)}"
        }
        func hideCredentials(_ dictionary: [String: Any]) -> [String: Any] {
            dictionary.reduce(into: [:]) { result, field in
                let key = field.key.lowercased()
                if let nested = field.value as? [String: Any] {
                    if key == "headers" {
                        result[field.key] = nested.mapValues { value in
                            guard let text = value as? String, !text.isEmpty else { return value }
                            return variable(text)
                        }
                    } else {
                        result[field.key] = hideCredentials(nested)
                    }
                } else if let value = field.value as? String, !value.isEmpty,
                    key.contains("key") || key.contains("secret") || key.contains("token") {
                    result[field.key] = variable(value)
                } else {
                    result[field.key] = field.value
                }
            }
        }
        model = hideCredentials(model)
        if let budget { model["max_tokens"] = budget.outputTokens }
        let skills = draft ? (directories: [URL](), disabled: Set<String>())
            : skillConfiguration(settings: setting("skills") as? [String: Any] ?? [:])
        var disabled = skills.disabled
        var skillDirectories = skills.directories
        if let skillIDs, !skillIDs.isEmpty {
            let catalog = installedSkills(directories: skills.directories, disabled: skills.disabled)
            let enabled = catalog.filter { skillIDs.contains($0.id) }
            let enabledNames = Set(enabled.map(\.name))
            for skill in catalog where !skillIDs.contains(skill.id) {
                disabled.insert(skill.id)
                if !enabledNames.contains(skill.name) { disabled.insert(skill.name) }
            }
            skillDirectories = try exposeSelectedSkills(enabled, in: home)
        }
        var runtimeConfig: [String: Any] = [
            "model": model,
            "custom_providers": selected.map(hideCredentials),
            // 普通对话随 Hermes 的原生工具目录更新，内部草稿请求只需要生成文字。
            "platform_toolsets": ["acp": toolsets ?? (draft ? mcpServers.map(\.name) : ["all"])],
            "display": ["busy_input_mode": "queue"],
            "skills": [
                "external_dirs": skillIDs?.isEmpty == true ? [] : skillDirectories.map(\.path),
                "disabled": disabled.sorted(),
                "project_discovery": false,
                "inline_shell": false,
                "template_vars": false,
                "write_approval": true
            ],
            "memory": ["memory_enabled": !draft, "user_profile_enabled": !draft, "provider": ""],
            "curator": ["enabled": false],
            "gateway": ["unmanaged_idle_exit_seconds": 120]
        ]
        if !draft, skillIDs?.isEmpty == true { runtimeConfig["agent"] = ["disabled_toolsets": ["skills"]] }
        if let budget {
            var agent = runtimeConfig["agent"] as? [String: Any] ?? [:]
            agent["max_turns"] = budget.iterations
            runtimeConfig["agent"] = agent
        }
        if !draft {
            for section in ["web", "browser"] {
                if let settings = setting(section) as? [String: Any], !settings.isEmpty {
                    runtimeConfig[section] = hideCredentials(settings)
                }
            }
            let declared = setting("security.fake_ip_ranges")
            let ranges = (declared as? [String]) ?? (declared as? String).map { [$0] } ?? []
            let fakeIPRanges = ranges.isEmpty ? proxyRange.map { [$0] } ?? [] : ranges
            if !fakeIPRanges.isEmpty { runtimeConfig["security"] = ["fake_ip_ranges": fakeIPRanges] }
        }
        if let vision { runtimeConfig["auxiliary"] = ["vision": hideCredentials(vision)] }
        let managesMCP = !mcpServers.isEmpty || (!draft && usesStudioMCP(home: home))
        if managesMCP {
            runtimeConfig["mcp_servers"] = Dictionary(mcpServers.map { ($0.name, $0.hermesConfig) },
                uniquingKeysWith: { first, _ in first })
        }
        let data = try JSONSerialization.data(withJSONObject: runtimeConfig, options: [.prettyPrinted, .sortedKeys])
        let configURL = home.appendingPathComponent("config.yaml")
        if managesMCP {
            try MCPStore.writePrivate(data, to: configURL)
        } else {
            try data.write(to: configURL, options: .atomic)
        }
        return env
    }

    func usesStudioMCP(home: URL) -> Bool {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("config.yaml")),
            let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return config["mcp_servers"] is [String: Any]
    }

    public func terminalHome() -> URL? {
        let output = Pipe()
        let command = process(arguments: ["config", "path"])
        command.standardOutput = output
        guard (try? HermesProcessLifetime.shared.launch(command)) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.terminationStatus == 0, path.hasPrefix("/"), !path.contains(where: \.isNewline) else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    private func config(_ key: String, raw: Bool = true) throws -> Any {
        let output = Pipe()
        let process = process(arguments: ["-p", "default", "config", "get", "--json"] + (raw ? ["--raw"] : []) + [key])
        process.standardOutput = output
        try HermesProcessLifetime.shared.launch(process)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            throw StudioError.message("无法读取本机 Hermes 的模型配置。请在终端检查 Hermes 配置。")
        }
        return value
    }

    func attachInstalledDependencies(to home: URL, environment: inout [String: String]) throws {
        let files = FileManager.default
        let root = dataRoot
        let installed = root.appendingPathComponent("installs", isDirectory: true)
        guard files.fileExists(atPath: installed.path) else { return }
        let link = home.appendingPathComponent("installs", isDirectory: true)
        if !files.fileExists(atPath: link.path) {
            try files.createSymbolicLink(at: link, withDestinationURL: installed)
        }
        if let tools = ProcessInfo.processInfo.environment["HERMES_RUNTIME_DIR"], !tools.isEmpty {
            environment["HERMES_RUNTIME_DIR"] = tools
        } else {
            environment["HERMES_RUNTIME_DIR"] = root.appendingPathComponent("tools").path
        }
        environment["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
    }

    var dataRoot: URL {
        let base = ProcessInfo.processInfo.environment["HERMES_HOME"].flatMap { path in
            path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true)
        return base.deletingLastPathComponent().lastPathComponent == "profiles"
            ? base.deletingLastPathComponent().deletingLastPathComponent() : base
    }

    func skillConfiguration() -> (directories: [URL], disabled: Set<String>) {
        skillConfiguration(settings: (try? config("skills", raw: false)) as? [String: Any] ?? [:])
    }

    private func skillConfiguration(settings: [String: Any]) -> (directories: [URL], disabled: Set<String>) {
        let disabled = settings["disabled"] as? [String] ?? []
        let platform = (settings["platform_disabled"] as? [String: [String]])?["acp"] ?? []
        let external = (settings["external_dirs"] as? [String] ?? []).map { path in
            let expanded = NSString(string: path).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: dataRoot).standardizedFileURL
        }
        let paths = [dataRoot.appendingPathComponent("skills", isDirectory: true)] + external
        var seen: Set<URL> = []
        return (paths.filter { seen.insert($0).inserted }, Set(disabled + platform))
    }

    private static let providerKeys: [String: [String]] = [
        "deepseek": ["DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL"],
        "openrouter": ["OPENROUTER_API_KEY"],
        "openai": ["OPENAI_API_KEY", "OPENAI_BASE_URL"],
        "anthropic": ["ANTHROPIC_API_KEY"],
        "gemini": ["GOOGLE_API_KEY", "GEMINI_API_KEY"],
        "openai-codex": [],
        "auto": ["DEEPSEEK_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY"]
    ]
}
