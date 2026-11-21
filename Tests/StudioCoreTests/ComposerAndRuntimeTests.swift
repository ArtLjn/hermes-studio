import Foundation
import XCTest
@testable import StudioCore

final class ComposerAndRuntimeTests: XCTestCase {
    func testCompletionUsesLatestUserInputInCurrentRoleAndProject() {
        let roleID = UUID()
        let projectID = UUID()
        var otherRole = Conversation(roleID: UUID())
        otherRole.projectID = projectID
        otherRole.messages = [Message(.user, "整理其他角色的内容")]
        var ungrouped = Conversation(roleID: roleID)
        ungrouped.messages = [Message(.user, "整理非项目记录")]
        var project = Conversation(roleID: roleID)
        project.projectID = projectID
        project.messages = [Message(.user, "整理旧稿"), Message(.user, "整理最新记录\n第二行"),
            Message(.assistant, "整理助手的回复")]
        let threads = [otherRole, ungrouped, project]
        XCTAssertEqual(ChatCompletion.suffix(for: "整理", in: threads, roleID: roleID, projectID: projectID), "最新记录")
        XCTAssertEqual(ChatCompletion.suffix(for: "独立前文\n第", in: threads, roleID: roleID, projectID: projectID), "二行")
        XCTAssertNil(ChatCompletion.suffix(for: "第二行", in: threads, roleID: roleID, projectID: projectID))
        XCTAssertEqual(ChatCompletion.suffix(for: "整理", in: threads, roleID: roleID, projectID: nil), "非项目记录")
        XCTAssertNil(ChatCompletion.suffix(for: "整理助手", in: threads, roleID: roleID, projectID: projectID))
        XCTAssertNil(ChatCompletion.suffix(for: " /skill", in: threads, roleID: roleID, projectID: projectID))
    }

