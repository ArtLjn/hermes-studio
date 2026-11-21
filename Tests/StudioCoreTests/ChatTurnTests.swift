import Foundation
import XCTest
@testable import StudioCore

final class ChatTurnTests: XCTestCase {
    func testPresentationGroupsConsecutiveToolsAndKeepsTheFinalReplyOutside() throws {
        var guide = Message(.user, "也检查权限")
        guide.isGuidance = true
        let final = Message(.assistant, "已完成检查。")
        var image = Message(.assistant, "")
        image.images = [ChatImage(name: "结果.png", mimeType: "image/png")]
        let messages = [
            Message(.user, "检查项目"),
            Message(.assistant, "正在读取项目文件。"),
            run("1", status: "completed"),
            run("2", status: "failed"),
            guide,
            run("3", status: "completed"),
            final,
            image,
            Message(.user, "继续")
        ]

        let turns = ChatTurn.collect(messages)
        XCTAssertEqual(turns.count, 2)
        let completed = try XCTUnwrap(turns.first).presentation(running: false)
        XCTAssertEqual(completed.process.map { $0.tools.map(\.id) }, [[], ["1", "2"], [], ["3"]])
        XCTAssertEqual(completed.process[2].messages, [guide])
        XCTAssertEqual(Array(completed.reply), [final, image])
        XCTAssertTrue(try XCTUnwrap(turns.first).presentation(running: true).reply.isEmpty)
        XCTAssertTrue(try XCTUnwrap(turns.last).presentation(running: true).process.isEmpty)
    }

    func testOlderDirectReplyAndAnInterruptedToolRunRemainReadable() throws {
        let user = Message(.user, "继续")
        let answer = Message(.assistant, "这是一条直接回复。")
        let old = try JSONDecoder().decode(Message.self,
            from: JSONSerialization.data(withJSONObject: ["id": user.id.uuidString, "author": "user", "text": user.text]))
        XCTAssertNil(old.workDuration)
        XCTAssertNil(old.isGuidance)
        let turns = ChatTurn.collect([old, answer, user, run("1", status: "cancelled")])
        XCTAssertEqual(Array(turns[0].presentation(running: false).reply), [answer])
        XCTAssertEqual(turns[1].presentation(running: false).process.first?.tools.first?.status, "cancelled")
        XCTAssertTrue(turns[1].presentation(running: false).reply.isEmpty)
    }

    func testPermissionParsesCommandAndFileChangesAndUsesOnlyOfferedOptions() throws {
        let command = try XCTUnwrap(ToolPermission([
            "toolCall": ["toolCallId": "perm-check-1", "kind": "execute",
                         "rawInput": ["command": "printf hello", "description": "核验输出"]],
            "options": [["optionId": "once", "name": "允许", "kind": "allow_once"]]
        ]))
        XCTAssertEqual(command.kind, "execute")
        XCTAssertEqual(command.title, "核验输出")
        XCTAssertEqual(command.details, "printf hello")
        XCTAssertEqual(command.options.map(\.id), ["once"])

        let edit = try XCTUnwrap(ToolPermission([
            "toolCall": ["toolCallId": "edit-approval-1", "kind": "edit",
                         "content": [["type": "diff", "path": "/tmp/report.txt", "oldText": "原文", "newText": "更新"]]],
            "options": [["optionId": "deny", "name": "拒绝", "kind": "reject_once"]]
        ]))
        XCTAssertEqual(edit.edit?.path, "/tmp/report.txt")
        XCTAssertEqual(edit.edit?.before, "原文")
        XCTAssertEqual(edit.edit?.after, "更新")
        XCTAssertNil(ToolPermission(["toolCall": ["toolCallId": "bad"], "options": []]))
    }

    func testACPRoutesNativeQueueAsANewRequestOnTheSameConnection() throws {
        try checkNativeQueue(echoesUserMessage: true)
    }

    func testACPGatewaySeparatesQueuedReplyWithoutAUserMessageEvent() throws {
        try checkNativeQueue(echoesUserMessage: false)
    }

