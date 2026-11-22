import Darwin
import Foundation

public enum TurnEvent: Sendable {
    case session(String)
    case runSettings(HermesRunSettings)
    case text(String, messageID: String?)
    case image(ImagePayload)
    case tool(ToolRun)
    case permission(ToolPermission)
    case permissionExpired(String)
    case followUpReady
    case followUpStarted(UUID)
    case followUpRejected(UUID)
    case insertionAccepted(UUID, String)
    case insertionFailed(UUID, String)
    case activity(String)
    case finished(String)
    case failed(String)
}

public final class TurnControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var submitFollowUp: ((UUID, String) throws -> Void)?
    private var acceptsFollowUps = false
    private var followUp: (id: UUID, text: String, started: Bool, acknowledged: Bool)?
    private var sendInsertion: ((UUID, String) -> Void)?
    private var permissions: [UUID: (ToolPermission, (String?) throws -> Void)] = [:]

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    public func enqueueFollowUp(id: UUID, text: String) -> Bool {
        lock.withLock {
            guard !cancelled, acceptsFollowUps, permissions.isEmpty, followUp == nil,
                let submitFollowUp, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !text.hasPrefix("/") else { return false }
            do {
                try submitFollowUp(id, text)
                followUp = (id, text, false, false)
                return true
            } catch {
                return false
            }
        }
    }

    public func insert(id: UUID, text: String) -> Bool {
        lock.withLock {
            guard !cancelled, permissions.isEmpty, let sendInsertion else { return false }
            sendInsertion(id, text)
            return true
        }
    }

    fileprivate func handleInsertion(_ handler: @escaping (UUID, String) -> Void) {
        lock.withLock { sendInsertion = handler }
    }

    public func respond(to id: UUID, optionID: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, let (request, reply) = permissions[id],
            optionID == nil || request.options.contains(where: { $0.id == optionID }) else { return false }
        do {
            try reply(optionID)
            permissions[id] = nil
            return true
        } catch {
            return false
        }
    }

    fileprivate func register(_ request: ToolPermission, reply: @escaping (String?) throws -> Void) {
        lock.withLock { permissions[request.id] = (request, reply) }
    }

    fileprivate func expire(toolID: String) -> Bool {
        lock.withLock {
            guard let id = permissions.first(where: { $0.value.0.toolID == toolID })?.key else { return false }
            permissions[id] = nil
            return true
        }
    }

    fileprivate func setFollowUpSender(_ sender: ((UUID, String) throws -> Void)?) {
        lock.withLock {
            submitFollowUp = sender
            if sender == nil { acceptsFollowUps = false }
        }
    }

    fileprivate func enableFollowUps() -> Bool {
        lock.withLock {
            guard submitFollowUp != nil, !acceptsFollowUps else { return false }
            acceptsFollowUps = true
            return followUp == nil
        }
    }

    fileprivate func beginFollowUp(text: String? = nil) -> UUID? {
        lock.withLock {
            guard let pending = followUp, !pending.started, text == nil || pending.text == text else { return nil }
            acceptsFollowUps = false
            followUp = pending.acknowledged ? nil : (pending.id, pending.text, true, false)
            return pending.id
        }
    }

    fileprivate func finishFollowUpRequest(id: UUID, rejected: Bool) -> (rejected: Bool, ready: Bool)? {
        lock.withLock {
            guard let pending = followUp, pending.id == id else { return nil }
            followUp = pending.started || rejected ? nil : (pending.id, pending.text, false, true)
            return (rejected && !pending.started, acceptsFollowUps && followUp == nil)
        }
    }

    fileprivate var waitingForFollowUpStart: Bool { lock.withLock { followUp?.started == false } }
    fileprivate var waitingForFollowUpResponse: Bool { lock.withLock { followUp?.acknowledged == false } }

    fileprivate func attach(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
    }

    fileprivate func detach() {
        lock.withLock {
            process = nil
            submitFollowUp = nil
            acceptsFollowUps = false
            followUp = nil
            sendInsertion = nil
            permissions.removeAll()
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

extension HermesRuntime {
    public func warm(home: URL, conversation: Conversation?, workspace: URL? = nil, skillIDs: Set<String>? = nil,
        onSettings: (@Sendable (String, HermesRunSettings) -> Void)? = nil) {
        workers.queue.async {
            do {
                let worker = try workers.connection(runtime: self, home: home, skillIDs: skillIDs,
                    projectTools: workspace != nil)
                if let id = conversation?.sessionID {
                    let directory = try self.sessionDirectory(home: home, workspace: workspace)
                    _ = try worker.session(existing: id, workspace: directory)
                    if let settings = worker.rpc.settings[id] { onSettings?(id, settings) }
                }
                workers.keepWarm(home: home)
            } catch {
                workers.remove(home: home)
            }
        }
    }

    public func reset(home: URL) {
        workers.queue.async { workers.remove(home: home) }
    }

    public func runSettings(home: URL, sessionID: String?, workspace: URL? = nil, skillIDs: Set<String>? = nil,
        change: (field: HermesRunSettings.Field, value: String)? = nil) async throws -> HermesRunSession {
        try await withCheckedThrowingContinuation { continuation in
            workers.queue.async {
                do {
                    let directory = try sessionDirectory(home: home, workspace: workspace)
                    let worker = try workers.connection(runtime: self, home: home, skillIDs: skillIDs,
                        projectTools: workspace != nil)
                    let id = try worker.session(existing: sessionID, workspace: directory)
                    workers.keepWarm(home: home)
                    if let change { try worker.setRunSetting(change.field, value: change.value, sessionID: id) }
                    continuation.resume(returning: HermesRunSession(id: id, settings: worker.rpc.settings[id]))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func turn(
        home: URL, conversation: Conversation, text: String, images: [ImagePayload] = [],
        skill: HermesSkill? = nil, workspace: URL? = nil, skillIDs: Set<String>? = nil,
        interactive: Bool = false, control: TurnControl
    ) -> AsyncStream<TurnEvent> {
        streamTurn(home: home, conversation: conversation, text: text, images: images, skill: skill,
            workspace: workspace, skillIDs: skillIDs, draft: false, interactive: interactive, control: control)
    }

    func streamTurn(
        home: URL, conversation: Conversation, text: String, images: [ImagePayload] = [],
        skill: HermesSkill? = nil, workspace: URL? = nil, skillIDs: Set<String>? = nil,
        draft: Bool, interactive: Bool = false, control: TurnControl
    ) -> AsyncStream<TurnEvent> {
        AsyncStream { stream in
            stream.onTermination = { reason in
                if case .cancelled = reason { control.cancel() }
            }
            workers.queue.async {
                defer { stream.finish() }
                do {
                    if control.isCancelled { throw CancellationError() }
                    let result = try runTurn(home: home, conversation: conversation, text: text,
                        images: images, skill: skill, workspace: workspace, skillIDs: skillIDs,
                        draft: draft, interactive: interactive, control: control) {
                        stream.yield($0)
                    }
                    if draft || control.isCancelled { workers.remove(home: home) } else { workers.keepWarm(home: home) }
                    stream.yield(.finished(control.isCancelled ? "cancelled" : result))
                } catch {
                    if !(error is CancellationError) { workers.remove(home: home) }
                    if control.isCancelled {
                        stream.yield(.finished("cancelled"))
                    } else {
                        stream.yield(.failed(error.localizedDescription))
                    }
                }
            }
        }
    }

    private func runTurn(
        home: URL, conversation: Conversation, text: String, images: [ImagePayload],
        skill: HermesSkill?, workspace requestedWorkspace: URL?, skillIDs: Set<String>?, draft: Bool, interactive: Bool,
        control: TurnControl, receive: @escaping (TurnEvent) -> Void
    ) throws -> String {
        let workspace = try sessionDirectory(home: home, workspace: requestedWorkspace)
        let worker = try workers.connection(runtime: self, home: home, skillIDs: skillIDs, draft: draft,
            projectTools: requestedWorkspace != nil, onLaunch: { receive(.activity("正在启动 Hermes")) },
            control: control)
        try control.attach(worker.process)
        defer { control.detach() }
        let sessionID = try worker.session(existing: conversation.sessionID, workspace: workspace)
        if conversation.sessionID == nil { receive(.session(sessionID)) }
        if interactive, let settings = worker.rpc.settings[sessionID] { receive(.runSettings(settings)) }
        if interactive {
            control.handleInsertion { id, text in
                Task {
                    do {
                        try await insertIntoRunningTurn(text, sessionID: sessionID, home: home)
                        receive(.insertionAccepted(id, text))
                    } catch {
                        receive(.insertionFailed(id, error.localizedDescription))
                    }
                }
            }
        }
        var prompt: [[String: Any]] = []
        if let skill, skillIDs?.contains(skill.id) != false {
            prompt.append(["type": "text", "text": "当前任务选择了 Hermes 技能「\(skill.name)」。请在回答前调用 skill_view，使用相对路径 \(skill.id) 获取技能指令。"])
        }
        if !text.isEmpty { prompt.append(["type": "text", "text": text]) }
        if interactive, !text.hasPrefix("/") {
            prompt.append(["type": "text", "text": "回复方式：简单问题直接回答。需要多个工具步骤时，在开始和出现重要进展时，用简短正文告知用户正在做什么。完成后直接给出可用的结果，并说明实际验证情况或仍有的阻碍。"])
        }
        prompt.append(contentsOf: images.map {
            ["type": "image", "mimeType": $0.image.mimeType, "data": $0.data.base64EncodedString()]
        })
        if control.isCancelled { throw CancellationError() }
        receive(.activity("等待模型回复"))
        let response = try worker.rpc.call("session/prompt", parameters: [
            "sessionId": sessionID,
            "prompt": prompt
        ], control: interactive ? control : nil, onPermission: { receive(.permission($0)) },
            onFollowUpReady: { receive(.followUpReady) },
            onFollowUpStarted: { receive(.followUpStarted($0)) },
            onFollowUpRejected: { receive(.followUpRejected($0)) }) { update in
            let kind = update["sessionUpdate"] as? String
            if kind == "agent_message_chunk",
                let content = update["content"] as? [String: Any], let text = content["text"] as? String {
                let id = update["messageId"] as? String
                receive(.text(text, messageID: id))
            } else if kind == "agent_message_chunk", let block = update["content"] as? [String: Any],
                let image = Self.imageBlock(block) {
                receive(.image(image))
            } else if kind == "tool_call" || kind == "tool_call_update", let id = update["toolCallId"] as? String {
                let content = (update["content"] as? [[String: Any]])?.compactMap(Self.toolContent).joined(separator: "\n\n")
                let details = (content?.isEmpty == false ? content : update["rawOutput"] as? String)
                    .map { String($0.prefix(24_000)) }
                let status = update["status"] as? String ?? (kind == "tool_call" ? "in_progress" : nil)
                if let status, ["completed", "failed", "cancelled"].contains(status), control.expire(toolID: id) {
                    receive(.permissionExpired(id))
                }
                receive(.tool(ToolRun(id: id, title: update["title"] as? String, status: status,
                    details: details, kind: update["kind"] as? String)))
            } else if (kind == "config_option_update" || kind == "current_mode_update"),
                interactive, let settings = worker.rpc.settings[sessionID] {
                receive(.runSettings(settings))
            } else if kind == "agent_thought_chunk" {
                receive(.activity("正在思考"))
            }
        }
        return response["stopReason"] as? String ?? "end_turn"
    }

    private func sessionDirectory(home: URL, workspace: URL?) throws -> URL {
        let directory = workspace ?? home.appendingPathComponent("workspace", isDirectory: true)
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw StudioError.message("项目目录已移动或不可访问。")
        }
        return directory
    }

    private static func imageBlock(_ block: [String: Any]) -> ImagePayload? {
        guard block["type"] as? String == "image", let content = block["data"] as? String, content.count < 33_600_000 else { return nil }
        let encoded = content.hasPrefix("data:") ? content.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "" : content
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? ImagePayload.prepare(name: "Hermes 图片", data: data)
    }

    private static func toolContent(_ block: [String: Any]) -> String? {
        if let content = block["content"] as? [String: Any] { return content["text"] as? String }
        if block["type"] as? String == "diff", let text = block["newText"] as? String { return text }
        return block["text"] as? String
    }
}

final class ACPWorkerPool: @unchecked Sendable {
    let queue = DispatchQueue(label: "studio.hermes.acp", qos: .userInitiated)
    private var workers: [URL: ACPWorker] = [:]

    fileprivate func connection(
        runtime: HermesRuntime, home: URL, skillIDs: Set<String>?, draft: Bool = false, projectTools: Bool,
        onLaunch: () -> Void = {}, control: TurnControl? = nil
    ) throws -> ACPWorker {
        if let worker = workers[home], worker.process.isRunning, worker.skillIDs == skillIDs,
            worker.draft == draft, worker.projectTools == projectTools {
            return worker
        }
        remove(home: home)
        if workers.count >= 2, let oldest = workers.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            remove(home: oldest)
        }
        onLaunch()
        let env = try runtime.prepare(home: home, withVision: !draft, skillIDs: skillIDs, draft: draft,
            projectTools: projectTools)
        if control?.isCancelled == true { throw CancellationError() }
        let process = runtime.process(arguments: ["acp"], directory: home.appendingPathComponent("workspace"), overrides: env)
        let worker = try ACPWorker(process: process, skillIDs: skillIDs, draft: draft,
            projectTools: projectTools, control: control)
        workers[home] = worker
        return worker
    }

    fileprivate func keepWarm(home: URL) {
        guard let worker = workers[home] else { return }
        let timestamp = DispatchTime.now().uptimeNanoseconds
        worker.lastUse = timestamp
        queue.asyncAfter(deadline: .now() + 180) { [weak self] in
            guard let self, self.workers[home]?.lastUse == timestamp else { return }
            self.remove(home: home)
        }
    }

    fileprivate func remove(home: URL) { workers.removeValue(forKey: home)?.close() }

    deinit {
        for worker in workers.values { worker.close() }
    }
}

private final class ACPWorker {
    let process: Process
    let rpc: ACPConnection
    let skillIDs: Set<String>?
    let draft: Bool
    let projectTools: Bool
    var lastUse = DispatchTime.now().uptimeNanoseconds
    private var readySessions: [String: String] = [:]

    init(process: Process, skillIDs: Set<String>?, draft: Bool, projectTools: Bool, control: TurnControl?) throws {
        self.process = process
        self.skillIDs = skillIDs
        self.draft = draft
        self.projectTools = projectTools
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        rpc = ACPConnection(input: input.fileHandleForWriting, output: output.fileHandleForReading)
        do {
            try process.run()
            try control?.attach(process)
            _ = try rpc.call("initialize", parameters: [
                "protocolVersion": 1,
                "clientInfo": ["name": "hermes-studio", "version": "0.3.0"],
                "clientCapabilities": [:]
            ])
        } catch {
            close()
            control?.detach()
            throw error
        }
    }

    func session(existing: String?, workspace: URL) throws -> String {
        let path = workspace.path
        var params: [String: Any] = ["cwd": path, "mcpServers": []]
        let id: String
        let response: [String: Any]
        if let existing {
            if readySessions[existing] == path { return existing }
            params["sessionId"] = existing
            response = try rpc.call("session/load", parameters: params)
            guard !response.isEmpty else {
                throw StudioError.message("无法恢复 Hermes 对话。请新建对话后再试。")
            }
            id = existing
        } else {
            response = try rpc.call("session/new", parameters: params)
            guard let created = response["sessionId"] as? String else {
                throw StudioError.message("Hermes 没有返回会话编号。")
            }
            id = created
        }
        rpc.recordSettings(response, sessionID: id)
        readySessions[id] = path
        return id
    }

    func setRunSetting(_ field: HermesRunSettings.Field, value: String, sessionID: String) throws {
        guard let current = rpc.settings[sessionID],
            current[field]?.choices.contains(where: { $0.id == value }) == true else {
            throw StudioError.message("Hermes 未提供这个选项，请重新打开运行设置。")
        }
        if field == .model, current.modelUsesLegacyMethod {
            _ = try rpc.call("session/set_model", parameters: ["sessionId": sessionID, "modelId": value])
            rpc.settings[sessionID] = current.settingLegacyModel(value)
        } else if field == .editApproval, current.editApprovalUsesLegacyMethod {
            _ = try rpc.call("session/set_mode", parameters: ["sessionId": sessionID, "modeId": value])
            rpc.settings[sessionID] = current.settingLegacyEditApproval(value)
        } else {
            let response = try rpc.call("session/set_config_option", parameters: [
                "sessionId": sessionID, "configId": field.rawValue, "value": value
            ])
            guard let applied = HermesRunSettings(response: response, previous: rpc.settings[sessionID]),
                let selected = applied[field], field != .editApproval || selected.value == value else {
                throw StudioError.message("Hermes 没有应用所选设置。")
            }
            rpc.settings[sessionID] = applied
        }
    }

    func close() {
        if process.isRunning { process.terminate() }
        try? rpc.input.close()
        try? rpc.output.close()
    }
}

final class ACPConnection {
    let input: FileHandle
    let output: FileHandle
    var buffer = Data()
    var nextID = 0
    private let writeLock = NSLock()
    private var queueSessions: Set<String> = []
    fileprivate var settings: [String: HermesRunSettings] = [:]

    fileprivate func recordSettings(_ response: [String: Any], sessionID: String) {
        if let parsed = HermesRunSettings(response: response, previous: settings[sessionID]) {
            settings[sessionID] = parsed
        }
    }

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func call(
        _ method: String, parameters: [String: Any], timeout: DispatchTimeInterval = .seconds(30),
        control: TurnControl? = nil, onPermission: (ToolPermission) -> Void = { _ in },
        onFollowUpReady: () -> Void = {},
        onFollowUpStarted: (UUID) -> Void = { _ in },
        onFollowUpRejected: (UUID) -> Void = { _ in },
        onUpdate: ([String: Any]) -> Void = { _ in }
    ) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let deadline = method == "session/prompt" ? nil : DispatchTime.now() + timeout
        let sessionID = parameters["sessionId"] as? String
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": parameters])
        if method == "session/prompt", let control, let sessionID {
            control.setFollowUpSender { [self] id, text in
                try send(["jsonrpc": "2.0", "id": id.uuidString, "method": "session/prompt", "params": [
                    "sessionId": sessionID, "prompt": [["type": "text", "text": "/queue " + text]]
                ]])
            }
        }
        defer { control?.setFollowUpSender(nil) }
        var primaryResult: [String: Any]?
        var rejectedQueueCommand = false
        let turnUpdates: Set<String> = ["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update"]
        while true {
            let event = try read(until: deadline)
            if event["method"] as? String == "session/update",
                let params = event["params"] as? [String: Any],
                let update = params["update"] as? [String: Any] {
                let updatedSession = params["sessionId"] as? String
                let kind = update["sessionUpdate"] as? String
                if kind == "config_option_update", let updatedSession {
                    recordSettings(update, sessionID: updatedSession)
                } else if kind == "current_mode_update", let updatedSession, let mode = update["currentModeId"] as? String,
                    let current = settings[updatedSession], current.editApprovalUsesLegacyMethod {
                    settings[updatedSession] = current.settingLegacyEditApproval(mode)
                }
                if kind == "available_commands_update", let updatedSession,
                    let commands = update["availableCommands"] as? [[String: Any]] {
                    if commands.contains(where: { $0["name"] as? String == "queue" }) {
                        queueSessions.insert(updatedSession)
                    } else {
                        queueSessions.remove(updatedSession)
                    }
                }
                guard sessionID == nil || updatedSession == sessionID else { continue }
                if let control, let content = update["content"] as? [String: Any], let text = content["text"] as? String {
                    if kind == "user_message_chunk", let id = control.beginFollowUp(text: text) {
                        onFollowUpStarted(id)
                        continue
                    }
                    if kind == "agent_message_chunk", update["messageId"] == nil, control.waitingForFollowUpStart {
                        if text.hasPrefix("Queued for the next turn. ("), text.hasSuffix(" queued)") { continue }
                        if text.hasPrefix("Error executing /queue:") || text == "Usage: /queue <prompt>" {
                            rejectedQueueCommand = true
                            continue
                        }
                    }
                }
                if let kind, turnUpdates.contains(kind) {
                    // Hermes 网关以原请求结束后的下一回合更新划分边界，旧版 ACP 会先回传用户消息。
                    if primaryResult != nil, let id = control?.beginFollowUp() { onFollowUpStarted(id) }
                    onUpdate(update)
                    if let sessionID, queueSessions.contains(sessionID), control?.enableFollowUps() == true {
                        onFollowUpReady()
                    }
                } else {
                    onUpdate(update)
                }
            } else if let serverMethod = event["method"] as? String, let serverID = event["id"] {
                if serverMethod == "session/request_permission" {
                    if let control, let sessionID, let params = event["params"] as? [String: Any],
                        params["sessionId"] as? String == sessionID, let request = ToolPermission(params) {
                        if primaryResult != nil, let id = control.beginFollowUp() { onFollowUpStarted(id) }
                        control.register(request) { [self] option in
                            try sendPermissionResponse(id: serverID, option: option)
                        }
                        onPermission(request)
                    } else {
                        try sendPermissionResponse(id: serverID, option: nil)
                    }
                } else {
                    try send(["jsonrpc": "2.0", "id": serverID, "error": ["code": -32601, "message": "客户端不支持此方法"]])
                }
            } else if event["id"] as? Int == id {
                if let failure = event["error"] as? [String: Any] {
                    let details = (failure["data"] as? [String: Any])?["details"] as? String ?? ""
                    if details.contains("invalid_control_pointer") {
                        throw StudioError.message("Hermes 无法验证这个角色的本地网关地址。请从左下角重新检测本机 Hermes。")
                    }
                    let message = switch method {
                    case "initialize": "Hermes ACP 初始化失败。"
                    case "session/load": "无法恢复 Hermes 对话。请新建对话后再试。"
                    case "session/new": "Hermes 无法建立本地会话。请从左下角重新检测本机 Hermes。"
                    case "session/set_mode": "Hermes 未能切换权限模式，请在回复结束后重试。"
                    case "session/set_model", "session/set_config_option": "Hermes 未能更新运行设置，请在回复结束后重试。"
                    default: "Hermes 未能完成本次回复。请检查模型和认证配置后重试。"
                    }
                    throw StudioError.message(message)
                }
                let result = event["result"] as? [String: Any] ?? [:]
                control?.setFollowUpSender(nil)
                if control?.waitingForFollowUpResponse == true {
                    primaryResult = result
                } else {
                    return result
                }
            } else if let remoteID = (event["id"] as? String).flatMap(UUID.init(uuidString:)),
                let state = control?.finishFollowUpRequest(id: remoteID,
                    rejected: event["error"] != nil || rejectedQueueCommand) {
                rejectedQueueCommand = false
                if state.rejected { onFollowUpRejected(remoteID) }
                if let primaryResult { return primaryResult }
                if state.ready { onFollowUpReady() }
            }
        }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try writeLock.withLock { try input.write(contentsOf: data) }
    }

    private func sendPermissionResponse(id: Any, option: String?) throws {
        let outcome = option.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        try send(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
    }

    private func read(until deadline: DispatchTime?) throws -> [String: Any] {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    return message
                }
            } else {
                if let deadline {
                    let remaining = Int64(deadline.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)
                    guard remaining > 0 else { throw StudioError.message("Hermes 初始化或恢复会话超时，请重试。") }
                    var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let result = poll(&descriptor, 1, Int32((remaining + 999_999) / 1_000_000))
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw StudioError.message("Hermes 初始化或恢复会话超时，请重试。") }
                }
                let data = output.availableData
                guard !data.isEmpty else {
                    throw StudioError.message("Hermes 连接已关闭。请检查本机 Hermes 和 ACP 安装。")
                }
                buffer.append(data)
            }
        }
    }
}
