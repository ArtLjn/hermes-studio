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
    private var cancelPrompt: (() throws -> Void)?
    private var promptStarted = false
    private var cancelledBeforePrompt: (() -> Void)?
    private var cancellationDeadline: DispatchTime?
    private var submitFollowUp: ((UUID, String) throws -> Void)?
    private var acceptsFollowUps = false
    private var followUp: (id: UUID, text: String, started: Bool, acknowledged: Bool)?
    private var sendInsertion: ((UUID, String) -> Void)?
    private var permissions: [UUID: (ToolPermission, (String?) throws -> Void)] = [:]

    public init() {}

    public func cancel() {
        let action = lock.withLock { () -> (Process?, (() throws -> Void)?, (() -> Void)?)? in
            guard !cancelled else { return nil }
            cancelled = true
            cancellationDeadline = .now() + .seconds(5)
            let action = (process, cancelPrompt, cancelledBeforePrompt)
            cancelledBeforePrompt = nil
            return action
        }
        guard let (process, notifyHermes, beforePrompt) = action else { return }
        beforePrompt?()
        guard let process else { return }
        let queue = DispatchQueue.global(qos: .userInitiated)
        if let notifyHermes {
            // Hermes 在登记会话请求前可能忽略第一次通知。只对当前连接重试。
            for delay in [0, 250, 1_000, 2_500] {
                queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                    guard self?.isAttached(to: process) == true else { return }
                    try? notifyHermes()
                }
            }
        }
        queue.asyncAfter(deadline: .now() + (notifyHermes == nil ? .milliseconds(0) : .seconds(5))) { [weak self] in
            if self?.isAttached(to: process) == true, process.isRunning {
                process.terminate()
            }
        }
    }

    private func isAttached(to process: Process) -> Bool { lock.withLock { self.process === process } }

    fileprivate func onCancellationBeforePrompt(_ handler: @escaping () -> Void) {
        let shouldNotify = lock.withLock {
            if cancelled { return !promptStarted }
            cancelledBeforePrompt = handler
            return false
        }
        if shouldNotify { handler() }
    }

    fileprivate func startPrompt(cancel: @escaping () throws -> Void) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            promptStarted = true
            cancelledBeforePrompt = nil
            cancelPrompt = cancel
        }
    }

    fileprivate var awaitingStopConfirmation: Bool { lock.withLock { cancelled && promptStarted } }
    fileprivate var stopDeadline: DispatchTime? { lock.withLock { cancellationDeadline } }

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
            cancelPrompt = nil
            cancelledBeforePrompt = nil
            submitFollowUp = nil
            acceptsFollowUps = false
            followUp = nil
            sendInsertion = nil
            permissions.removeAll()
        }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

extension HermesRuntime {
    public func warm(home: URL, conversation: Conversation?, workspace: URL? = nil, skillIDs: Set<String>? = nil,
        mcpServers: [MCPServer.Connection] = [],
        onSettings: (@Sendable (String, HermesRunSettings) -> Void)? = nil) {
        let id = conversation?.sessionID
        workers.perform(runtime: self, home: home, sessionID: id, skillIDs: skillIDs,
            workspace: workspace, mcpServers: mcpServers, prewarmOnly: id == nil) { worker, _ in
            if let id {
                if let settings = worker.rpc.settings[id] { onSettings?(id, settings) }
            }
        } completion: { _ in }
    }

    public func reset(home: URL) {
        workers.reset(home: home)
    }

    public func releaseIdleWorkers() async {
        await withCheckedContinuation { continuation in
            workers.releaseIdle { continuation.resume() }
        }
    }

    public func keepGroupWarm(homes: Set<URL>, idleLimit: Int = 6) {
        workers.keepWarm(homes: homes, idleLimit: idleLimit)
    }

    public func warmGroupSpeaker(home: URL) {
        workers.perform(runtime: self, home: home, sessionID: nil, skillIDs: [], draft: true,
            reuseDraftWorker: true, workspace: nil, mcpServers: [], prewarmOnly: true, withVision: true,
            sessionMCPServers: [], budget: .chat, speculativeGroupWarm: true) { _, _ in
        } completion: { _ in }
    }

