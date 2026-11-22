import Foundation

public struct HermesRuntime: Sendable {
    public let executable: URL
    let workers = ACPWorkerPool()
    let completionWorker = HermesCompletionWorker()

    public init(executable: URL) {
        self.executable = executable
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

    public func currentModel() throws -> String {
        let model = try config("model", raw: false)
        return (model as? [String: Any])?["default"] as? String ?? model as? String ?? ""
    }

    func prepare(home: URL, withVision: Bool, skillIDs: Set<String>?, draft: Bool,
        projectTools: Bool) throws -> [String: String] {
        try HermesGatewayRendezvous.cleanRelocatedPointer(in: home)
        let modelValue = try config("model")
        var model = modelValue as? [String: Any] ?? ["default": modelValue as? String ?? ""]
        guard let name = model["default"] as? String, !name.isEmpty else {
            throw StudioError.message("请先在 Hermes 中设置默认模型。")
        }

        let provider = (model["provider"] as? String ?? "").lowercased()
        let vision = withVision ? (try? config("auxiliary.vision")) as? [String: Any] : nil
        let visionProvider = (vision?["provider"] as? String ?? "").lowercased()
        let custom = (try? config("custom_providers")) as? [[String: Any]] ?? []
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
            if let value = (try? config(key)) as? String, !value.isEmpty {
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
        let skills = draft ? (directories: [URL](), disabled: Set<String>()) : skillConfiguration()
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
        var toolsets = draft ? [] : ["memory", "session_search"]
        if !draft, skillIDs?.isEmpty != true { toolsets.append("skills") }
        if !draft, projectTools { toolsets += ["file", "terminal"] }
        var runtimeConfig: [String: Any] = [
            "model": model,
            "custom_providers": selected.map(hideCredentials),
            "platform_toolsets": ["acp": toolsets],
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
            "curator": ["enabled": false]
        ]
        if let vision { runtimeConfig["auxiliary"] = ["vision": hideCredentials(vision)] }
        let data = try JSONSerialization.data(withJSONObject: runtimeConfig, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: home.appendingPathComponent("config.yaml"), options: .atomic)
        return env
    }

    public func terminalHome() -> URL? {
        let output = Pipe()
        let command = process(arguments: ["config", "path"])
        command.standardOutput = output
        guard (try? command.run()) != nil else { return nil }
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
        try process.run()
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
        let settings = (try? config("skills", raw: false)) as? [String: Any] ?? [:]
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