    func testTerminalCompletionReadsNewestInputAndRefreshesWhenHistoryChanges() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".hermes_history")
        let history = HermesInputHistory()
        let oldHistory = """
            # 日期
            +hermes 旧问题

            # 日期
            +前文
            +hermes如何与claudecode搭配使用
            +第二行
            不属于终端输入
            +/help

            """
        let missing = await history.suffix(for: "hermes", in: home)
        XCTAssertNil(missing)
        try Data(oldHistory.utf8).write(to: file)

        let newest = await history.suffix(for: "hermes", in: home)
        let multiline = await history.suffix(for: "其他前文\n第二", in: home)
        let blank = await history.suffix(for: "hermes\n ", in: home)
        let slash = await history.suffix(for: "/he", in: home)
        let metadata = await history.suffix(for: "不属于", in: home)
        XCTAssertEqual(newest, "如何与claudecode搭配使用")
        XCTAssertEqual(multiline, "行")
        XCTAssertNil(blank)
        XCTAssertNil(slash)
        XCTAssertNil(metadata)

        let stream = try FileHandle(forWritingTo: file)
        try stream.seekToEnd()
        try stream.write(contentsOf: Data("\n# 日期\n+hermes使用方法\n".utf8))
        try stream.close()
        let updated = await history.suffix(for: "hermes", in: home)
        let exact = await history.suffix(for: "hermes使用方法", in: home)
        let otherProfile = await history.suffix(for: "hermes", in: home.appendingPathComponent("另一份配置"))
        XCTAssertEqual(updated, "使用方法")
        XCTAssertNil(exact)
        XCTAssertNil(otherProfile)
    }

    func testConversationStarterFiltersInvalidDuplicateAndExcessQuestions() throws {
        let response = """
            ```json
            {"questions":[
              " 怎么整理术语表？ ",
              "指令式文案",
              "怎么整理术语表？",
              "/reset?",
              "本周有哪些重点值得回顾？",
              "怎样拆解下一步工作？",
              "还有哪些额外建议？"
            ]}
            ```
            """
        let suggestions = try ConversationStarter.parse(response)
        XCTAssertEqual(suggestions, ["怎么整理术语表？", "本周有哪些重点值得回顾？", "怎样拆解下一步工作？"])
        XCTAssertThrowsError(try ConversationStarter.parse("无效回复"))
    }

    func testLiveConversationStartersUseRoleMemory() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后验证记忆推荐。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let role = Role(name: "测试写作搭档", summary: "负责准备科普活动", template: .writing)
        let suggestions = try await runtime.suggestConversationStarters(role: role,
            memory: "当前唯一工作是为青少年筹备一场月球科普展。尚未完成展板文字、参观问题和讲解提纲。",
            user: "喜欢短句和面向初学者的表达。", projectName: nil)
        XCTAssertTrue(suggestions.contains { $0.contains("月球") }, "问题应点明记忆里的月球主题，实际问题：\(suggestions)")
    }

    func testNativeReferenceUsesCaretAndPreservesOtherText() throws {
        let draft = "讨论 🌕 @行星 后续内容"
        let reference = try XCTUnwrap(HermesCompletion.reference(at: "讨论 🌕 @行星".utf16.count, in: draft))
        XCTAssertEqual(reference.word, "@行星")
        XCTAssertEqual((draft as NSString).replacingCharacters(in: reference.range, with: "@file:行星.md"),
            "讨论 🌕 @file:行星.md 后续内容")
        XCTAssertNil(HermesCompletion.reference(at: "邮箱a@b".utf16.count, in: "邮箱a@b"))
    }

    func testLiveNativeCompletionLooksUpCommandsAndProjectFiles() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后验证原生命令与文件补全。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("项目", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("行星 展板.md"))
        let outside = root.appendingPathComponent("行星归档.md")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("行星链接.md"), withDestinationURL: outside)

        let commands = await runtime.complete(.slash("/he"))
        XCTAssertTrue(commands.contains { $0.text == "/help" })
        XCTAssertFalse(commands.contains { $0.text == "/heartbeat" })
        let files = await runtime.complete(.reference(word: "@行星", project: project))
        XCTAssertEqual(files.map(\.insertion), ["@file:\"行星 展板.md\" "])
    }

    func testSlashSkillKeepsOtherTextAndAcceptsChineseSearch() throws {
        let draft = "前文\n请用 /cod 后续"
        let position = ("前文\n请用 /cod" as NSString).length
        let command = try XCTUnwrap(SkillCommand.atCaret(position, in: draft))
        XCTAssertEqual(command.query, "cod")
        XCTAssertEqual((draft as NSString).replacingCharacters(in: command.range, with: ""), "前文\n请用  后续")
        let chinese = "/skill 写作"
        XCTAssertEqual(SkillCommand.atCaret((chinese as NSString).length, in: chinese)?.query, "写作")
        XCTAssertEqual(SkillCommand.atCaret(1, in: "/")?.query, "")
        XCTAssertNil(SkillCommand.atCaret(9, in: "/tmp/file"))
    }

    func testRoleDraftFiltersUnknownSkillsAndPreservesTerminalMemory() throws {
        let skills = [HermesSkill(id: "writing/edit", name: "edit", summary: "中文编辑")]
        XCTAssertEqual(HermesSkill.matching("编辑", in: skills), skills)
        let response = """
            ```json
            {"name":"编辑","summary":"改稿","instructions":"保留事实。","skillIDs":["writing/edit","不存在"]}
            ```
            """
        let suggestion = try RoleSuggestion.parse(response, catalog: skills)
        XCTAssertEqual(suggestion.skillIDs, ["writing/edit"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("terminal")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("memories"), withIntermediateDirectories: true)
        let memory = source.appendingPathComponent(RoleFile.memory.rawValue)
        try Data("原始记忆".utf8).write(to: memory)
        let store = RoleStore(root: root.appendingPathComponent("studio"))
        var role = Role(name: suggestion.name, summary: suggestion.summary, template: .blank)
        role.skillIDs = suggestion.skillIDs
        try store.create(role, instructions: suggestion.instructions, initialMemory: [.memory: RoleStore.readFile(.memory, in: source)])
        XCTAssertEqual(try store.list().first?.skillIDs, suggestion.skillIDs)
        try store.writeFile(.memory, for: role.id, text: "桌面副本的记忆")
        XCTAssertEqual(try RoleStore.readFile(.memory, in: source), "原始记忆")
    }

    func testTerminalChatReopensTheSameRoleAndKeepsOriginalMemorySeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("terminal", isDirectory: true)
        let desktop = root.appendingPathComponent("desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("memories"), withIntermediateDirectories: true)
        for (file, contents) in [(RoleFile.soul, "原始角色指令"), (.memory, "原始长期记忆"), (.user, "原始用户偏好")] {
            try Data(contents.utf8).write(to: source.appendingPathComponent(file.rawValue))
        }

        let store = RoleStore(root: desktop)
        let role = try store.terminalChatRole(from: source)
        XCTAssertEqual(role.name, "终端 Hermes")
        XCTAssertEqual(try store.file(.soul, for: role.id), "原始角色指令")
        XCTAssertEqual(try store.file(.memory, for: role.id), "原始长期记忆")
        XCTAssertEqual(try store.file(.user, for: role.id), "原始用户偏好")
        try store.writeFile(.memory, for: role.id, text: "桌面端的新记忆")
        var conversation = Conversation(roleID: role.id)
        conversation.title = "继续聊天"
        try store.save(conversation)

        let reopened = RoleStore(root: desktop)
        let sameRole = try reopened.terminalChatRole(from: source)
        XCTAssertEqual(sameRole.id, role.id)
        XCTAssertEqual(try reopened.list().count, 1)
        XCTAssertEqual(try reopened.conversations(for: sameRole.id).first?.id, conversation.id)
        XCTAssertEqual(try reopened.file(.memory, for: sameRole.id), "桌面端的新记忆")
        XCTAssertEqual(try RoleStore.readFile(.memory, in: source), "原始长期记忆")
    }

    func testArchivedRoleRestoresItsAvatarMemoryAndConversationUntilDeadline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        var role = Role(name: "会议整理", summary: "整理纪要", template: .blank)
        role.avatar = .illustration(.lavender)
        try store.create(role, instructions: "整理待办", initialMemory: [.memory: "保留会议决策"])
        let other = Role(name: "其他角色", summary: "", template: .blank)
        try store.create(other, instructions: "")
        var conversation = Conversation(roleID: role.id)
        conversation.title = "上周会议"
        try store.save(conversation)

        let archivedAt = Date(timeIntervalSince1970: 1_000)
        let deadline = archivedAt.addingTimeInterval(30 * 86_400)
        XCTAssertEqual(try store.archive(role.id, now: archivedAt).archiveDeadline, deadline)
        XCTAssertEqual(try store.list().map(\.id), [other.id])

        let reopened = RoleStore(root: root)
        XCTAssertEqual(try reopened.archivedRoles().map(\.id), [role.id])
        try reopened.purgeExpiredRoles(now: deadline.addingTimeInterval(-1))
        let restored = try reopened.restore(role.id, now: deadline.addingTimeInterval(-1))
        XCTAssertEqual(restored.id, role.id)
        XCTAssertEqual(restored.avatar, role.avatar)
        XCTAssertNil(restored.archivedAt)
        XCTAssertTrue(try reopened.archivedRoles().isEmpty)
        XCTAssertEqual(try reopened.file(.memory, for: role.id), "保留会议决策")
        XCTAssertEqual(try reopened.conversations(for: role.id).map(\.id), [conversation.id])

        _ = try reopened.archive(role.id, now: archivedAt)
        XCTAssertThrowsError(try reopened.restore(role.id, now: deadline))
        try reopened.purgeExpiredRoles(now: deadline)
        XCTAssertTrue(try reopened.archivedRoles().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.runtime(for: role.id).path))
        XCTAssertEqual(try reopened.list().map(\.id), [other.id])
    }

    func testACPReusesWorkerAndSessionAndReloadsAfterReset() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("模拟 ACP 需要系统 Python。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "测试角色", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let home = store.runtime(for: role.id)
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let scope: Set<String> = []
        runtime.warm(home: home, conversation: nil, skillIDs: scope)
        var conversation = Conversation(roleID: role.id)

        func send() async throws -> String? {
            let control = TurnControl()
            let timeout = Task {
                try await Task.sleep(for: .seconds(15))
                control.cancel()
            }
            defer { timeout.cancel() }
            var id: String?
            for await event in runtime.turn(home: home, conversation: conversation, text: "测试", skillIDs: scope, control: control) {
                switch event {
                case .session(let newID): id = newID
                case .finished(let reason): XCTAssertEqual(reason, "end_turn")
                case .failed(let message): throw StudioError.message(message)
                default: break
                }
            }
            return id
        }
        let created = try await send()
        conversation.sessionID = try XCTUnwrap(created)
        _ = try await send()
        runtime.reset(home: home)
        _ = try await send()
        let methods = try String(contentsOf: home.appendingPathComponent("calls"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(methods, ["initialize", "session/new", "session/prompt", "session/prompt", "initialize", "session/load", "session/prompt"])
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("config.yaml"))) as? [String: Any])
        XCTAssertEqual((config["platform_toolsets"] as? [String: [String]])?["acp"], ["memory", "session_search"])
    }

    func testRunSettingsPreserveNativeModelIDsAndEffortReset() throws {
        let model: [String: Any] = ["id": "model", "currentValue": "custom:proxy:model",
            "options": [["name": "代理", "options": [["value": "custom:proxy:model", "name": "当前模型"]]]]]
        let original: [String: Any] = ["id": "reasoning_effort", "currentValue": "default",
            "options": [["value": "default", "name": "default"], ["value": "high", "name": "high"]]]
        let selected: [String: Any] = ["id": "reasoning_effort", "currentValue": "high",
            "options": [["value": "high", "name": "high"]]]
        let initial = try XCTUnwrap(HermesRunSettings(response: ["configOptions": [model, original]]))
        let updated = try XCTUnwrap(HermesRunSettings(response: ["configOptions": [selected]], previous: initial))
        XCTAssertEqual(updated.model?.value, "custom:proxy:model")
        XCTAssertEqual(updated.model?.name, "当前模型")
        XCTAssertEqual(updated.effort?.value, "high")
        XCTAssertEqual(updated.effort?.choices.map(\.id), ["default", "high"])
        XCTAssertFalse(updated.modelUsesLegacyMethod)

        let legacy = try XCTUnwrap(HermesRunSettings(response: ["models": [
            "currentModelId": "provider:model",
            "availableModels": [["modelId": "provider:model", "name": "旧版模型"]]
        ]]))
        XCTAssertTrue(legacy.modelUsesLegacyMethod)
        XCTAssertEqual(legacy.model?.name, "旧版模型")
        XCTAssertNil(legacy.effort)
    }

    func testLiveHermesAppliesRunSettingsBeforeFirstMessage() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后验证模型和推理强度。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "运行设置验收", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let home = store.runtime(for: role.id)
        let prepared = try await runtime.runSettings(home: home, sessionID: nil)
        let model = try XCTUnwrap(prepared.settings?.model)
        XCTAssertTrue(model.choices.contains { $0.id == model.value })
        let provider = model.value.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        guard let target = model.choices.first(where: { $0.id.hasPrefix(provider + ":") && $0.id != model.value })?.id else {
            throw XCTSkip("当前供应商只提供一个模型，无法实测切换。")
        }
        let modelResult = try await runtime.runSettings(home: home, sessionID: prepared.id, change: (.model, target))
        let chosenModel = try XCTUnwrap(modelResult.settings?.model?.value)
        XCTAssertEqual(modelResult.id, prepared.id)
        XCTAssertEqual(chosenModel, target)

        let effort = try XCTUnwrap(modelResult.settings?.effort)
        let option = try XCTUnwrap(effort.choices.first { ["low", "medium", "high"].contains($0.id) && $0.id != effort.value })
        let configured = try await runtime.runSettings(home: home, sessionID: prepared.id, change: (.effort, option.id))
        XCTAssertEqual(configured.settings?.effort?.value, option.id)

        var thread = Conversation(roleID: role.id)
        thread.sessionID = prepared.id
        let control = TurnControl()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(75)) } catch { return }
            control.cancel()
        }
        defer { timeout.cancel() }
        var answer = ""
        var applied: HermesRunSettings?
        for await event in runtime.turn(home: home, conversation: thread, text: "请只回复 RUN-SETTINGS-OK。",
            interactive: true, control: control) {
            switch event {
            case .runSettings(let settings): applied = settings
            case .text(let text, _): answer += text
            case .failed(let message): throw StudioError.message(message)
            case .finished(let reason): XCTAssertEqual(reason, "end_turn")
            default: break
            }
        }
        XCTAssertEqual(applied?.model?.value, chosenModel)
        XCTAssertEqual(applied?.effort?.value, option.id)
        XCTAssertTrue(answer.contains("RUN-SETTINGS-OK"), answer)
    }

    func testRunSettingsUseAdvertisedEditApprovalOptions() throws {
        let legacy: [String: Any] = ["currentModeId": "default", "availableModes": [
            ["id": "default", "name": "Default"], ["id": "accept_edits", "name": "Accept Edits"]
        ]]
        let native: [String: Any] = ["id": "edit_approval_policy", "currentValue": "ask", "options": [
            ["value": "ask", "name": "Default"], ["value": "workspace_session", "name": "Accept Edits"],
            ["value": "session", "name": "Don't Ask"]
        ]]
        let modern = try XCTUnwrap(HermesRunSettings(response: ["configOptions": [native], "modes": legacy]))
        XCTAssertEqual(modern.editApproval?.choices.map(\.id), ["ask", "workspace_session", "session"])
        XCTAssertFalse(modern.editApprovalUsesLegacyMethod)
        let older = try XCTUnwrap(HermesRunSettings(response: ["modes": legacy]))
        XCTAssertEqual(older.editApproval?.choices.map(\.id), ["default", "accept_edits"])
        XCTAssertTrue(older.editApprovalUsesLegacyMethod)
        XCTAssertEqual(older.settingLegacyEditApproval("accept_edits").editApproval?.value, "accept_edits")
    }

    func testLiveHermesSwitchesNativeEditApprovalModes() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后验证编辑权限。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RoleStore(root: root)
        let role = Role(name: "编辑权限验收", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let home = store.runtime(for: role.id)
        defer {
            runtime.reset(home: home)
            try? FileManager.default.removeItem(at: root)
        }

        let prepared = try await runtime.runSettings(home: home, sessionID: nil)
        let approval = try XCTUnwrap(prepared.settings?.editApproval)
        let manual = approval.value
        let scopes = approval.choices.map(\.id).filter { $0 != manual }
        XCTAssertFalse(scopes.isEmpty)
        for scope in scopes + [manual] {
            let updated = try await runtime.runSettings(home: home, sessionID: prepared.id, change: (.editApproval, scope))
            XCTAssertEqual(updated.settings?.editApproval?.value, scope)
            XCTAssertEqual(updated.id, prepared.id)
        }
        let another = try await runtime.runSettings(home: home, sessionID: nil)
        XCTAssertNotEqual(another.id, prepared.id)
        XCTAssertEqual(another.settings?.editApproval?.value, manual)
    }

    func testLiveRoleSuggestionUsesInstalledSkillIDs() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后验证智能创建。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let skills = runtime.installedSkills().filter { $0.name == "project-readme-and-docs" }
        let draft = try await runtime.suggestRole(for: "专门为软件项目整理 README 和使用说明，把安装步骤写得容易验证。", skills: skills)
        XCTAssertFalse(draft.name.isEmpty)
        XCTAssertFalse(draft.instructions.isEmpty)
        XCTAssertTrue(draft.skillIDs.isSubset(of: skills.map(\.id)))
        if !skills.isEmpty { XCTAssertFalse(draft.skillIDs.isEmpty) }
    }

    private static let fixture = """
        #!/usr/bin/python3
        import json, os, sys
        from pathlib import Path
        if sys.argv[1:] != ["acp"]:
            if sys.argv[-1] == "model":
                print(json.dumps({"default": "tester", "provider": "fixture"}))
            elif sys.argv[-1] == "custom_providers":
                print("[]")
            else:
                print("{}")
            sys.exit(0)
        for line in sys.stdin:
            req = json.loads(line)
            method = req["method"]
            with (Path(os.environ["HERMES_HOME"]) / "calls").open("a") as f:
                print(method, file=f)
            result = {"ok": True}
            if method == "session/new":
                result = {"sessionId": "saved-session"}
            if method == "session/prompt":
                result = {"stopReason": "end_turn"}
            print(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}), flush=True)
        """
}