    private func applyRunPreferences(_ preferences: HermesRunPreferences, useModelDefaults: Bool,
        worker: ACPWorker, sessionID: String, home: URL) throws {
        if useModelDefaults {
            if let value = preferences.modelID, let model = worker.rpc.settings[sessionID]?.model, model.value != value {
                if model.choices.contains(where: { $0.id == value }) {
                    try worker.setRunSetting(.model, value: value, sessionID: sessionID)
                } else if worker.hasDeferredModelCatalog {
                    // 已保存的选项由 Hermes 单独验证，失效的默认值沿用会话当前模型。
                    try? worker.setRunSetting(.model, value: value, sessionID: sessionID, applyingSavedModel: true)
                }
            }
            if let value = preferences.effort, let effort = worker.rpc.settings[sessionID]?.effort,
                effort.value != value, effort.choices.contains(where: { $0.id == value }) {
                try worker.setRunSetting(.effort, value: value, sessionID: sessionID)
            }
        }
        let enableYOLO = preferences.approval == .fullAccess
        if preferences.managesTerminalApproval && !enableYOLO {
            try setTerminalApprovalBypass(false, sessionID: sessionID, home: home)
        }
        guard let mode = preferences.approval else { return }
        let editApproval = worker.rpc.settings[sessionID]?.editApproval
        guard let choice = mode.nativeChoice(in: editApproval) else {
            throw StudioError.message("当前 Hermes 不支持所选文件权限，请重新选择运行权限。")
        }
        if choice.id != editApproval?.value {
            try worker.setRunSetting(.editApproval, value: choice.id, sessionID: sessionID)
        }
        if enableYOLO {
            do {
                try setTerminalApprovalBypass(true, sessionID: sessionID, home: home)
            } catch {
                if let previous = editApproval?.value, previous != choice.id {
                    try? worker.setRunSetting(.editApproval, value: previous, sessionID: sessionID)
                }
                throw error
            }
        }
    }

    public func runSettings(home: URL, sessionID: String?, workspace: URL? = nil, skillIDs: Set<String>? = nil,
        mcpServers: [MCPServer.Connection] = [],
        preferences: HermesRunPreferences = .init(), useModelDefaults: Bool = false,
        change: (field: HermesRunSettings.Field, value: String)? = nil,
        includeModelChoices: Bool = true) async throws -> HermesRunSession {
        try await withCheckedThrowingContinuation { continuation in
            workers.perform(runtime: self, home: home, sessionID: sessionID, skillIDs: skillIDs,
                workspace: workspace, mcpServers: mcpServers) { worker, id in
                try applyRunPreferences(preferences, useModelDefaults: useModelDefaults, worker: worker,
                    sessionID: id, home: home)
                if includeModelChoices || change.map({ $0.field == .model }) == true {
                    try worker.loadModelChoices(sessionID: id)
                }
                if let change { try worker.setRunSetting(change.field, value: change.value, sessionID: id) }
                return HermesRunSession(id: id, settings: worker.rpc.settings[id])
            } completion: { result in
                continuation.resume(with: result)
            }
        }
    }

    public func turn(
        home: URL, conversation: Conversation, text: String, images: [ImagePayload] = [],
        skill: HermesSkill? = nil, workspace: URL? = nil, skillIDs: Set<String>? = nil,
        mcpServers: [MCPServer.Connection] = [], preferences: HermesRunPreferences = .init(),
        useModelDefaults: Bool = false, interactive: Bool = false, control: TurnControl
    ) -> AsyncStream<TurnEvent> {
        streamTurn(home: home, conversation: conversation, text: text, images: images, skill: skill,
            workspace: workspace, skillIDs: skillIDs, mcpServers: mcpServers, draft: false,
            preferences: preferences, useModelDefaults: useModelDefaults, interactive: interactive, control: control)
    }

    public func groupRecall(home: URL, roleID: UUID, prompt: String, model: String?, effort: String?,
        control: TurnControl) -> AsyncStream<TurnEvent> {
        var preferences = HermesRunPreferences()
        preferences.modelID = model
        preferences.effort = effort
        return streamTurn(home: home, conversation: Conversation(roleID: roleID), text: prompt,
            skillIDs: [], draft: true, reuseDraftWorker: true, preferences: preferences, useModelDefaults: true, control: control)
    }