    private func checkNativeQueue(echoesUserMessage: Bool) throws {
        let input = Pipe()
        let output = Pipe()
        let rpc = ACPConnection(input: input.fileHandleForWriting, output: output.fileHandleForReading)
        let control = TurnControl()
        let followUpID = UUID()
        let serverFinished = expectation(description: "模拟服务器收到审核答复和 Hermes 原生排队命令")
        let clientFinished = expectation(description: "客户端收到两个独立的回合")

        let client = DispatchQueue(label: "studio.tests.client")
        client.async {
            var updates: [String] = []
            do {
                let result = try rpc.call("session/prompt", parameters: ["sessionId": "session"], control: control,
                    onPermission: { request in
                        XCTAssertFalse(control.respond(to: request.id, optionID: "invented"))
                        XCTAssertFalse(control.enqueueFollowUp(id: followUpID, text: "审核时追加"))
                        XCTAssertTrue(control.respond(to: request.id, optionID: "deny"))
                    }, onFollowUpReady: {
                        if updates.isEmpty {
                            XCTAssertTrue(control.enqueueFollowUp(id: followUpID, text: "继续检查\n并给出结论"))
                            XCTAssertFalse(control.enqueueFollowUp(id: UUID(), text: "同时发送"))
                        }
                    }, onFollowUpStarted: { id in
                        XCTAssertEqual(id, followUpID)
                        updates.append("追问已开始")
                    }, onFollowUpRejected: { _ in
                        XCTFail("支持排队的 Hermes 应接收请求")
                    }, onUpdate: { update in
                        if update["sessionUpdate"] as? String == "agent_message_chunk",
                            let block = update["content"] as? [String: String], let text = block["text"] {
                            updates.append(text)
                        }
                    })
                XCTAssertEqual(result["stopReason"] as? String, "end_turn")
                XCTAssertEqual(updates, ["原始回复", "追问已开始", "追问回复"])
                XCTAssertFalse(control.enqueueFollowUp(id: UUID(), text: "回合已结束"))
            } catch {
                XCTFail(error.localizedDescription)
            }
            clientFinished.fulfill()
        }

        DispatchQueue.global().async {
            defer { serverFinished.fulfill() }
            let send: ([String: Any]) throws -> Void = { event in
                var data = try JSONSerialization.data(withJSONObject: event)
                data.append(10)
                try output.fileHandleForWriting.write(contentsOf: data)
            }
            let update: ([String: Any]) throws -> Void = { content in
                try send(["jsonrpc": "2.0", "method": "session/update",
                    "params": ["sessionId": "session", "update": content]])
            }
            let read: () throws -> [String: Any] = {
                var data = Data()
                while let byte = try input.fileHandleForReading.read(upToCount: 1)?.first, byte != 10 {
                    data.append(byte)
                }
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
            do {
                let primary = try read()
                try update(["sessionUpdate": "available_commands_update", "availableCommands": [["name": "queue"]]])
                try send(["jsonrpc": "2.0", "id": 21, "method": "session/request_permission", "params": [
                    "sessionId": "session",
                    "toolCall": ["toolCallId": "edit-1", "kind": "edit"],
                    "options": [["optionId": "deny", "name": "拒绝", "kind": "reject_once"]]
                ]])
                let reply = try read()
                let selection = (reply["result"] as? [String: Any])?["outcome"] as? [String: String]
                XCTAssertEqual(reply["id"] as? Int, 21)
                XCTAssertEqual(selection, ["outcome": "selected", "optionId": "deny"])

                try update(["sessionUpdate": "agent_thought_chunk"])
                let queued = try read()
                XCTAssertEqual(queued["id"] as? String, followUpID.uuidString)
                let params = queued["params"] as? [String: Any]
                XCTAssertEqual(params?["sessionId"] as? String, "session")
                let prompt = params?["prompt"] as? [[String: String]]
                XCTAssertEqual(prompt?.first?["text"], "/queue 继续检查\n并给出结论")

                try update(["sessionUpdate": "agent_message_chunk", "content": ["text": "Queued for the next turn. (1 queued)"]])
                try update(["sessionUpdate": "agent_message_chunk", "content": ["text": "原始回复"]])
                let end = ["stopReason": "end_turn"]
                let originalEnd: [String: Any] = ["jsonrpc": "2.0", "id": try XCTUnwrap(primary["id"]), "result": end]
                if echoesUserMessage {
                    try update(["sessionUpdate": "user_message_chunk", "content": ["text": "继续检查\n并给出结论"]])
                    try update(["sessionUpdate": "agent_message_chunk", "content": ["text": "追问回复"]])
                    try send(originalEnd)
                } else {
                    try send(originalEnd)
                    try update(["sessionUpdate": "agent_message_chunk", "content": ["text": "追问回复"]])
                }
                try send(["jsonrpc": "2.0", "id": followUpID.uuidString, "result": end])
            } catch {
                XCTFail(error.localizedDescription)
            }
        }

        wait(for: [serverFinished, clientFinished], timeout: 5)
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForWriting.close()
    }

    func testLiveHermesRunsNativeFollowUpAfterTheOriginalReply() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后验证 Hermes 原生追问。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "追问验证", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let project = try store.createProject(name: "追问测试", directory: nil, for: role.id)
        let control = TurnControl()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            control.cancel()
        }
        defer { timeout.cancel() }