    func streamTurn(
        home: URL, conversation: Conversation, text: String, images: [ImagePayload] = [],
        skill: HermesSkill? = nil, workspace: URL? = nil, skillIDs: Set<String>? = nil,
        mcpServers: [MCPServer.Connection] = [], draft: Bool, reuseDraftWorker: Bool = false, preferences: HermesRunPreferences = .init(),
        useModelDefaults: Bool = false, interactive: Bool = false, groupStart: GroupReplyStart? = nil,
        toolsets: [String]? = nil, prepareVision: Bool = false,
        sessionMCPServers: [MCPServer.Connection]? = nil, budget: HermesGenerationBudget? = nil,
        temporaryRoot: URL? = nil, control: TurnControl
    ) -> AsyncStream<TurnEvent> {
        AsyncStream { stream in
            stream.onTermination = { reason in
                if case .cancelled = reason { control.cancel() }
            }
            control.onCancellationBeforePrompt {
                groupStart?.release()
                stream.yield(.finished("cancelled"))
                stream.finish()
            }
            workers.perform(runtime: self, home: home, sessionID: conversation.sessionID, skillIDs: skillIDs,
                draft: draft, reuseDraftWorker: reuseDraftWorker, workspace: workspace, mcpServers: mcpServers,
                withVision: draft && (!images.isEmpty || prepareVision), toolsets: toolsets,
                sessionMCPServers: sessionMCPServers, budget: budget, temporaryRoot: temporaryRoot, control: control,
                onActivity: { stream.yield(.activity($0)) }) { worker, sessionID in
                if conversation.sessionID == nil { stream.yield(.session(sessionID)) }
                return try runTurn(worker: worker, home: home, sessionID: sessionID, text: text,
                    images: images, skill: skill, skillIDs: skillIDs,
                    preferences: preferences, useModelDefaults: useModelDefaults, interactive: interactive,
                    groupStart: groupStart, control: control) {
                    stream.yield($0)
                }
            } completion: { result in
                groupStart?.release()
                defer { stream.finish() }
                switch result {
                case .success(let reason): stream.yield(.finished(reason))
                case .failure where control.awaitingStopConfirmation:
                    stream.yield(.failed("Hermes 尚未确认本次任务停止，已关闭本地回复连接。"))
                case .failure where control.isCancelled:
                    stream.yield(.finished("cancelled"))
                case .failure(let error): stream.yield(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func runTurn(
        worker: ACPWorker, home: URL, sessionID: String, text: String, images: [ImagePayload],
        skill: HermesSkill?, skillIDs: Set<String>?,
        preferences: HermesRunPreferences,
        useModelDefaults: Bool, interactive: Bool, groupStart: GroupReplyStart?, control: TurnControl,
        receive: @escaping (TurnEvent) -> Void
    ) throws -> String {
        try applyRunPreferences(preferences, useModelDefaults: useModelDefaults, worker: worker,
            sessionID: sessionID, home: home)
        if control.isCancelled { throw CancellationError() }
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
        if let groupStart {
            receive(.activity("等待同伴就绪"))
            groupStart.arrive()
            if control.isCancelled { throw CancellationError() }
        }
        receive(.activity("等待模型回复"))
        let response = try worker.rpc.call("session/prompt", parameters: [
            "sessionId": sessionID,
            "prompt": prompt
        ], control: interactive ? control : nil, cancellation: control, onPermission: { receive(.permission($0)) },
            onFollowUpReady: { receive(.followUpReady) },
            onFollowUpStarted: { receive(.followUpStarted($0)) },
            onFollowUpRejected: { receive(.followUpRejected($0)) }) { update in
            guard !control.isCancelled else { return }
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

    fileprivate func sessionDirectory(home: URL, workspace: URL?) throws -> URL {
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
    private struct SessionKey: Hashable {
        let home: URL
        let id: String
    }

    fileprivate struct Options: Equatable {
        let skillIDs: Set<String>?
        let draft: Bool
        let reuseDraftWorker: Bool
        let mcpServers: [MCPServer.Connection]
        let proxyRange: String?
        let withVision: Bool
        let toolsets: [String]?
        let sessionScopedMCP: Bool
        let budget: HermesGenerationBudget?
    }

    private struct SetupLane {
        let queue = DispatchQueue(label: "studio.hermes.acp.profile", qos: .userInitiated)
        var pending = 0
    }

    private let queue = DispatchQueue(label: "studio.hermes.acp.pool", qos: .userInitiated)
    private struct IdleEntry {
        let home: URL
        let worker: ACPWorker
        let since: ContinuousClock.Instant
        let speculative: Bool
    }
    private var idle: [IdleEntry] = []
    private var expiry: Task<Void, Never>?
    private var generations: [URL: UUID] = [:]
    private var profileOptions: [URL: Options] = [:]
    private var waiting: [SessionKey: [() -> Void]] = [:]
    private var setupLanes: [URL: SetupLane] = [:]
    private var inUse: [URL: Int] = [:]
    private let idleTimeout: TimeInterval
    private let idleCapacity: Int
    private var preferredHomes: Set<URL> = []
    private var preferredIdleLimit = 6
    private var prewarming = false
    private var prewarmEpoch = UUID()
    private var effectiveIdleCapacity: Int { max(idleCapacity, min(6, preferredIdleLimit, preferredHomes.count)) }

    init(idleTimeout: TimeInterval = 120, idleCapacity: Int = 2) {
        self.idleTimeout = idleTimeout
        self.idleCapacity = max(0, idleCapacity)
    }

    fileprivate func perform<Value>(
        runtime: HermesRuntime, home: URL, sessionID: String?, skillIDs: Set<String>?,
        draft: Bool = false, reuseDraftWorker: Bool = false, workspace: URL?, mcpServers: [MCPServer.Connection],
        prewarmOnly: Bool = false, withVision: Bool = false, toolsets: [String]? = nil,
        sessionMCPServers: [MCPServer.Connection]? = nil, budget: HermesGenerationBudget? = nil, temporaryRoot: URL? = nil,
        control: TurnControl? = nil, speculativeGroupWarm: Bool = false, onActivity: @escaping (String) -> Void = { _ in },
        work: @escaping (ACPWorker, String) throws -> Value, completion: @escaping (Result<Value, Error>) -> Void
    ) {
        queue.async {
            guard !HermesProcessLifetime.shared.isClosing else {
                if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
                completion(.failure(CancellationError()))
                return
            }
            let key = sessionID.map { SessionKey(home: home, id: $0) }
            let options = Options(skillIDs: skillIDs, draft: draft, reuseDraftWorker: reuseDraftWorker, mcpServers: mcpServers,
                proxyRange: draft ? nil : HermesProxyDNS.activeRange, withVision: withVision, toolsets: toolsets,
                sessionScopedMCP: sessionMCPServers != nil, budget: budget)
            let warmEpoch = self.prewarmEpoch
            if speculativeGroupWarm {
                guard self.admitsPrewarm(home: home, options: options) else {
                    completion(.failure(CancellationError()))
                    return
                }
                self.prewarming = true
            }
            self.inUse[home, default: 0] += 1
            let start = {
                self.setup(home: home) {
                    var acquired: ACPWorker?
                    do {
                        if control?.isCancelled == true { throw CancellationError() }
                        if speculativeGroupWarm, self.queue.sync(execute: { self.prewarmEpoch != warmEpoch }) {
                            throw CancellationError()
                        }
                        let generation = self.queue.sync { self.generations[home] }
                        let directory = try runtime.sessionDirectory(home: home, workspace: workspace)
                        let worker = try self.checkout(runtime: runtime, home: home, sessionID: sessionID,
                            options: options, generation: generation, onActivity: onActivity, control: control)
                        acquired = worker
                        try control?.attach(worker.process)
                        // 同一角色目录串行准备，独立角色目录可同时启动和载入会话。
                        if !prewarmOnly { onActivity("正在准备 Hermes 会话") }
                        let id = prewarmOnly ? "" : try worker.session(existing: sessionID, workspace: directory,
                            mcpServers: sessionMCPServers ?? [])
                        let finish = { (result: Result<Value, Error>) in
                            self.inUse[home, default: 1] -= 1
                            if speculativeGroupWarm { self.prewarming = false }
                            let canRetain = !speculativeGroupWarm || (self.prewarmEpoch == warmEpoch
                                && self.idle.count < self.effectiveIdleCapacity)
                            if case .success = result, temporaryRoot == nil, !draft || reuseDraftWorker, control?.isCancelled != true,
                                self.generations[home] == generation, worker.process.isRunning,
                                canRetain, !HermesProcessLifetime.shared.isClosing {
                                self.recycle(worker, home: home, speculative: speculativeGroupWarm)
                            } else {
                                worker.close()
                                if temporaryRoot == nil { self.retireIfUnused(home: home) }
                            }
                            self.advance(key)
                        }
                        if prewarmOnly {
                            let result = Result { try work(worker, id) }
                            self.queue.sync { finish(result) }
                            completion(result)
                        } else {
                            // 每个会话独占连接的读取方，流式读取无需占用准备队列。
                            DispatchQueue.global(qos: .userInitiated).async {
                                let result = Result { try work(worker, id) }
                                control?.detach()
                                if let temporaryRoot {
                                    self.queue.sync { finish(result) }
                                    HermesProcessLifetime.shared.finishTemporary(home: home, root: temporaryRoot)
                                } else {
                                    self.queue.async { finish(result) }
                                }
                                completion(result)
                            }
                        }
                    } catch {
                        acquired?.close()
                        control?.detach()
                        self.queue.async {
                            self.inUse[home, default: 1] -= 1
                            if speculativeGroupWarm { self.prewarming = false }
                            if temporaryRoot == nil { self.retireIfUnused(home: home) }
                            self.advance(key)
                        }
                        if let temporaryRoot { HermesProcessLifetime.shared.finishTemporary(home: home, root: temporaryRoot) }
                        completion(.failure(error))
                    }
                }
            }
            if let key {
                if self.waiting[key] != nil {
                    self.waiting[key]?.append(start)
                    return
                }
                self.waiting[key] = []
            }
            start()
        }
    }

    private func admitsPrewarm(home: URL, options: Options) -> Bool {
        expireIdle()
        return idleCapacity > 0 && preferredHomes.contains(home) && !prewarming
            && inUse[home, default: 0] == 0 && idle.count < effectiveIdleCapacity
            && !idle.contains { $0.speculative || ($0.home == home && $0.worker.options == options && $0.worker.process.isRunning) }
    }

    private func setup(home: URL, work: @escaping () -> Void) {
        var lane = setupLanes[home] ?? SetupLane()
        lane.pending += 1
        setupLanes[home] = lane
        lane.queue.async {
            work()
            self.queue.async {
                self.setupLanes[home]?.pending -= 1
                if self.setupLanes[home]?.pending == 0 { self.setupLanes[home] = nil }
            }
        }
    }

    private func advance(_ key: SessionKey?) {
        guard let key else { return }
        if let next = waiting[key]?.first {
            waiting[key]?.removeFirst()
            // 让其他会话的连接请求也有机会先进入队列。
            queue.async { next() }
        } else {
            waiting[key] = nil
        }
    }

    private func checkout(
        runtime: HermesRuntime, home: URL, sessionID: String?, options: Options, generation: UUID?,
        onActivity: (String) -> Void, control: TurnControl?
    ) throws -> ACPWorker {
        let (worker, prepared) = queue.sync { (takeIdleWorker(home: home, sessionID: sessionID, options: options), profileOptions[home]) }
        if let worker {
            do {
                if prepared != options { _ = try prepare(runtime, home: home, options: options, generation: generation) }
                return worker
            } catch {
                worker.close()
                throw error
            }
        }
        onActivity("正在准备 Hermes 配置")
        let env = try prepare(runtime, home: home, options: options, generation: generation)
        if control?.isCancelled == true { throw CancellationError() }
        onActivity("正在启动 Hermes")
        let process = runtime.process(arguments: ["acp"], directory: home.appendingPathComponent("workspace"), overrides: env)
        let refreshMCP: ((String) throws -> Void)?
        if (!options.draft || !options.mcpServers.isEmpty), runtime.usesStudioMCP(home: home) {
            refreshMCP = { [executable = runtime.executable] id in
                // 保留当前网关的会话与权限记录，由 Hermes 刷新它实际使用的 MCP 清单。
                try HermesRuntime(executable: executable)
                    .refreshMCP(sessionID: id, home: home, serverNames: options.mcpServers.map(\.name))
            }
        } else {
            refreshMCP = nil
        }
        let customized = runtime.acpLauncher.configure(process, runtime: runtime)
        do {
            return try ACPWorker(process: process, home: home, options: options, refreshMCP: refreshMCP, control: control)
        } catch where customized && control?.isCancelled != true && !HermesProcessLifetime.shared.isClosing {
            runtime.acpLauncher.useNative()
            let native = runtime.process(arguments: ["acp"], directory: home.appendingPathComponent("workspace"), overrides: env)
            return try ACPWorker(process: native, home: home, options: options, refreshMCP: refreshMCP, control: control)
        }
    }

    private func takeIdleWorker(home: URL, sessionID: String?, options: Options) -> ACPWorker? {
        expireIdle()
        for index in idle.indices.reversed() where idle[index].home == home {
            let worker = idle[index].worker
            if !worker.process.isRunning || (worker.sessionID == sessionID && worker.options != options) {
                idle.remove(at: index).worker.close()
            }
        }
        let matches = idle.indices.filter { idle[$0].home == home && idle[$0].worker.options == options }
        let preferred = matches.last { idle[$0].worker.sessionID == sessionID }
        let index = preferred ?? matches.last(where: { idle[$0].worker.sessionID == nil })
            ?? (options.sessionScopedMCP || (options.reuseDraftWorker && sessionID == nil) ? matches.last : nil)
        return index.map { idle.remove(at: $0).worker }
    }

    private func prepare(_ runtime: HermesRuntime, home: URL, options: Options, generation: UUID?) throws -> [String: String] {
        let environment = try runtime.prepare(home: home, withVision: !options.draft || options.withVision, skillIDs: options.skillIDs,
            draft: options.draft, mcpServers: options.mcpServers, proxyRange: options.proxyRange, toolsets: options.toolsets,
            budget: options.budget)
        queue.sync {
            if generations[home] == generation { profileOptions[home] = options }
        }
        return environment
    }

    private func recycle(_ worker: ACPWorker, home: URL, speculative: Bool) {
        guard idleCapacity > 0 else { worker.close(); retireIfUnused(home: home); return }
        while idle.count >= effectiveIdleCapacity {
            let index = idle.firstIndex(where: \.speculative) ?? idle.firstIndex { !preferredHomes.contains($0.home) } ?? 0
            let entry = idle.remove(at: index)
            entry.worker.close()
            retireIfUnused(home: entry.home)
        }
        idle.append(IdleEntry(home: home, worker: worker, since: .now, speculative: speculative))
        scheduleExpiry()
    }

    private func deadline(for entry: IdleEntry) -> ContinuousClock.Instant {
        let timeout = entry.speculative ? min(idleTimeout, 45)
            : preferredHomes.contains(entry.home) ? max(idleTimeout, 300) : idleTimeout
        return entry.since + .seconds(timeout)
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let next = idle.map(deadline).min() else { expiry = nil; return }
        expiry = Task { [weak self] in
            do { try await Task.sleep(until: next, clock: .continuous) } catch { return }
            self?.queue.async { [weak self] in self?.expireIdle() }
        }
    }

    private func expireIdle() {
        let now = ContinuousClock.now
        for index in idle.indices.reversed() where deadline(for: idle[index]) <= now {
            let entry = idle.remove(at: index)
            entry.worker.close()
            retireIfUnused(home: entry.home)
        }
        scheduleExpiry()
    }

    fileprivate func keepWarm(homes: Set<URL>, idleLimit: Int) {
        queue.async {
            guard self.preferredHomes != homes || self.preferredIdleLimit != idleLimit else { return }
            self.preferredHomes = homes
            self.preferredIdleLimit = idleLimit
            self.prewarmEpoch = UUID()
            for index in self.idle.indices.reversed() where self.idle[index].speculative && !homes.contains(self.idle[index].home) {
                let entry = self.idle.remove(at: index)
                entry.worker.close()
                self.retireIfUnused(home: entry.home)
            }
            while self.idle.filter({ !homes.contains($0.home) }).count > self.idleCapacity {
                guard let index = self.idle.firstIndex(where: { !homes.contains($0.home) }) else { break }
                let entry = self.idle.remove(at: index)
                entry.worker.close()
                self.retireIfUnused(home: entry.home)
            }
            while self.idle.count > self.effectiveIdleCapacity {
                let index = self.idle.firstIndex { !homes.contains($0.home) } ?? 0
                let entry = self.idle.remove(at: index)
                entry.worker.close()
                self.retireIfUnused(home: entry.home)
            }
            self.expireIdle()
        }
    }

    private func retireIfUnused(home: URL) {
        guard inUse[home, default: 0] == 0, !idle.contains(where: { $0.home == home }) else { return }
        setup(home: home) {
            let unused = self.queue.sync { self.inUse[home, default: 0] == 0 && !self.idle.contains { $0.home == home } }
            if unused { HermesProcessLifetime.shared.retireIdle(home: home) }
        }
    }

    fileprivate func reset(home: URL) {
        queue.async {
            self.generations[home] = UUID()
            self.profileOptions[home] = nil
            for index in self.idle.indices.reversed() where self.idle[index].home == home {
                self.idle.remove(at: index).worker.close()
            }
            self.retireIfUnused(home: home)
            self.scheduleExpiry()
        }
    }

    fileprivate func releaseIdle(completion: @escaping () -> Void) {
        queue.async {
            self.prewarmEpoch = UUID()
            let entries = self.idle
            self.idle.removeAll()
            self.scheduleExpiry()
            for entry in entries { entry.worker.close() }
            let group = DispatchGroup()
            for home in Set(entries.map(\.home)) {
                group.enter()
                self.setup(home: home) {
                    let unused = self.queue.sync { self.inUse[home, default: 0] == 0 && !self.idle.contains { $0.home == home } }
                    if unused { HermesProcessLifetime.shared.retireIdle(home: home) }
                    group.leave()
                }
            }
            group.notify(queue: .global(qos: .utility), execute: completion)
        }
    }

    deinit {
        expiry?.cancel()
        for entry in idle { entry.worker.close() }
        let homes = Set(idle.map(\.home))
        DispatchQueue.global(qos: .utility).async {
            for home in homes { HermesProcessLifetime.shared.retireIdle(home: home) }
        }
    }
}

private final class ACPWorker {
    let process: Process
    let rpc: ACPConnection
    let options: ACPWorkerPool.Options
    private let refreshMCP: ((String) throws -> Void)?
    private let home: URL
    private let previousGateway: HermesGatewayControl.Identity?
    private var sessionMCPServers: [MCPServer.Connection] = []
    private(set) var sessionID: String?
    private(set) var hasDeferredModelCatalog = false
    private var sessionPath: String?

    init(process: Process, home: URL, options: ACPWorkerPool.Options, refreshMCP: ((String) throws -> Void)?, control: TurnControl?) throws {
        self.process = process
        self.options = options
        self.refreshMCP = refreshMCP
        self.home = home
        previousGateway = HermesGatewayControl.identify(home: home)
        HermesProcessLifetime.shared.willConnect(home: home, previous: previousGateway)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        rpc = ACPConnection(input: input.fileHandleForWriting, output: output.fileHandleForReading)
        do {
            try HermesProcessLifetime.shared.launch(process)
            try control?.attach(process)
            let initialize = try rpc.call("initialize", parameters: [
                "protocolVersion": 1,
                "clientInfo": ["name": "hermes-studio", "version": "0.3.0"],
                "clientCapabilities": [:]
            ])
            hasDeferredModelCatalog = (initialize["_meta"] as? [String: Any])?["studioModelCatalog"] as? Int == 1
            HermesProcessLifetime.shared.observe(home: home, previous: previousGateway)
        } catch {
            close()
            control?.detach()
            throw error
        }
    }

    func session(existing: String?, workspace: URL, mcpServers: [MCPServer.Connection] = []) throws -> String {
        let path = workspace.path
        var params: [String: Any] = ["cwd": path, "mcpServers": mcpServers.map(\.acpSpecification)]
        let id: String
        let response: [String: Any]
        if let existing {
            if sessionID == existing, sessionPath == path, sessionMCPServers == mcpServers { return existing }
            params["sessionId"] = existing
            response = try rpc.call("session/load", parameters: params)
            guard !response.isEmpty else {
                throw StudioError.message("无法恢复 Hermes 对话。请新建对话后再试。")
            }
            try refreshMCP?(existing)
            id = existing
        } else {
            response = try rpc.call("session/new", parameters: params)
            guard let created = response["sessionId"] as? String else {
                throw StudioError.message("Hermes 没有返回会话编号。")
            }
            id = created
        }
        rpc.recordSettings(response, sessionID: id)
        sessionID = id
        sessionPath = path
        sessionMCPServers = mcpServers
        HermesProcessLifetime.shared.observe(home: home, previous: previousGateway)
        return id
    }

    func loadModelChoices(sessionID: String) throws {
        guard hasDeferredModelCatalog, rpc.modelCatalogs[sessionID] == nil else { return }
        let result = try rpc.call("_studio/model_catalog", parameters: ["sessionId": sessionID])
        guard let catalog = HermesRunSettings(response: result)?.model, let settings = rpc.settings[sessionID] else { return }
        rpc.modelCatalogs[sessionID] = catalog.choices
        rpc.settings[sessionID] = settings.includingModelChoices(catalog.choices)
    }

    func setRunSetting(_ field: HermesRunSettings.Field, value: String, sessionID: String, applyingSavedModel: Bool = false) throws {
        let canApplySavedModel = field == .model && applyingSavedModel && hasDeferredModelCatalog
        guard let current = rpc.settings[sessionID],
            current[field]?.choices.contains(where: { $0.id == value }) == true || canApplySavedModel else {
            throw StudioError.message("Hermes 未提供这个选项，请重新打开运行设置。")
        }
        if current[field]?.value == value { return }
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
                let selected = applied[field],
                field == .model || (field == .effort && value == "default") || selected.value == value else {
                throw StudioError.message("Hermes 没有应用所选设置。")
            }
            rpc.storeSettings(applied, sessionID: sessionID)
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
    fileprivate var modelCatalogs: [String: [HermesRunSettings.Choice]] = [:]

    fileprivate func recordSettings(_ response: [String: Any], sessionID: String) {
        if let parsed = HermesRunSettings(response: response, previous: settings[sessionID]) {
            storeSettings(parsed, sessionID: sessionID)
        }
    }

    fileprivate func storeSettings(_ value: HermesRunSettings, sessionID: String) {
        settings[sessionID] = modelCatalogs[sessionID].map { value.includingModelChoices($0) } ?? value
    }

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func call(
        _ method: String, parameters: [String: Any], timeout: DispatchTimeInterval = .seconds(30),
        control: TurnControl? = nil, cancellation: TurnControl? = nil,
        onPermission: (ToolPermission) -> Void = { _ in },
        onFollowUpReady: () -> Void = {},
        onFollowUpStarted: (UUID) -> Void = { _ in },
        onFollowUpRejected: (UUID) -> Void = { _ in },
        onUpdate: ([String: Any]) -> Void = { _ in }
    ) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let deadline = method == "session/prompt" ? nil : DispatchTime.now() + timeout
        let sessionID = parameters["sessionId"] as? String
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": parameters]
        if let cancellation, let sessionID {
            let data = try Self.encode(request)
            try writeLock.withLock {
                try cancellation.startPrompt { [self] in
                    try send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionID]])
                }
                try input.write(contentsOf: data)
            }
        } else {
            try send(request)
        }
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
            let event = try read(until: deadline, cancellation: cancellation)
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
                    if let control, !control.isCancelled, let sessionID, let params = event["params"] as? [String: Any],
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
                    case "_studio/model_catalog": "Hermes 暂时无法读取模型列表，请重试。"
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
        let data = try Self.encode(message)
        try writeLock.withLock { try input.write(contentsOf: data) }
    }

    private static func encode(_ message: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        return data
    }

    private func sendPermissionResponse(id: Any, option: String?) throws {
        let outcome = option.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        try send(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
    }

    private func read(until deadline: DispatchTime?, cancellation: TurnControl?) throws -> [String: Any] {
        while true {
            if let stopDeadline = cancellation?.stopDeadline, DispatchTime.now() >= stopDeadline {
                throw CancellationError()
            }
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    return message
                }
            } else {
                if deadline != nil || cancellation != nil {
                    var timeout: Int32 = 100
                    if let deadline {
                        let remaining = Int64(deadline.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)
                        guard remaining > 0 else { throw StudioError.message("Hermes 初始化或恢复会话超时，请重试。") }
                        timeout = Int32(clamping: (remaining + 999_999) / 1_000_000)
                    }
                    var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let result = poll(&descriptor, 1, timeout)
                    if result == 0 || (result < 0 && errno == EINTR) { continue }
                    guard result > 0 else { throw StudioError.message("无法读取 Hermes 的回复。") }
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