        let followUpID = UUID()
        var sent = false
        var started = false
        var original = ""
        var followUp = ""
        var stopReason: String?
        for await event in runtime.turn(home: store.runtime(for: role.id), conversation: Conversation(roleID: role.id),
            text: "请调用 terminal 执行 `sleep 4 && printf ready`，完成后仅回复 ORIGINAL-TURN。",
            workspace: project.directory, interactive: true, control: control) {
            switch event {
            case .followUpReady where !sent:
                sent = control.enqueueFollowUp(id: followUpID, text: "这是下一条问题。请只输出 FOLLOWUP-TURN。")
            case .followUpStarted(let id): started = id == followUpID
            case .followUpRejected: XCTFail("Hermes 拒绝了原生追问。")
            case .permission(let request): _ = control.respond(to: request.id, optionID: nil)
            case .text(let text, _):
                if started { followUp += text }
                else { original += text }
            case .finished(let reason): stopReason = reason
            case .failed(let message): throw StudioError.message(message)
            default: break
            }
        }
        XCTAssertTrue(sent && started)
        XCTAssertEqual(stopReason, "end_turn")
        XCTAssertTrue(original.contains("ORIGINAL-TURN"), original)
        XCTAssertFalse(original.contains("FOLLOWUP-TURN"), original)
        XCTAssertTrue(followUp.contains("FOLLOWUP-TURN"), followUp)
        XCTAssertFalse(original.contains("Queued for the next turn"), original)
    }

    func testLiveHermesInsertsIntoActiveTurnAndRefusesAfterItEnds() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后验证执行中插入。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RoleStore(root: root)
        let role = Role(name: "插入验证", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let home = store.runtime(for: role.id)
        defer {
            runtime.reset(home: home)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try store.createProject(name: "插入验证", directory: nil, for: role.id)
        let control = TurnControl()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(80)) } catch { return }
            control.cancel()
        }
        defer { timeout.cancel() }
        let id = UUID()
        let insertion = "补充原任务，不需要重跑命令。最终答复请保留原始标记，并附上 INSERT-SAME-TURN-OK。"
        var sessionID: String?
        var sent = false
        var accepted = false
        var ended = false
        var answer = ""
        for await event in runtime.turn(home: home, conversation: Conversation(roleID: role.id),
            text: "请只调用一次 terminal 执行 `sleep 10 && printf ready`，完成后答复必须包含原始标记 ORIGINAL-WORK。",
            workspace: project.directory, interactive: true, control: control) {
            switch event {
            case .session(let value): sessionID = value
            case .tool(let tool) where tool.category == "execute" && tool.isRunning && !sent:
                sent = control.insert(id: id, text: insertion)
            case .insertionAccepted(let receivedID, let text):
                XCTAssertFalse(ended)
                XCTAssertEqual(receivedID, id)
                XCTAssertEqual(text, insertion)
                accepted = true
            case .insertionFailed(_, let error): XCTFail(error)
            case .text(let text, _): answer += text
            case .permission(let request): _ = control.respond(to: request.id, optionID: nil)
            case .finished(let status):
                XCTAssertEqual(status, "end_turn")
                ended = true
            case .failed(let error): throw StudioError.message(error)
            default: break
            }
        }
        XCTAssertTrue(sent && accepted && ended)
        XCTAssertTrue(answer.contains("ORIGINAL-WORK"), answer)
        XCTAssertTrue(answer.contains("INSERT-SAME-TURN-OK"), answer)
        do {
            try await runtime.insertIntoRunningTurn("过期的补充", sessionID: XCTUnwrap(sessionID), home: home)
            XCTFail("回合结束后，插入请求不应进入新一轮。")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("回合已经结束"), error.localizedDescription)
        }
    }

    func testLiveHermesDeniesFileEditBeforeWriting() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后验证真实文件审核。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "审核验证", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let project = try store.createProject(name: "审核测试", directory: nil, for: role.id)
        let file = project.directory.appendingPathComponent("approval-check.txt")
        try Data("BEFORE".utf8).write(to: file)
        let control = TurnControl()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            control.cancel()
        }
        defer { timeout.cancel() }

        var approval: ToolPermission?
        for await event in runtime.turn(home: store.runtime(for: role.id), conversation: Conversation(roleID: role.id),
            text: "请只用 write_file 将 ./approval-check.txt 改成 AFTER。遇到拒绝就结束，不要重试。",
            workspace: project.directory, interactive: true, control: control) {
            switch event {
            case .permission(let request):
                if request.kind == "edit" { approval = request }
                let deny = request.options.first(where: { $0.kind == "reject_once" })
                XCTAssertTrue(control.respond(to: request.id, optionID: deny?.id))
            case .failed(let message): throw StudioError.message(message)
            default: break
            }
        }
        let request = try XCTUnwrap(approval)
        XCTAssertEqual(request.edit?.before, "BEFORE")
        XCTAssertEqual(request.edit?.after?.trimmingCharacters(in: .whitespacesAndNewlines), "AFTER")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "BEFORE")
    }

    private func run(_ id: String, status: String) -> Message {
        var message = Message(.tool, "")
        message.tool = ToolRun(id: id, title: "terminal: 检查", status: status, details: nil)
        return message
    }
}
