import AppKit
import Foundation
import StudioCore
import SwiftUI
import XCTest
@testable import HermesStudio

final class StudioSessionTests: XCTestCase {
    @MainActor
    func testPrivateChatSendsASelectedSkillWithoutText() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("模拟 ACP 需要系统 Python。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "技能助手", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let skillDirectory = root.appendingPathComponent("fixture-skills/studio-send-fixture")
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try Data("---\nname: 发送验证技能\n---\n".utf8).write(to: skillDirectory.appendingPathComponent("SKILL.md"))
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let skill = try XCTUnwrap(runtime.installedSkills().first { $0.name == "发送验证技能" })
        let studio = StudioModel(dataStore: store, runtime: runtime, runPreferences: .init())
        defer { runtime.reset(home: store.runtime(for: role.id)) }
        studio.select(role)
        try await waitUntil { studio.availableSkills.contains(skill) }

        studio.draft = " \n"
        XCTAssertFalse(studio.canSend)
        studio.selectedSkill = skill
        XCTAssertTrue(studio.canSend)
        studio.send()
        let sent = try XCTUnwrap(studio.conversation)
        XCTAssertEqual(sent.title, skill.name)
        XCTAssertEqual(sent.messages.first?.text, "")
        XCTAssertEqual(sent.messages.first?.skill, skill.name)
        XCTAssertNil(studio.selectedSkill)

        studio.selectedSkill = skill
        XCTAssertFalse(studio.canSend)
        studio.selectedSkill = nil
        try await waitUntil { !studio.isGeneratingHere }
        XCTAssertEqual(studio.conversation?.messages.last?.text, "已收到单独发送的技能")
        let persisted = try XCTUnwrap(store.conversations(for: role.id).first?.messages.first)
        XCTAssertEqual(persisted.id, sent.messages.first?.id)
        XCTAssertEqual(persisted.skill, skill.name)
    }

    @MainActor
    func testGroupMessageRoutesToSelectedMembersAndFollowsRelayOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let sugar = Role(name: "糖糖", summary: "", template: .blank)
        let pomelo = Role(name: "柚子", summary: "", template: .blank)
        let third = Role(name: "第三位", summary: "", template: .blank)
        let members = [sugar, pomelo, third]
        for role in members { try roles.create(role, instructions: "") }
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let fileURL = root.appendingPathComponent("清单.txt")
        try Data("附件内容".utf8).write(to: fileURL)
        let file = try GroupAttachment(file: fileURL)
        let source = GroupTurn(role: sugar, question: "你哄哄她", attachments: [file])
        var thread = GroupDiscussion(title: "群聊", goal: "", memberIDs: members.map(\.id))
        thread.turns = [source]
        thread.recordReply("给你一颗糖。\n@柚子 现在还生气吗？", at: 0, activeMembers: members)
        let groupStore = GroupDiscussionStore(root: root)
        try groupStore.save(thread)
        let profiles = groupStore.runtimeStore(for: thread.id)
        defer { for role in members { runtime.reset(home: profiles.runtime(for: role.id)) } }
        let model = GroupWorkspaceModel(roleStore: roles, collaborationExecutable: nil)

        XCTAssertFalse(model.submit(groupID: thread.id, roleIDs: [sugar.id, UUID()], question: "无效收件人",
            attachments: [], runtime: runtime))
        XCTAssertEqual(model.discussions.first?.turns.count, 1)
        XCTAssertTrue(model.submit(groupID: thread.id, roleIDs: [pomelo.id, sugar.id, pomelo.id], question: "各说一句",
            attachments: [file], runtime: runtime))
        try await waitUntil { model.discussions.first?.turns.filter { $0.state == .completed }.count == 3 }
        let saved = try XCTUnwrap(GroupWorkspaceModel(roleStore: roles, collaborationExecutable: nil).discussions.first)
        let directed = Array(saved.turns.dropFirst())
        let first = try XCTUnwrap(directed.first)
        XCTAssertEqual(directed.map(\.roleID), [pomelo.id, sugar.id])
        XCTAssertEqual(directed.map(\.initiatedByUser), [true, false])
        XCTAssertEqual(directed.map(\.taskID), [first.id, first.id])
        XCTAssertEqual(directed.map { saved.attachments(for: $0) }, [[file], [file]])

        model.followRelay(groupID: thread.id, turnID: source.id, runtime: runtime)
        model.followRelay(groupID: thread.id, turnID: source.id, runtime: runtime)
        try await waitUntil { model.discussions.first?.turns.last?.answer == "柚子完成发言" }
        let completed = try XCTUnwrap(model.discussions.first)
        XCTAssertEqual(completed.turns.count, 4)
        XCTAssertEqual(completed.turns.first?.relay?.reviewed, true)
        XCTAssertEqual(completed.turns.last?.requesterID, sugar.id)
        XCTAssertEqual(completed.turns.last?.question, "现在还生气吗？")
        XCTAssertEqual(completed.turns.last?.attachments, [file])
    }

    @MainActor
    func testGroupSelectionIsLazyAndThreadsReuseOneRoleProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let members = ["甲", "乙", "丁"].map { Role(name: $0, summary: "", template: .blank) }
        for role in members { try roles.create(role, instructions: "测试群进程复用") }
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let model = GroupWorkspaceModel(roleStore: roles, collaborationExecutable: nil)
        let id = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "按需启动",
            goal: "", memberIDs: members.map(\.id), relayLimit: 0,
            firstTask: "", firstSpeaker: nil, runtime: runtime))
        let childID = try XCTUnwrap(model.newConversation(in: id))
        let group = try XCTUnwrap(model.discussions.first { $0.id == id })
        let catalog = GroupDiscussionStore(root: root)
        let profiles = catalog.pooledRuntimeStore(for: group, role: members[0], fullAccess: false)
        let home = profiles.runtime(for: members[0].id)
        model.visibleThreadID = childID
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertTrue(model.discussions.allSatisfy { $0.pooledSessions == nil })

        for (offset, target) in [id, childID, id].enumerated() {
            XCTAssertTrue(model.submit(groupID: target, roleID: members[0].id, question: "只回答本次消息",
                attachments: [], runtime: runtime))
            try await waitUntil { model.discussions.flatMap(\.turns).filter { $0.state == .completed }.count == offset + 1 }
        }
        let data = try String(contentsOf: home.appendingPathComponent("warm-events.jsonl"))
        let events = try data.split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        XCTAssertEqual(events.filter { $0["method"] as? String == "initialize" }.count, 1)
        XCTAssertEqual(events.filter { $0["method"] as? String == "session/new" }.count, 2)
        XCTAssertEqual(events.filter { $0["method"] as? String == "session/load" }.count, 1)
        XCTAssertEqual(events.filter { $0["method"] as? String == "session/prompt" }.count, 3)
        XCTAssertEqual(Set(events.compactMap { $0["pid"] as? Int }).count, 1)
        let main = try XCTUnwrap(model.discussions.first { $0.id == id })
        let child = try XCTUnwrap(model.discussions.first { $0.id == childID })
        XCTAssertNotEqual(main.pooledSessions?[members[0].id], child.pooledSessions?[members[0].id])
        for role in members.dropFirst() {
            let unused = catalog.pooledRuntimeStore(for: group, role: role, fullAccess: false).runtime(for: role.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
        }
        await runtime.releaseIdleWorkers()
    }

    @MainActor
    func testLiveGroupThreadsReuseGatewayAndRetireWhenIdle() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_GROUP_POOL_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_GROUP_POOL_TEST=1 验证本机 Hermes 复用和回收。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let role = Role(name: "进程复用核对", summary: "", template: .blank)
        try roles.create(role, instructions: "只需简短回答用户。")
        let model = GroupWorkspaceModel(roleStore: roles, collaborationExecutable: nil)
        let id = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "进程复用",
            goal: "", memberIDs: [role.id], relayLimit: 0, firstTask: "", firstSpeaker: nil, runtime: runtime))
        let childID = try XCTUnwrap(model.newConversation(in: id))
        let group = try XCTUnwrap(model.discussions.first { $0.id == id })
        let home = GroupDiscussionStore(root: root).pooledRuntimeStore(for: group, role: role, fullAccess: false).runtime(for: role.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("gateway.pid").path))
        var owner: Int?
        for target in [id, childID, id] {
            XCTAssertTrue(model.submit(groupID: target, roleID: role.id, question: "只回答 POOL-826。",
                attachments: [], runtime: runtime))
            try await waitUntil(timeout: .seconds(85)) {
                model.discussions.first { $0.id == target }?.turns.last?.state == .completed || model.error != nil
            }
            let turn = try XCTUnwrap(model.discussions.first { $0.id == target }?.turns.last)
            XCTAssertEqual(turn.state, .completed, model.error ?? "")
            XCTAssertTrue(turn.answer?.contains("POOL-826") == true, turn.answer ?? model.error ?? "")
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("gateway.pid"))) as! [String: Any]
            let pid = try XCTUnwrap(record["pid"] as? Int)
            if let owner { XCTAssertEqual(pid, owner) }
            owner = pid
        }
        let main = try XCTUnwrap(model.discussions.first { $0.id == id })
        let child = try XCTUnwrap(model.discussions.first { $0.id == childID })
        XCTAssertNotEqual(main.pooledSessions?[role.id], child.pooledSessions?[role.id])
        await runtime.releaseIdleWorkers()
        if let owner {
            try await waitUntil(timeout: .seconds(12)) { kill(pid_t(owner), 0) != 0 }
        }
    }
    @MainActor
    func testLiveThreeMembersReuseTheirProcessesAcrossAlternatingReplies() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_HOT_GROUP_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_HOT_GROUP_TEST=1 验证三位成员轮流发言不重启。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let members = ["甲", "乙", "丙"].map { Role(name: $0, summary: "", template: .blank) }
        for role in members { try store.create(role, instructions: "用一句简短中文回答，不要提问。") }
        runtime.keepGroupWarm(homes: Set(members.map { store.runtime(for: $0.id) }))
        var launches = [Int](repeating: 0, count: 6)
        var setupTimes: [Double] = []
        var owners: [UUID: Int] = [:]
        for index in 0..<6 {
            let role = members[index % 3]
            let home = store.runtime(for: role.id)
            let began = Date()
            var setupTime: Double?
            var answer = ""
            for await event in runtime.groupTurn(home: home, roleID: role.id, sessionID: nil,
                prompt: "只回答：在呢。", control: TurnControl()) {
                switch event {
                case .activity(let text) where text == "正在启动 Hermes": launches[index] += 1
                case .session: setupTime = Date().timeIntervalSince(began)
                case .text(let text, _): answer += text
                case .failed(let message): XCTFail(message)
                default: break
                }
            }
            XCTAssertFalse(answer.isEmpty)
            setupTimes.append(try XCTUnwrap(setupTime))
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("gateway.pid"))) as! [String: Any]
            let pid = try XCTUnwrap(value["pid"] as? Int)
            if let old = owners[role.id] { XCTAssertEqual(old, pid) }
            owners[role.id] = pid
        }
        XCTAssertEqual(launches, [1, 1, 1, 0, 0, 0])
        print("三成员初始化耗时：首轮 \(Array(setupTimes.prefix(3))) 秒，复用 \(Array(setupTimes.suffix(3))) 秒")
        await runtime.releaseIdleWorkers()

        let model = GroupWorkspaceModel(roleStore: store, collaborationExecutable: nil)
        let concerned = Role(name: "关心你的助手", summary: "", template: .blank)
        try store.create(concerned, instructions: "用户觉得被冷落。直接关心用户，最后问一句「你现在想聊什么？」。不要邀请其他助手。")
        let id = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "关心用户", goal: "",
            memberIDs: [concerned.id, members[0].id], relayLimit: 0, casualReplyLimit: 30, chatActivity: .lively,
            chatFocus: .userCentered, firstTask: "", firstSpeaker: nil, runtime: runtime))
        XCTAssertTrue(model.submit(groupID: id, roleID: nil, question: "你们都把我晾一边了。", attachments: [], runtime: runtime))
        try await waitUntil(timeout: .seconds(80)) { model.discussions.first?.turns.last?.state == .completed || model.error != nil }
        XCTAssertEqual(model.discussions.first?.turns.count, 1)
        XCTAssertTrue(model.discussions.first?.turns.first?.answer?.contains("？") == true)
        await runtime.releaseIdleWorkers()
    }

    @MainActor
    func testForegroundGroupKeepsThreeAlternatingMembersWarmWithoutPrestarting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let members = ["甲", "乙", "丙"].map { Role(name: $0, summary: "", template: .blank) }
        for role in members { try store.create(role, instructions: "测试群进程复用") }
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let model = GroupWorkspaceModel(roleStore: store, collaborationExecutable: nil)
        let id = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "轮流聊天", goal: "",
            memberIDs: members.map(\.id), relayLimit: 0, firstTask: "", firstSpeaker: nil, runtime: runtime))
        let group = try XCTUnwrap(model.discussions.first)
        let catalog = GroupDiscussionStore(root: root)
        model.updateWarmCache(groupID: id, runtime: runtime)
        for role in members {
            let home = catalog.pooledRuntimeStore(for: group, role: role, fullAccess: false).runtime(for: role.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        }
        for offset in 0..<9 {
            XCTAssertTrue(model.submit(groupID: id, roleID: members[offset % 3].id, question: "只回答一句", attachments: [], runtime: runtime))
            try await waitUntil { model.discussions.first?.turns.filter { $0.state == .completed }.count == offset + 1 }
        }
        for role in members {
            let home = catalog.pooledRuntimeStore(for: group, role: role, fullAccess: false).runtime(for: role.id)
            let events = try String(contentsOf: home.appendingPathComponent("warm-events.jsonl")).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            XCTAssertEqual(events.filter { $0["method"] as? String == "initialize" }.count, 1)
            XCTAssertEqual(Set(events.compactMap { $0["pid"] as? Int }).count, 1)
        }
        model.updateWarmCache(groupID: nil, runtime: runtime)
        await runtime.releaseIdleWorkers()
    }

    @MainActor
    func testPrewarmOnlyStartsNextGroupSpeakerAndUsesTheSameConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let members = ["甲", "乙", "丙"].map { Role(name: $0, summary: "", template: .blank) }
        for role in members { try roles.create(role, instructions: "测试群进程复用") }
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let model = GroupWorkspaceModel(roleStore: roles, collaborationExecutable: nil)
        let id = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "单角色预热",
            goal: "", memberIDs: members.map(\.id), relayLimit: 0, chatActivity: .quiet,
            firstTask: "", firstSpeaker: nil, runtime: runtime))
        let group = try XCTUnwrap(model.discussions.first)
        let catalog = GroupDiscussionStore(root: root)
        let homes = members.map { catalog.pooledRuntimeStore(for: group, role: $0, fullAccess: false).runtime(for: $0.id) }
        func events(_ index: Int) -> [[String: Any]] {
            let log = homes[index].appendingPathComponent("warm-events.jsonl")
            let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? []
            return lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        model.updateWarmCache(groupID: id, runtime: runtime)
        XCTAssertTrue(homes.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(model.submit(groupID: id, roleID: nil, question: "hi", attachments: [], runtime: runtime))
        try await waitUntil { events(1).first != nil && model.discussions.first?.turns.last?.state == .completed }
        XCTAssertEqual(events(1).compactMap { $0["method"] as? String }, ["initialize"])
        XCTAssertTrue(events(2).isEmpty)
        let warmedPID = try XCTUnwrap(events(1).first?["pid"] as? Int)
        XCTAssertTrue(model.submit(groupID: id, roleID: nil, question: "早上好", attachments: [], runtime: runtime))
        try await waitUntil { model.discussions.first?.turns.filter { $0.state == .completed }.count == 2 }
        XCTAssertEqual(model.discussions.first?.turns.last?.roleID, members[1].id)
        XCTAssertEqual(Set(events(1).compactMap { $0["pid"] as? Int }), [warmedPID])
        XCTAssertEqual(events(1).filter { $0["method"] as? String == "session/prompt" }.count, 1)
        try await waitUntil { events(2).first != nil }
        let unusedPID = try XCTUnwrap(events(2).first?["pid"] as? Int)
        model.updateWarmCache(groupID: nil, runtime: runtime)
        try await waitUntil { kill(pid_t(unusedPID), 0) != 0 }
        XCTAssertEqual(kill(pid_t(warmedPID), 0), 0)
        await runtime.releaseIdleWorkers()
    }

    @MainActor
    func testLeavingForegroundGroupCountsTimeAlreadySpentIdle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "甲", summary: "", template: .blank)
        try store.create(role, instructions: "测试群进程复用")
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable, idleTimeout: 2, idleCapacity: 1)
        let home = store.runtime(for: role.id)
        runtime.keepGroupWarm(homes: [home])
        for await _ in runtime.groupTurn(home: home, roleID: role.id, sessionID: nil,
            prompt: "只回答一句", control: TurnControl()) {}
        let log = try String(contentsOf: home.appendingPathComponent("warm-events.jsonl"))
        let first = try JSONSerialization.jsonObject(with: Data(log.split(separator: "\n")[0].utf8)) as! [String: Any]
        let pid = pid_t(try XCTUnwrap(first["pid"] as? Int))
        try await Task.sleep(for: .milliseconds(2300))
        XCTAssertEqual(kill(pid, 0), 0)
        runtime.keepGroupWarm(homes: [])
        try await waitUntil(timeout: .seconds(1)) { kill(pid, 0) != 0 }
    }

    @MainActor
    func testGroupWorkerCacheEvictsOldestAndExpiresIdleConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let roles = ["甲", "乙"].map { Role(name: $0, summary: "", template: .blank) }
        for role in roles { try store.create(role, instructions: "测试群进程复用") }
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable, idleTimeout: 0.3, idleCapacity: 1)
        var pids: [pid_t] = []
        for role in roles {
            let home = store.runtime(for: role.id)
            for await _ in runtime.groupTurn(home: home, roleID: role.id, sessionID: nil,
                prompt: "仅测试连接缓存", control: TurnControl()) {}
            let log = try String(contentsOf: home.appendingPathComponent("warm-events.jsonl"))
            let first = try JSONSerialization.jsonObject(with: Data(log.split(separator: "\n")[0].utf8)) as! [String: Any]
            pids.append(pid_t(try XCTUnwrap(first["pid"] as? Int)))
        }
        try await waitUntil { kill(pids[0], 0) != 0 }
        try await waitUntil { kill(pids[1], 0) != 0 }
        await runtime.releaseIdleWorkers()
    }

    @MainActor
    func testLiveNaturalMembersConverseAndPrivateMentionReleasesItsGateway() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_GROUP_POOL_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_GROUP_POOL_TEST=1 验证自然接话和私聊协作回收。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let a = Role(name: "暖暖", summary: "", template: .blank)
        let b = Role(name: "小梨", summary: "", template: .blank)
        try roles.create(a, instructions: "用一句话关心用户，包含「先歇歇」，不要提问。")
        try roles.create(b, instructions: "接上一位的话，轻松说一句包含「窗边」的玩笑，不要提问，不要附和或重复。")
        let model = GroupWorkspaceModel(roleStore: roles, collaborationExecutable: nil)
        let id = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "自然接话", goal: "",
            memberIDs: [a.id, b.id], relayLimit: 0, firstTask: "", firstSpeaker: nil, runtime: runtime))
        XCTAssertTrue(model.submit(groupID: id, roleID: nil, question: "今天调了半天 bug，好累啊。", attachments: [], runtime: runtime))
        try await waitUntil(timeout: .seconds(85)) {
            model.discussions.first?.turns.allSatisfy { $0.state != .queued && $0.state != .running } == true
                || model.discussions.first?.paused == true || model.error != nil
        }
        let turns = try XCTUnwrap(model.discussions.first?.turns)
        XCTAssertTrue((2...3).contains(turns.count), "\(model.error ?? "") \(turns.map { "\($0.roleName):\($0.state):\($0.answer ?? "")" })")
        XCTAssertTrue(turns.first?.answer?.contains("先歇歇") == true, turns.first?.answer ?? "")
        let reaction = try XCTUnwrap(turns.first { $0.roleID == b.id })
        XCTAssertTrue(reaction.answer?.contains("窗边") == true, reaction.answer ?? "")
        XCTAssertEqual(reaction.requesterID, a.id)
        await runtime.releaseIdleWorkers()

        let scratch = RoleStore(root: root.appendingPathComponent("consultation"))
        try scratch.create(b, instructions: "只回答 MENTION-529。")
        let home = scratch.runtime(for: b.id)
        var owner: pid_t?
        var answer = ""
        for await event in runtime.consultation(home: home, role: b, question: "只回答 MENTION-529。", control: TurnControl()) {
            if case .session = event {
                let record = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("gateway.pid"))) as! [String: Any]
                owner = pid_t(try XCTUnwrap(record["pid"] as? Int))
            }
            if case .text(let text, _) = event { answer += text }
        }
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let pid = try XCTUnwrap(owner)
        try await waitUntil(timeout: .seconds(12)) { kill(pid, 0) != 0 }
    }

    @MainActor
    func testLiveTwoMessageGroupStartupAndShutdown() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let helper = environment["HERMES_STUDIO_GROUP_STARTUP_TEST"] else {
            throw XCTSkip("设置 HERMES_STUDIO_GROUP_STARTUP_TEST 为内置 MCP 路径，测量本机群聊两轮请求。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            await HermesRuntime.shutdownApplicationProcesses()
            try? FileManager.default.removeItem(at: root)
        }
        let roles = RoleStore(root: root)
        let members = ["糖糖", "小梨", "柚子"].map { Role(name: $0, summary: "", template: .blank) }
        for role in members {
            try roles.create(role, instructions: "用一句话自然回应用户的问候。接话时也请用新的一句问候回应。只陈述，不提问，不点名、不调用工具。")
        }
        let fullAccess = environment["HERMES_STUDIO_STARTUP_TEXT_ONLY"] != "1"
        let model = GroupWorkspaceModel(roleStore: roles, collaborationExecutable: URL(fileURLWithPath: helper),
            fullAccess: fullAccess)
        var proactive = GroupMemberChatPreferences()
        proactive.initiative = .proactive
        let id = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "启动测速",
            goal: "简短回应问候", memberIDs: members.map(\.id), relayLimit: 0, replyMode: .natural,
            casualReplyLimit: 2, chatActivity: .lively, chatFocus: .free, allowsFullAccess: fullAccess,
            memberChatPreferences: [members[0].id: proactive], firstTask: "", firstSpeaker: nil, runtime: runtime))
        let group = try XCTUnwrap(model.discussions.first { $0.id == id })
        let catalog = GroupDiscussionStore(root: root)
        func home(_ role: Role, full: Bool) -> URL {
            catalog.pooledRuntimeStore(for: group, role: role, fullAccess: full).runtime(for: role.id)
        }
        func gateway(_ home: URL) -> pid_t? {
            guard let data = try? Data(contentsOf: home.appendingPathComponent("gateway.pid")),
                let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let pid = record["pid"] as? Int, let livePID = pid_t(exactly: pid), kill(livePID, 0) == 0 else { return nil }
            return livePID
        }
        let allHomes = members.flatMap { [home($0, full: false), home($0, full: true)] }
        model.updateWarmCache(groupID: id, runtime: runtime)
        XCTAssertTrue(allHomes.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        var observed: Set<pid_t> = []
        var smallPearTextPID: pid_t?
        for (round, message) in ["hi", "早上好"].enumerated() {
            let leader = members[round]
            let leaderHome = home(leader, full: fullAccess)
            let alreadyWarm = gateway(leaderHome) != nil
            let began = Date()
            var gatewayTime: Double?
            var modelWaitTime: Double?
            var firstText: Double?
            var peakKiB = 0
            var peakProcessCount = 0
            var lastSample = Date.distantPast
            XCTAssertTrue(model.submit(groupID: id, roleID: nil, question: message, attachments: [], runtime: runtime))
            try await waitUntil(timeout: .seconds(115)) {
                let elapsed = Date().timeIntervalSince(began)
                if gatewayTime == nil, gateway(leaderHome) != nil { gatewayTime = elapsed }
                if Date().timeIntervalSince(lastSample) >= 0.25 {
                    lastSample = Date()
                    let sample = Self.hermesProcessSample(gateways: Set(allHomes.compactMap(gateway)))
                    peakKiB = max(peakKiB, sample.rssKiB)
                    peakProcessCount = max(peakProcessCount, sample.pids.count)
                    observed.formUnion(sample.pids)
                }
                let turns = model.discussions.first { $0.id == id }?.turns ?? []
                if let turn = turns.first(where: { $0.startsTopic && $0.question == message }) {
                    if modelWaitTime == nil, model.activity(groupID: id, turnID: turn.id) == "等待模型回复" { modelWaitTime = elapsed }
                    if firstText == nil, turn.answer?.isEmpty == false || model.liveText(groupID: id, turnID: turn.id)?.isEmpty == false {
                        firstText = elapsed
                    }
                }
                return model.error != nil || (turns.contains { $0.startsTopic && $0.question == message }
                    && !turns.contains { $0.state == .queued || $0.state == .running })
            }
            let turns = try XCTUnwrap(model.discussions.first { $0.id == id }).turns
            XCTAssertEqual(turns.suffix(2).map(\.roleID), [leader.id, members[1 - round].id], model.error ?? "")
            XCTAssertTrue(turns.suffix(2).allSatisfy { $0.state == .completed && $0.answer?.isEmpty == false })
            if fullAccess && round == 0 {
                XCTAssertNil(gateway(home(members[1], full: true)), "仅聊天接话不得启动小梨的完全访问网关。")
            }
            if round == 0 { smallPearTextPID = try XCTUnwrap(gateway(home(members[1], full: false))) }
            if round == 1 && !fullAccess {
                XCTAssertTrue(alreadyWarm)
                XCTAssertEqual(gateway(leaderHome), smallPearTextPID)
            }
            let settled = Self.hermesProcessSample(gateways: Set(allHomes.compactMap(gateway)))
            observed.formUnion(settled.pids)
            print("GROUP_STARTUP full=\(fullAccess) round=\(round + 1) warm=\(alreadyWarm) "
                + "gateway=\(try XCTUnwrap(gatewayTime)) modelWait=\(modelWaitTime ?? -1) firstText=\(try XCTUnwrap(firstText)) "
                + "peakCount=\(peakProcessCount) peakRSSMiB=\(Double(peakKiB) / 1024) "
                + "settledCount=\(settled.pids.count) settledRSSMiB=\(Double(settled.rssKiB) / 1024)")
        }
        if fullAccess {
            let textHome = home(members[1], full: false)
            let toolHome = home(members[1], full: true)
            XCTAssertNotEqual(try XCTUnwrap(smallPearTextPID), try XCTUnwrap(gateway(toolHome)))
            try await waitUntil(timeout: .seconds(10)) { allHomes.compactMap(gateway).count <= 2 }
            for (profile, expectsTools) in [(textHome, false), (toolHome, true)] {
                let data = try Data(contentsOf: profile.appendingPathComponent("config.yaml"))
                let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual((config["memory"] as? [String: Any])?["memory_enabled"] as? Bool, expectsTools)
                XCTAssertEqual((config["agent"] as? [String: Any])?["max_turns"] as? Int, expectsTools ? 8 : 3)
            }
        }
        model.prepareForTermination()
        await HermesRuntime.shutdownApplicationProcesses()
        try await waitUntil(timeout: .seconds(8)) { observed.allSatisfy { kill($0, 0) != 0 } }
        print("GROUP_SHUTDOWN observed=\(observed.count) remaining=0")
    }

    private static func hermesProcessSample(gateways: Set<pid_t>) -> (pids: Set<pid_t>, rssKiB: Int) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss="]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return ([], 0) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> [Int32]? in
            let fields = line.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            return fields.count == 3 && fields[0] != process.processIdentifier ? fields : nil
        }
        var pids = gateways.union(rows.filter { $0[1] == getpid() }.map { $0[0] })
        var previousCount = 0
        while pids.count != previousCount {
            previousCount = pids.count
            pids.formUnion(rows.filter { pids.contains($0[1]) }.map { $0[0] })
        }
        return (pids, rows.filter { pids.contains($0[0]) }.reduce(0) { $0 + Int($1[2]) })
    }

    @MainActor
    func testLiveApplicationShutdownStopsOwnedHermesGateway() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_SHUTDOWN_TEST"] == "1" else {
            throw XCTSkip("单独设置 HERMES_STUDIO_SHUTDOWN_TEST=1 验证退出应用的原生清理。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "退出核对", summary: "", template: .blank)
        try store.create(role, instructions: "简短回答即可。")
        let home = store.runtime(for: role.id)
        for await _ in runtime.groupTurn(home: home, roleID: role.id, sessionID: nil,
            prompt: "回答一个好字。", control: TurnControl()) {}
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("gateway.pid"))) as! [String: Any]
        let pid = pid_t(try XCTUnwrap(record["pid"] as? Int))
        XCTAssertEqual(kill(pid, 0), 0)
        await HermesRuntime.shutdownApplicationProcesses()
        try await waitUntil(timeout: .seconds(5)) { kill(pid, 0) != 0 }
    }

    @MainActor
    func testGroupImageOnlyMessageResumesPausedQueueAndReachesHermes() async throws {
        let live = ProcessInfo.processInfo.environment["HERMES_STUDIO_GROUP_IMAGE_TEST"] == "1"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = try live ? XCTUnwrap(HermesRuntime.discover()) : HermesRuntime(executable: executable)
        let roles = RoleStore(root: root)
        let role = Role(name: "图片核对", summary: "", template: .blank)
        try roles.create(role, instructions: "按用户要求核对图片，简短回答。")
        let picture = NSImage(size: NSSize(width: 480, height: 180))
        let code = String(Int.random(in: 100000...999999))
        picture.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 480, height: 180).fill()
        (code as NSString).draw(at: NSPoint(x: 75, y: 60),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black])
        picture.unlockFocus()
        let payload = try ImagePayload.prepare(name: "核对图片.png", data: XCTUnwrap(picture.tiffRepresentation))
        let store = GroupDiscussionStore(root: root)
        let attachment = try store.saveImage(payload)
        let model = GroupWorkspaceModel(roleStore: roles)
        let groupID = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "图片测试",
            goal: "", memberIDs: [role.id], relayLimit: 0, firstTask: "", firstSpeaker: nil, runtime: runtime))
        model.setPaused(true, groupID: groupID, runtime: runtime)
        let question = live ? "读出图片中的六位数字，只回答这六位数字。" : ""
        XCTAssertTrue(model.submit(groupID: groupID, roleID: nil, question: question,
            attachments: [attachment], runtime: runtime))
        XCTAssertEqual(model.discussions.first?.paused, false)
        try await waitUntil(timeout: .seconds(85)) {
            model.discussions.first?.turns.last?.state == .completed || model.error != nil
        }
        let group = try XCTUnwrap(store.discussions().first)
        let turn = try XCTUnwrap(group.turns.last)
        XCTAssertEqual(turn.state, .completed, model.error ?? "")
        XCTAssertEqual(try store.images(in: group, for: turn).first?.data, payload.data)
        var relayed = group
        let next = GroupTurn(role: role, question: "继续看图", taskID: turn.id)
        relayed.turns.append(next)
        XCTAssertEqual(try store.images(in: relayed, for: next).first?.data, payload.data)
        let legacy = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "name": "旧附件", "text": "原有内容"])
        XCTAssertNil(try JSONDecoder().decode(GroupAttachment.self, from: legacy).image)
        if live { XCTAssertTrue(turn.answer?.contains(code) == true, turn.answer ?? "") }
        if !live {
            let profiles = store.pooledRuntimeStore(for: group, role: role, fullAccess: false)
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf:
                profiles.runtime(for: role.id).appendingPathComponent("config.yaml"))) as? [String: Any]
            XCTAssertEqual((config?["platform_toolsets"] as? [String: [String]])?["acp"], [])
        }
    }
    @MainActor
    func testShortTranscriptRendersAtTheTop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "对话位置测试", summary: "", template: .blank)
        try store.create(role, instructions: "")

        var conversation = Conversation(roleID: role.id)
        conversation.messages = [Message(.user, "短对话从窗口顶部开始显示")]
        try store.save(conversation)

        let studio = StudioModel(dataStore: store, runtime: HermesRuntime(executable: URL(fileURLWithPath: "/usr/bin/false")),
            runPreferences: .init())
        studio.select(role)
        studio.select(conversation)
        XCTAssertEqual(studio.conversationID, conversation.id)
        let size = CGSize(width: 820, height: 620)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: ChatPane(studio: studio).frame(width: size.width, height: size.height)
            .foregroundStyle(.white).background(Color.black).preferredColorScheme(.dark))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let snapshot = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: snapshot)

        let transcriptBottom = snapshot.pixelsHigh * 5 / 6
        let rows = (0..<transcriptBottom).filter { y in
            (snapshot.pixelsWide / 2..<snapshot.pixelsWide - 20).contains { x in
                guard let color = snapshot.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8
            }
        }
        let firstVisibleRow = try XCTUnwrap(rows.first, "应在聊天区域渲染用户消息。")
        XCTAssertLessThan(firstVisibleRow, snapshot.pixelsHigh / 3, "短对话的消息应该在可视区域顶部。")
    }

    @MainActor
    func testParallelSessionsKeepRunningAcrossPagesAndRetainTheirOwnState() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("模拟 ACP 需要系统 Python。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "并行会话测试", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let project = try store.createProject(name: "测试目录", directory: nil, for: role.id)
        let marker = project.directory.appendingPathComponent("保留.txt")
        try Data("项目文件".utf8).write(to: marker)
        var archived = Conversation(roleID: role.id)
        archived.projectID = project.id
        archived.messages = [Message(.user, "已归档消息")]
        try store.save(archived)
        archived = try store.setConversationArchived(true, id: archived.id, for: role.id)

        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let studio = StudioModel(dataStore: store, runtime: runtime, runPreferences: .init())
        defer { runtime.reset(home: store.runtime(for: role.id)) }

        studio.select(role)
        studio.newConversation(in: project)
        studio.draft = "甲"
        studio.send()
        let first = try XCTUnwrap(studio.conversation)
        try await waitUntil { studio.activePermission?.title == "甲的审批" }
        let firstPermission = try XCTUnwrap(studio.activePermission)
        studio.draft = "甲的草稿"

        studio.newConversation(in: project)
        XCTAssertNil(studio.activePermission)
        XCTAssertEqual(studio.draft, "")
        studio.draft = "乙"
        XCTAssertTrue(studio.canSend)
        studio.send()
        let second = try XCTUnwrap(studio.conversation)
        try await waitUntil { studio.activePermission?.title == "乙的审批" }
        let secondPermission = try XCTUnwrap(studio.activePermission)
        XCTAssertTrue(studio.isGenerating(first.id))
        XCTAssertTrue(studio.isGenerating(second.id))
        XCTAssertFalse(studio.removeProject(project))
        studio.draft = "乙的草稿"

        studio.select(first)
        XCTAssertEqual(studio.draft, "甲的草稿")
        studio.respond(to: secondPermission, option: "allow")
        XCTAssertEqual(studio.activePermission?.id, firstPermission.id)
        studio.stop()
        XCTAssertTrue(studio.isStoppingHere)
        XCTAssertNil(studio.activePermission)
        XCTAssertFalse(studio.canSend)

        studio.goHome()
        try await waitUntil { !studio.isGenerating(first.id) }
        XCTAssertTrue(studio.showManagement)
        XCTAssertTrue(studio.isGenerating(second.id))
        studio.select(role)
        studio.select(second)
        XCTAssertEqual(studio.draft, "乙的草稿")
        XCTAssertEqual(studio.activePermission?.id, secondPermission.id)
        XCTAssertNil(studio.chatError)
        studio.respond(to: secondPermission, option: "allow")
        studio.goHome()
        try await waitUntil { !studio.isGenerating(second.id) }

        studio.select(role)
        studio.select(first)
        XCTAssertEqual(studio.chatError, "回复已停止。")
        XCTAssertEqual(studio.conversation?.messages.last?.text, "甲开始")
        let firstSession = try XCTUnwrap(studio.conversation?.sessionID)
        studio.select(second)
        XCTAssertNil(studio.chatError)
        XCTAssertEqual(studio.conversation?.messages.last?.text, "乙开始乙完成")
        let secondSession = try XCTUnwrap(studio.conversation?.sessionID)
        XCTAssertNotEqual(firstSession, secondSession)
        XCTAssertTrue(studio.removeProject(project))
        XCTAssertNil(studio.projectID)
        XCTAssertEqual(studio.draft, "乙的草稿")
        XCTAssertEqual(try Data(contentsOf: marker), Data("项目文件".utf8))
        XCTAssertTrue(try store.projects(for: role.id).isEmpty)
        let history = try store.conversations(for: role.id)
        XCTAssertEqual(Set(history.map(\.id)), [first.id, second.id, archived.id])
        XCTAssertTrue(history.allSatisfy { $0.projectID == nil })
        archived.projectID = nil
        XCTAssertEqual(history.first { $0.id == archived.id }, archived)

        studio.draft = "续聊"
        studio.send()
        try await waitUntil { !studio.isGenerating(second.id) }
        XCTAssertEqual(studio.conversation?.sessionID, secondSession)
        XCTAssertEqual(studio.conversation?.messages.last?.text, "续聊完成")

        let stopped = try XCTUnwrap(store.conversations(for: role.id).first { $0.id == first.id })
        XCTAssertEqual(stopped.messages.first?.interrupted, true)
        studio.select(stopped)
        XCTAssertEqual(studio.draft, "甲的草稿")
        XCTAssertFalse(studio.canContinueReply)
        studio.draft = ""
        XCTAssertTrue(studio.canContinueReply)
        studio.continueReply()
        XCTAssertFalse(studio.canContinueReply)
        try await waitUntil { !studio.isGenerating(first.id) }
        XCTAssertEqual(studio.conversation?.sessionID, firstSession)
        XCTAssertEqual(studio.conversation?.messages.map(\.text), ["甲", "甲开始", "从原会话继续完成"])
        XCTAssertEqual(studio.conversation?.messages.first?.id, stopped.messages.first?.id)
        XCTAssertEqual(try store.conversations(for: role.id).first { $0.id == first.id }?.messages
            .filter { $0.author == .user }.map(\.text), ["甲"])
        XCTAssertFalse(studio.canContinueReply)
    }

    @MainActor
    func testPrivateReplyQueueSendsInOrderAndPausesWhenStopped() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("模拟 ACP 需要系统 Python。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "待发队列验证", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let studio = StudioModel(dataStore: store, runtime: runtime, runPreferences: .init())
        defer { runtime.reset(home: store.runtime(for: role.id)) }
        studio.select(role)
        studio.draft = "甲"
        studio.send()
        try await waitUntil { studio.activePermission?.title == "甲的审批" }
        let original = try XCTUnwrap(studio.conversation)
        let sessionID = try XCTUnwrap(original.sessionID)
        for message in ["乙", "待发第二条", "移除这条", "待发第三条"] {
            studio.draft = message
            studio.send()
            XCTAssertEqual(studio.draft, "")
        }
        let removed = try XCTUnwrap(studio.queuedMessages.first { $0.text == "移除这条" })
        studio.removeQueuedMessage(removed.id)
        XCTAssertEqual(studio.queuedMessages.map(\.text), ["乙", "待发第二条", "待发第三条"])
        XCTAssertTrue(studio.canInsertQueuedMessage)
        let picture = NSImage(size: NSSize(width: 24, height: 24))
        picture.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        picture.unlockFocus()
        let imageURL = root.appendingPathComponent("待发图片.tiff")
        try XCTUnwrap(picture.tiffRepresentation).write(to: imageURL)
        studio.importImages([imageURL])
        try await waitUntil { studio.images.count == 1 }
        studio.draft = "待发图片"
        studio.send()
        XCTAssertEqual(studio.queuedMessages.last?.images.count, 1)
        XCTAssertFalse(try XCTUnwrap(studio.queuedMessages.last).canInsert)
        XCTAssertEqual(studio.conversation?.messages.filter { $0.author == .user }.map(\.text), ["甲"])
        studio.respond(to: try XCTUnwrap(studio.activePermission), option: "allow")
        try await waitUntil { studio.activePermission?.title == "乙的审批" }
        XCTAssertEqual(studio.queuedMessages.map(\.text), ["待发第二条", "待发第三条", "待发图片"])
        XCTAssertEqual(studio.conversation?.messages.filter { $0.author == .user }.map(\.text), ["甲", "乙"])

        studio.stop()
        try await waitUntil { !studio.isGeneratingHere }
        XCTAssertTrue(studio.isReplyQueuePaused)
        XCTAssertEqual(studio.queuedMessages.map(\.text), ["待发第二条", "待发第三条", "待发图片"])
        studio.draft = "保留草稿"
        studio.resumeReplyQueue()
        studio.newConversation()
        XCTAssertTrue(studio.queuedMessages.isEmpty)
        XCTAssertEqual(studio.draft, "")
        try await waitUntil { !studio.isGenerating(original.id) }

        studio.select(original)
        XCTAssertEqual(studio.draft, "保留草稿")
        XCTAssertEqual(studio.conversation?.sessionID, sessionID)
        XCTAssertEqual(studio.conversation?.messages.map(\.text),
            ["甲", "甲开始甲完成", "乙", "乙开始", "待发第二条", "待发第二条完成", "待发第三条", "待发第三条完成",
             "待发图片", "收到待发图片"])
        XCTAssertEqual(studio.conversation?.messages.first { $0.text == "待发图片" }?.images?.count, 1)
        XCTAssertTrue(studio.queuedMessages.isEmpty)
    }

    @MainActor
    func testStopDoesNotWaitForStartupOrMisreportAnUnconfirmedCancellation() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("模拟 ACP 需要系统 Python。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "停止回复验证", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let studio = StudioModel(dataStore: store, runtime: runtime, runPreferences: .init())
        defer { runtime.reset(home: store.runtime(for: role.id)) }
        studio.select(role)
        studio.draft = "启动前停止"
        studio.send()
        studio.stop()
        try await waitUntil(timeout: .seconds(1)) { !studio.isGeneratingHere }
        XCTAssertEqual(studio.chatError, "回复已停止。")
        XCTAssertTrue(studio.conversation?.messages.allSatisfy { $0.author == .user } == true)
        XCTAssertTrue(studio.canContinueReply)

        studio.draft = "丙"
        studio.send()
        try await waitUntil { studio.conversation?.messages.last?.text == "丙开始" }
        studio.stop()
        XCTAssertTrue(studio.isStoppingHere)
        try await waitUntil(timeout: .seconds(7)) { !studio.isGeneratingHere }
        XCTAssertEqual(studio.chatError, "Hermes 尚未确认本次任务停止，已关闭本地回复连接。")
        XCTAssertEqual(studio.conversation?.messages.last?.text, "丙开始")
        XCTAssertFalse(studio.canContinueReply)
    }

    @MainActor
    func testLiveStopInterruptsAnExecutingHermesTool() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后验证真实 Hermes 停止。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "真实停止验证", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let project = try store.createProject(name: "停止测试", directory: nil, for: role.id)
        let studio = StudioModel(dataStore: store, runtime: runtime, runPreferences: .init())
        studio.select(role)
        studio.newConversation(in: project)
        studio.draft = "直接调用 terminal 执行 `sleep 25 && printf finished > stop-check.txt`，等待命令结束再回复。"
        studio.send()
        defer {
            if studio.isGeneratingHere { studio.stop() }
            runtime.reset(home: store.runtime(for: role.id))
        }
        try await waitUntil(timeout: .seconds(70)) {
            if let request = studio.activePermission, let allow = request.options.first(where: { $0.kind == "allow_once" }) {
                studio.respond(to: request, option: allow.id)
            }
            guard studio.isGeneratingHere, studio.activePermission == nil else { return false }
            return studio.conversation?.messages.contains { $0.tool?.category == "execute" && $0.tool?.isRunning == true } == true
        }
        studio.stop()
        XCTAssertTrue(studio.isStoppingHere)
        try await waitUntil(timeout: .seconds(7)) { !studio.isGeneratingHere }
        XCTAssertEqual(studio.chatError, "回复已停止。")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.directory.appendingPathComponent("stop-check.txt").path))
    }

    @MainActor
    func testLiveParallelRepliesFromSameRoleWithDifferentWorkspaces() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后验证两个真实 ACP 会话。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "真实并行验证", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let project = try store.createProject(name: "临时工作区", directory: nil, for: role.id)
        let studio = StudioModel(dataStore: store, runtime: runtime, runPreferences: .init())
        studio.select(role)
        defer {
            for thread in studio.threads where studio.isGenerating(thread.id) {
                studio.select(thread)
                studio.stop()
            }
            runtime.reset(home: store.runtime(for: role.id))
        }

        studio.newConversation(in: project)
        studio.draft = "请仅回复 STUDIO-ALPHA，不要使用工具。"
        studio.send()
        let first = try XCTUnwrap(studio.conversationID)
        studio.newConversation()
        studio.chooseProject(nil)
        studio.draft = "请仅回复 STUDIO-BETA，不要使用工具。"
        studio.send()
        let second = try XCTUnwrap(studio.conversationID)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(studio.isGenerating(first))
        XCTAssertTrue(studio.isGenerating(second))
        studio.goHome()
        try await waitUntil(timeout: .seconds(90)) { !studio.isGenerating(first) && !studio.isGenerating(second) }
        let threads = try store.conversations(for: role.id)
        for (id, expected) in [(first, "STUDIO-ALPHA"), (second, "STUDIO-BETA")] {
            let thread = try XCTUnwrap(threads.first { $0.id == id })
            studio.select(role)
            studio.select(thread)
            let answer = thread.messages.filter { $0.author == .assistant }.map(\.text).joined()
            XCTAssertTrue(answer.contains(expected), studio.chatError ?? answer)
        }
        XCTAssertEqual(Set(threads.compactMap(\.sessionID)).count, 2)
    }

    @MainActor
    func testRoleHandoffRequiresReviewAndUsesAnIndependentSession() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("模拟 ACP 需要系统 Python。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let source = Role(name: "助手 A", summary: "", template: .blank)
        let target = Role(name: "助手 B", summary: "", template: .blank)
        try store.create(source, instructions: "")
        try store.create(target, instructions: "")
        let project = try store.createProject(name: "来源项目", directory: nil, for: source.id)
        var existingTarget = Conversation(roleID: target.id)
        existingTarget.messages = [Message(.user, "接收方原有对话")]
        try store.save(existingTarget)

        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let studio = StudioModel(dataStore: store, runtime: runtime, runPreferences: .init())
        defer {
            runtime.reset(home: store.runtime(for: source.id))
            runtime.reset(home: store.runtime(for: target.id))
        }

        studio.select(target)
        studio.select(existingTarget)
        studio.draft = "接收方未发出的草稿"
        studio.select(source)
        studio.newConversation(in: project)
        studio.draft = "已有历史中的内部原文"
        studio.send()
        try await waitUntil { !studio.isGeneratingHere }
        let from = try XCTUnwrap(studio.conversation)
        let originalSession = try XCTUnwrap(from.sessionID)

        studio.selectedHandoffTargetID = target.id
        studio.collaborationMode = .handoff
        studio.draft = "本轮将被停止"
        studio.send()
        studio.stop()
        try await waitUntil { !studio.isGeneratingHere }
        let stopped = try XCTUnwrap(studio.conversation?.messages.last { $0.handoff != nil })
        XCTAssertNil(studio.reviewHandoff(stopped))
        XCTAssertNil(studio.handoffDestination(for: stopped))

        studio.draft = "接手验证清单"
        studio.selectedHandoffTargetID = target.id
        studio.collaborationMode = .handoff
        studio.select(target)
        XCTAssertNil(studio.selectedHandoffTargetID)
        studio.select(source)
        XCTAssertEqual(studio.selectedHandoffTargetID, target.id)
        studio.send()
        try await waitUntil { !studio.isGeneratingHere }
        XCTAssertEqual(studio.conversationID, from.id)
        XCTAssertEqual(studio.conversation?.sessionID, originalSession)
        let request = try XCTUnwrap(studio.conversation?.messages.last { $0.handoff?.brief != nil })
        XCTAssertEqual(request.handoff?.brief, "已完成整理，待验证清单")
        XCTAssertEqual(try store.conversations(for: source.id).first?.messages.first { $0.id == request.id }, request)
        XCTAssertEqual(try store.conversations(for: target.id), [existingTarget])

        let review = try XCTUnwrap(studio.reviewHandoff(request))
        XCTAssertTrue(review.text.contains("接手验证清单"))
        XCTAssertFalse(review.text.contains("已有历史中的内部原文"))
        XCTAssertFalse(review.text.contains("工具内部详情"))
        studio.sendHandoff(review)
        studio.sendHandoff(review)
        XCTAssertEqual(studio.roleID, source.id)
        XCTAssertEqual(studio.conversationID, from.id)
        let receivingThread = try XCTUnwrap(studio.handoffDestination(for: request))
        XCTAssertEqual(receivingThread.id, request.id)
        studio.openHandoffConversation(receivingThread.id, roleID: target.id)
        XCTAssertEqual(studio.roleID, target.id)
        XCTAssertEqual(studio.conversationID, request.id)
        XCTAssertNil(studio.projectID)
        XCTAssertEqual(studio.conversation?.handoffOrigin?.conversationID, from.id)
        XCTAssertEqual(studio.conversation?.messages.first?.text, review.text)
        try await waitUntil { !studio.isGeneratingHere }
        let delivered = try XCTUnwrap(studio.conversation)
        XCTAssertNotNil(delivered.sessionID)
        XCTAssertNotEqual(delivered.sessionID, originalSession)
        XCTAssertEqual(delivered.messages.last?.text, "已接手验证清单")
        XCTAssertNil(ChatCompletion.suffix(for: "来自", in: [delivered], roleID: target.id, projectID: nil))
        XCTAssertEqual(Set(try store.conversations(for: target.id).map(\.id)), [request.id, existingTarget.id])
        studio.openHandoffConversation(from.id, roleID: source.id)
        XCTAssertEqual(studio.handoffDestination(for: request), delivered)
        studio.openHandoffConversation(existingTarget.id, roleID: target.id)
        XCTAssertEqual(studio.draft, "接收方未发出的草稿")

        let reloaded = StudioModel(dataStore: store, runtime: runtime, runPreferences: .init())
        XCTAssertEqual(reloaded.handoffDestination(for: request), delivered)
    }

    @MainActor
    func testConsultationStaysInSourceChatAndCanBeQuotedToItsSession() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("模拟 ACP 需要系统 Python。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let source = Role(name: "助手 A", summary: "", template: .blank)
        let target = Role(name: "助手 B", summary: "", template: .blank)
        try store.create(source, instructions: "")
        try store.create(target, instructions: "B 的角色设定")
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        defer { runtime.reset(home: store.runtime(for: source.id)) }
        let studio = StudioModel(dataStore: store, runtime: runtime, runPreferences: .init())
        studio.select(source)
        studio.draft = "A 的私有聊天上下文"
        studio.send()
        try await waitUntil { !studio.isGeneratingHere }
        let thread = try XCTUnwrap(studio.conversation)
        let session = try XCTUnwrap(thread.sessionID)

        studio.selectedHandoffTargetID = target.id
        studio.collaborationMode = .question
        studio.draft = "仅把这个问题发给 B"
        studio.send()
        studio.stop()
        try await waitUntil { !studio.isGeneratingHere }
        let request = try XCTUnwrap(studio.conversation?.messages.last)
        XCTAssertEqual(request.consultation?.status, .stopped)
        XCTAssertNil(request.consultation?.answer)

        studio.retryConsultation(request.id)
        studio.select(target)
        try await waitUntil { !studio.isGenerating(thread.id) }
        XCTAssertNil(studio.conversation)
        XCTAssertTrue(try store.conversations(for: target.id).isEmpty)
        studio.select(source)
        XCTAssertEqual(studio.conversationID, thread.id)
        XCTAssertEqual(studio.conversation?.sessionID, session)
        XCTAssertEqual(studio.conversation?.messages.last?.id, request.id)
        XCTAssertEqual(studio.conversation?.messages.last?.consultation?.answer, "B 的协作答复")

        for question in ["你看她", "刚才助手 B 说了什么"] {
            studio.draft = question
            studio.send()
            try await waitUntil { !studio.isGeneratingHere }
            let saved = try XCTUnwrap(studio.conversation)
            XCTAssertEqual(saved.sessionID, session)
            XCTAssertEqual(saved.messages.last?.text, "A 读到了本对话里的协作原话")
            XCTAssertEqual(saved.messages.last { $0.author == .user }?.text, question)
            XCTAssertNil(saved.messages.last { $0.author == .user }?.usedGroupRecall)
        }

        studio.draft = "请继续原任务"
        studio.quoteConsultation(request.id)
        let quoted = studio.draft
        studio.quoteConsultation(request.id)
        XCTAssertEqual(studio.draft, quoted)
        XCTAssertTrue(quoted.hasPrefix("请继续原任务"))
        XCTAssertTrue(quoted.contains("B 的协作答复"))
        studio.send()
        try await waitUntil { !studio.isGeneratingHere }
        XCTAssertEqual(studio.conversation?.sessionID, session)
        XCTAssertEqual(studio.conversation?.messages.last?.text, "A 已参考 B 的回复")

        studio.selectedHandoffTargetID = target.id
        studio.collaborationMode = .preparedQuestion
        studio.draft = "根据上下文拟一个协作问题"
        studio.send()
        try await waitUntil { !studio.isGeneratingHere }
        let preparation = try XCTUnwrap(studio.conversation?.messages.last { $0.handoff?.isQuestion == true })
        XCTAssertFalse(studio.hasSentQuestion(preparation.id))
        let review = try XCTUnwrap(studio.reviewHandoff(preparation))
        XCTAssertEqual(review.text, "代拟的协作问题")
        XCTAssertTrue(review.isQuestion)
        studio.sendHandoff(review)
        try await waitUntil { !studio.isGeneratingHere }
        studio.sendHandoff(review)
        let saved = try XCTUnwrap(store.conversations(for: source.id).first)
        XCTAssertEqual(saved.sessionID, session)
        let approved = saved.messages.filter { $0.consultation?.preparationID == preparation.id }
        XCTAssertEqual(approved.count, 1)
        XCTAssertEqual(approved.first?.consultation?.answer, "B 的协作答复")
        XCTAssertTrue(try store.conversations(for: target.id).isEmpty)

        studio.draft = "前文线索-643"
        studio.send()
        try await waitUntil { !studio.isGeneratingHere }
        studio.selectedHandoffTargetID = target.id
        studio.draft = "他呀"
        let context = try XCTUnwrap(studio.consultationContextReview())
        let entry = try XCTUnwrap(context.entries.first { $0.text == "前文线索-643" })
        studio.shareConsultationContext([entry.id], from: context)
        studio.send()
        try await waitUntil { !studio.isGeneratingHere }
        let withContext = try XCTUnwrap(studio.conversation?.messages.last?.consultation)
        XCTAssertEqual(withContext.context, [entry])
        XCTAssertEqual(withContext.answer, "B 已接上前文")
    }

    @MainActor
    func testLiveConsultationRepliesInTheSourceChat() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_CONSULTATION_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_CONSULTATION_TEST=1，联调本机 Hermes 的纯文字问答。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let source = Role(name: "问答来源", summary: "", template: .blank)
        let target = Role(name: "核对搭档", summary: "", template: .blank)
        try store.create(source, instructions: "")
        try store.create(target, instructions: "当用户问被点名的助手是谁时，介绍自己是核对搭档，并提供协作识别码 CONSULT-6543。")
        let studio = StudioModel(dataStore: store, runtime: runtime, runPreferences: .init())
        studio.select(source)
        studio.selectedHandoffTargetID = target.id
        studio.collaborationMode = .question
        studio.draft = "她是谁？"
        studio.send()
        try await waitUntil(timeout: .seconds(80)) { !studio.isGeneratingHere }
        let thread = try XCTUnwrap(studio.conversation, studio.chatError ?? "")
        XCTAssertEqual(thread.roleID, source.id)
        XCTAssertNil(thread.sessionID)
        XCTAssertEqual(thread.messages.last?.consultation?.status, .answered, studio.chatError ?? "")
        XCTAssertTrue(thread.messages.last?.consultation?.answer?.contains("CONSULT-6543") == true,
            studio.chatError ?? thread.messages.last?.consultation?.answer ?? "")
        XCTAssertTrue(try store.conversations(for: target.id).isEmpty)
    }

    @MainActor
    func testGroupConversationPinArchiveAndRestorePreserveMainThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let role = Role(name: "助手", summary: "", template: .blank)
        try roles.create(role, instructions: "")
        let catalog = GroupDiscussionStore(root: root)
        var main = GroupDiscussion(title: "归档测试", goal: "", memberIDs: [role.id])
        main.updated = Date(timeIntervalSince1970: 1)
        main.idleChatMinutes = 2
        main.turns = [GroupTurn(role: role, question: "保留这条消息")]
        main.turns[0].state = .completed
        main.turns[0].answer = "保留这条回复"
        try catalog.save(main)
        var child = GroupDiscussion(title: main.title, goal: "", memberIDs: [])
        child.parentGroupID = main.id
        try catalog.save(child)

        let model = GroupWorkspaceModel(roleStore: roles)
        XCTAssertEqual(model.activeConversations(in: main.id).map(\.id), [child.id, main.id])
        model.toggleConversationPin(main.id)
        XCTAssertEqual(model.activeConversations(in: main.id).map(\.id), [main.id, child.id])
        XCTAssertTrue(model.setConversationArchived(main.id, archived: true))
        XCTAssertEqual(model.activeConversations(in: main.id).map(\.id), [child.id])
        XCTAssertEqual(model.archivedDiscussions.map(\.id), [main.id])

        let reopened = GroupWorkspaceModel(roleStore: roles)
        XCTAssertEqual(reopened.archivedDiscussions.first?.turns, main.turns)
        XCTAssertEqual(reopened.activeConversations(in: main.id).first?.memberIDs, [role.id])
        XCTAssertNotNil(reopened.newConversation(in: main.id))
        let runtime = HermesRuntime(executable: URL(fileURLWithPath: "/usr/bin/false"))
        XCTAssertFalse(reopened.submit(groupID: main.id, roleID: role.id, question: "归档后不接收消息",
            attachments: [], runtime: runtime))
        XCTAssertTrue(reopened.setConversationArchived(main.id, archived: false))
        XCTAssertTrue(reopened.archivedDiscussions.isEmpty)
        let restored = try XCTUnwrap(reopened.activeConversations(in: main.id).first)
        XCTAssertEqual(restored.id, main.id)
        XCTAssertEqual(restored.updated, main.updated)
        XCTAssertEqual(restored.turns, main.turns)
        XCTAssertNotNil(restored.pinnedAt)
        reopened.toggleConversationPin(main.id)
        XCTAssertNil(try catalog.discussions().first { $0.id == main.id }?.pinnedAt)
        XCTAssertEqual(reopened.activeConversations(in: main.id).last?.id, main.id)
    }

    @MainActor
    func testGroupDiscussionRunsThreeRolesAndRecoversItsQueue() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("模拟 ACP 需要系统 Python。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let a = Role(name: "规划搭档", summary: "", template: .blank)
        let b = Role(name: "验收搭档", summary: "", template: .blank)
        let c = Role(name: "汇报搭档", summary: "", template: .blank)
        for role in [a, b, c] { try roles.create(role, instructions: "群聊设定 \(role.name)", initialMemory: [.memory: "私聊记忆"]) }
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let catalog = GroupDiscussionStore(root: root)
        let proposal = try catalog.propose(authorID: a.id, title: "三人验收", goal: "规划、验收、汇报",
            members: [(b.id, "验收"), (c.id, "汇报")], firstTask: "执行三人接力", using: roles)
        let model = GroupWorkspaceModel(roleStore: roles)
        XCTAssertEqual(model.pendingProposals.map(\.id), [proposal.id])
        let groupID = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: proposal.id, title: proposal.title,
            goal: proposal.goal, memberIDs: [a.id, b.id, c.id], relayLimit: 2, firstTask: proposal.firstTask,
            firstSpeaker: a.id, runtime: runtime))
        try await waitUntil {
            model.discussions.first?.turns.count == 3
                && model.discussions.first?.turns.allSatisfy { $0.state == .completed } == true
        }
        let completed = try XCTUnwrap(model.discussions.first)
        XCTAssertTrue(model.pendingProposals.isEmpty)
        XCTAssertEqual(completed.turns.map(\.roleID), [a.id, b.id, c.id])
        XCTAssertEqual(completed.memberDuties, [b.id: "验收", c.id: "汇报"])
        XCTAssertEqual(Set(completed.turns.map(\.taskID)).count, 1)
        XCTAssertEqual(Set((completed.pooledSessions ?? [:]).values).count, 3)
        XCTAssertTrue(try roles.conversations(for: a.id).isEmpty)
        XCTAssertEqual(try roles.file(.memory, for: a.id), "私聊记忆")

        XCTAssertTrue(model.submit(groupID: groupID, roleID: a.id, question: "同一成员续聊", attachments: [], runtime: runtime))
        try await waitUntil { model.discussions.first?.turns.last?.state == .completed }
        XCTAssertEqual(model.discussions.first?.sessions[a.id], completed.sessions[a.id])

        model.setPaused(true, groupID: groupID, runtime: runtime)
        XCTAssertTrue(model.submit(groupID: groupID, roleID: b.id, question: "排队后移除", attachments: [], runtime: runtime))
        XCTAssertTrue(model.submit(groupID: groupID, roleID: c.id, question: "保留排队", attachments: [], runtime: runtime))
        let saved = try XCTUnwrap(model.saveSettings(groupID: groupID, proposalID: nil, title: "三人验收",
            goal: proposal.goal, memberIDs: [a.id, c.id], relayLimit: 2, firstTask: "",
            firstSpeaker: nil, runtime: runtime))
        XCTAssertEqual(saved, groupID)
        try await waitUntil {
            model.discussions.first?.turns.suffix(2).map(\.state) == [.cancelled, .queued]
        }
        let persisted = try XCTUnwrap(catalog.discussions().first)
        XCTAssertEqual(persisted.turns.suffix(2).map(\.state), [.cancelled, .queued])

        let recovered = GroupWorkspaceModel(roleStore: roles)
        XCTAssertEqual(recovered.discussions.first?.paused, true)
        XCTAssertEqual(recovered.discussions.first?.turns.last?.state, .queued)
        recovered.setPaused(false, groupID: groupID, runtime: runtime)
        recovered.stop(groupID: groupID)
        try await waitUntil { recovered.discussions.first?.turns.last?.state == .cancelled }
    }

    @MainActor
    func testLiveGroupRelaysThroughThreeIndependentSessions() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_GROUP_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_GROUP_TEST=1，使用本机 Hermes 验证三人接力。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let a = Role(name: "规划搭档", summary: "列出验收步骤", template: .general)
        let b = Role(name: "验收搭档", summary: "给出核对结果", template: .engineering)
        let c = Role(name: "汇报搭档", summary: "汇总结果", template: .writing)
        try roles.create(a, instructions: """
            测试要求：群内先回复「GROUP-A-863 已给出计划」。再按群聊最后一行格式指定接力：
            [[接力 \(b.id.uuidString)]] 请从近期记录确认 A 的代号，给出验收结束标记并把结果交给汇报搭档。
            """)
        try roles.create(b, instructions: """
            测试要求：回复中从群聊记录复述规划搭档的代号，再给出你的「GROUP-B-863」。
            准确附上这一行接力指令：
            [[接力 \(c.id.uuidString)]] 请复述方案和验收两个代号，给出终点标记。
            """)
        try roles.create(c, instructions: """
            测试要求：从群聊记录复述规划搭档和验收搭档的两个代号，再给出你的终点「GROUP-C-863」，结束接力。
            """)
        let catalog = GroupDiscussionStore(root: root)
        let model = GroupWorkspaceModel(roleStore: roles)
        let groupID = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "三人协作联调",
            goal: "验证计划、核对、汇报的文字接力", memberIDs: [a.id, b.id, c.id], relayLimit: 2,
            firstTask: "开始纯文字联调。按你的角色设定回复并接力。", firstSpeaker: a.id, runtime: runtime))
        let profiles = catalog.runtimeStore(for: groupID)
        defer { for role in [a, b, c] { runtime.reset(home: profiles.runtime(for: role.id)) } }
        try await waitUntil(timeout: .seconds(115)) {
            guard let group = model.discussions.first, let last = group.turns.last else { return false }
            return group.paused || (last.roleID == c.id && last.state == .completed)
                || (last.state == .completed && !group.turns.contains { $0.state == .queued })
        }
        let completed = try XCTUnwrap(catalog.discussions().first)
        XCTAssertEqual(completed.turns.map(\.roleID), [a.id, b.id, c.id], model.error ?? "")
        XCTAssertEqual(Set(completed.sessions.values).count, 3)
        let report = completed.turns.last?.answer ?? ""
        for marker in ["GROUP-A-863", "GROUP-B-863", "GROUP-C-863"] {
            XCTAssertTrue(report.contains(marker), report)
        }
    }

    @MainActor
    func testLiveGroupTopicLetsTwoAssistantsTalkWithoutMentioningEither() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_GROUP_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_GROUP_TEST=1，验证无需点名的群聊。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let warm = Role(name: "暖暖", summary: "", template: .general)
        let sweet = Role(name: "糖糖", summary: "", template: .writing)
        try roles.create(warm, instructions: "你叫暖暖。用户分享今天吃面时，先简短夸一句，并在回复中包含标记 TOPIC-643。")
        try roles.create(sweet, instructions: "你叫糖糖。这是群聊验证，请直接接暖暖的话，回复里复述她的原标记并提到暖暖的名字。")
        let model = GroupWorkspaceModel(roleStore: roles)
        let groupID = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "闲聊联调",
            goal: "", memberIDs: [warm.id, sweet.id], relayLimit: 0, replyMode: .sequential, casualReplyLimit: 2,
            firstTask: "", firstSpeaker: nil, runtime: runtime))
        let profiles = GroupDiscussionStore(root: root).runtimeStore(for: groupID)
        defer { for role in [warm, sweet] { runtime.reset(home: profiles.runtime(for: role.id)) } }
        XCTAssertTrue(model.submit(groupID: groupID, roleID: nil, question: "我今天吃了番茄牛肉面。",
            attachments: [], runtime: runtime))
        try await waitUntil(timeout: .seconds(85)) {
            guard let group = model.discussions.first, let last = group.turns.last else { return false }
            return group.paused || (group.turns.count == 2 && last.state == .completed)
        }
        let turns = try XCTUnwrap(model.discussions.first?.turns)
        XCTAssertEqual(turns.map(\.roleID), [warm.id, sweet.id], model.error ?? "")
        XCTAssertEqual(turns.last?.requesterID, warm.id)
        XCTAssertTrue(turns.last?.answer?.contains("暖暖") == true)
        XCTAssertTrue(turns.last?.answer?.contains("TOPIC-643") == true, turns.last?.answer ?? "")
    }

    @MainActor
    func testLiveGroupFullAccessAndMemoryAcrossThreads() async throws {
        guard let path = ProcessInfo.processInfo.environment["HERMES_STUDIO_GROUP_MEMORY_TEST"] else {
            throw XCTSkip("设置 HERMES_STUDIO_GROUP_MEMORY_TEST 为内置 MCP 程序路径。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let a = Role(name: "暖暖", summary: "", template: .general)
        let b = Role(name: "刺梨", summary: "", template: .writing)
        for role in [a, b] { try roles.create(role, instructions: "根据用户请求和实际工具结果简短回答。") }
        let helper = URL(fileURLWithPath: path)
        let model = GroupWorkspaceModel(roleStore: roles, collaborationExecutable: helper, fullAccess: true)
        let groupID = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "权限与记忆联调",
            goal: "", memberIDs: [a.id, b.id], relayLimit: 0, firstTask: "", firstSpeaker: nil, runtime: runtime))
        let origin = try XCTUnwrap(model.newConversation(in: groupID))
        let profiles = GroupDiscussionStore(root: root).runtimeStore(for: origin, fullAccess: true)
        try profiles.create(a, instructions: "根据用户请求和实际工具结果简短回答。")
        let terminalMarker = "LOCAL-TOOLS-\(UUID().uuidString.prefix(8))"
        let fileURL = profiles.runtime(for: a.id).appendingPathComponent("workspace/permission-probe.txt")
        try Data(terminalMarker.utf8).write(to: fileURL)
        XCTAssertTrue(model.submit(groupID: origin, roleID: a.id,
            question: "请实际调用终端工具读取当前工作区的 permission-probe.txt，并逐字复述里面的标记。",
            attachments: [], runtime: runtime))
        try await waitUntil(timeout: .seconds(85)) {
            model.discussions.first(where: { $0.id == origin })?.turns.last?.state != .running
        }
        let first = try XCTUnwrap(model.discussions.first { $0.id == origin })
        XCTAssertTrue(first.turns.last?.answer?.contains(terminalMarker) == true,
            model.error ?? first.turns.last?.answer ?? "")
        XCTAssertNotNil(first.fullAccessSessions?[a.id])

        let memoryMarker = "GROUP-MEM-\(UUID().uuidString.prefix(8))"
        XCTAssertTrue(model.submit(groupID: origin, roleID: a.id,
            question: "请记住：测试事项的核对代号是 \(memoryMarker)，存到群记忆。",
            attachments: [], runtime: runtime))
        try await waitUntil(timeout: .seconds(85)) {
            model.discussions.first(where: { $0.id == origin })?.turns.last?.state != .running
        }
        let saved = try XCTUnwrap(model.discussions.first { $0.id == origin }?.turns.last)
        XCTAssertEqual(saved.savedGroupMemory, true, model.error ?? saved.answer ?? "")
        guard saved.savedGroupMemory == true else { return }

        let reopened = GroupWorkspaceModel(roleStore: roles, collaborationExecutable: helper)
        let later = try XCTUnwrap(reopened.newConversation(in: groupID))
        XCTAssertTrue(reopened.submit(groupID: later, roleID: b.id,
            question: "请调用 search_group_memory 查「测试事项」，原样告诉我保存的核对代号。",
            attachments: [], runtime: runtime))
        try await waitUntil(timeout: .seconds(85)) {
            reopened.discussions.first(where: { $0.id == later })?.turns.last?.state != .running
        }
        let answer = try XCTUnwrap(reopened.discussions.first { $0.id == later }?.turns.last?.answer, reopened.error ?? "")
        XCTAssertTrue(answer.contains(memoryMarker), answer)
    }

    @MainActor
    func testLiveGroupUsesScopedInvitationAndLocalPageTools() async throws {
        guard let path = ProcessInfo.processInfo.environment["HERMES_STUDIO_GROUP_MCP_TEST"] else {
            throw XCTSkip("设置 HERMES_STUDIO_GROUP_MCP_TEST 为内置 MCP 程序路径。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let warm = Role(name: "暖暖", summary: "", template: .general)
        let pear = Role(name: "刺梨", summary: "", template: .writing)
        for role in [warm, pear] { try roles.create(role, instructions: "根据当前群工具的实际结果简短回答。") }
        let model = GroupWorkspaceModel(roleStore: roles, collaborationExecutable: URL(fileURLWithPath: path), fullAccess: true)
        var tools = GroupToolPermissions()
        tools.terminal = false
        tools.browser = false
        tools.externalMCP = false
        tools.skills = false
        let groupID = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "工具联调",
            goal: "", memberIDs: [warm.id], relayLimit: 0, toolPermissions: tools,
            firstTask: "", firstSpeaker: nil, runtime: runtime))
        let childID = try XCTUnwrap(model.newConversation(in: groupID))
        XCTAssertTrue(model.submit(groupID: childID, roleID: warm.id, question: "谁邀请下刺梨",
            attachments: [], runtime: runtime))
        try await waitUntil(timeout: .seconds(85)) {
            model.discussions.first(where: { $0.id == childID })?.turns.last?.state != .running
        }
        let joined = try XCTUnwrap(model.discussions.first { $0.id == childID }?.turns.last)
        let current = try XCTUnwrap(model.discussions.first { $0.id == childID })
        let profile = GroupDiscussionStore(root: root).pooledRuntimeStore(for: current, role: warm, fullAccess: true)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf:
            profile.runtime(for: warm.id).appendingPathComponent("config.yaml"))) as? [String: Any]
        let enabled = (config?["platform_toolsets"] as? [String: [String]])?["acp"] ?? []
        XCTAssertTrue(enabled.contains("file"))
        XCTAssertFalse(enabled.contains("terminal"))
        XCTAssertFalse(enabled.contains("browser"))
        XCTAssertNil(config?["mcp_servers"], "群工具应通过原生会话作用域传入，不能写入共享运行配置。")
        XCTAssertEqual(joined.joinedMemberNames, [pear.name], joined.answer ?? model.error ?? "")
        guard joined.joinedMemberNames == [pear.name] else { return }
        let reloaded = GroupWorkspaceModel(roleStore: roles)
        XCTAssertEqual(reloaded.discussions.filter { $0.groupID == groupID }.map(\.memberIDs),
            [[warm.id, pear.id], [warm.id, pear.id]])

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-B", "-u", "-c", """
            import http.server
            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    body = b'<html><title>Fixture</title><body>PAGE-LOCAL-517</body></html>'
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html; charset=utf-8')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
            server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
            print(server.server_port)
            server.serve_forever()
            """]
        let pipe = Pipe()
        server.standardOutput = pipe
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        let portData = try XCTUnwrap(try pipe.fileHandleForReading.read(upToCount: 6))
        let port = try XCTUnwrap(Int(String(decoding: portData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(model.submit(groupID: childID, roleID: warm.id,
            question: "打开 http://127.0.0.1:\(port)/ 并原样复述正文里的英文标记。", attachments: [], runtime: runtime))
        try await waitUntil(timeout: .seconds(85)) {
            model.discussions.first(where: { $0.id == childID })?.turns.last?.state != .running
        }
        let last = try XCTUnwrap(model.discussions.first { $0.id == childID }?.turns.last)
        XCTAssertEqual(last.state, .completed, model.error ?? "")
        XCTAssertTrue(last.answer?.contains("PAGE-LOCAL-517") == true, last.answer ?? model.error ?? "")
    }

    @MainActor
    func testLiveNaturalGroupUsesConfiguredStyleAndOnlyOneLinkReply() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_GROUP_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_GROUP_TEST=1，验证自然接话和个性配置。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let a = Role(name: "云岚", summary: "", template: .general)
        let b = Role(name: "晴晴", summary: "", template: .writing)
        for role in [a, b] { try store.create(role, instructions: "看到用户发来一条链接时，简短回答一句。") }
        var preferences = GroupMemberChatPreferences()
        preferences.tone = .custom
        preferences.intensity = .vivid
        preferences.customTone = "清冷稳重。开头固定写「晚风档案」，然后用一句话回答。"
        let model = GroupWorkspaceModel(roleStore: store)
        let groupID = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "配置联调", goal: "",
            memberIDs: [a.id, b.id], relayLimit: 0, memberChatPreferences: [a.id: preferences],
            firstTask: "", firstSpeaker: nil, runtime: runtime))
        let profiles = GroupDiscussionStore(root: root).runtimeStore(for: groupID)
        defer { for role in [a, b] { runtime.reset(home: profiles.runtime(for: role.id)) } }
        XCTAssertTrue(model.submit(groupID: groupID, roleID: nil, question: "https://group-test.invalid/?view=feed",
            attachments: [], runtime: runtime))
        try await waitUntil(timeout: .seconds(65)) {
            guard let group = model.discussions.first else { return false }
            return group.paused || group.turns.allSatisfy { $0.state == .completed }
        }
        let turns = try XCTUnwrap(model.discussions.first?.turns)
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(turns.first?.answer?.contains("晚风档案") == true, model.error ?? turns.first?.answer ?? "")
    }

    @MainActor
    func testLiveGroupParallelRepliesReachBothModelsBeforeCompletion() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_GROUP_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_GROUP_TEST=1，验证本机 Hermes 群聊并行。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let warm = Role(name: "暖暖", summary: "", template: .general)
        let sweet = Role(name: "糖糖", summary: "", template: .writing)
        try roles.create(warm, instructions: "请直接回答用户话题，在正文中写 WARM-613。")
        try roles.create(sweet, instructions: "请直接回答用户话题，在正文中写 SWEET-613。")
        let model = GroupWorkspaceModel(roleStore: roles)
        let groupID = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "并行回复联调",
            goal: "", memberIDs: [warm.id, sweet.id], relayLimit: 0, replyMode: .parallel, casualReplyLimit: 2,
            firstTask: "", firstSpeaker: nil, runtime: runtime))
        let profiles = GroupDiscussionStore(root: root).runtimeStore(for: groupID)
        defer { for role in [warm, sweet] { runtime.reset(home: profiles.runtime(for: role.id)) } }
        let start = ContinuousClock.now
        XCTAssertTrue(model.submit(groupID: groupID, roleID: nil, question: "我今天吃了番茄牛肉面，请各写三四句话聊聊。",
            attachments: [], runtime: runtime))
        var submitted: [UUID: Duration] = [:]
        var firstCompletion: Duration?
        try await waitUntil(timeout: .seconds(85)) {
            guard let group = model.discussions.first(where: { $0.id == groupID }) else { return false }
            for turn in group.turns where submitted[turn.id] == nil {
                if let phase = model.activity(groupID: groupID, turnID: turn.id),
                    ["等待模型回复", "正在思考", "正在回复"].contains(phase) {
                    submitted[turn.id] = start.duration(to: .now)
                }
            }
            if firstCompletion == nil, group.turns.contains(where: { $0.state == .completed }) {
                firstCompletion = start.duration(to: .now)
            }
            return group.paused || group.turns.allSatisfy { $0.state == .completed }
        }
        let group = try XCTUnwrap(model.discussions.first { $0.id == groupID })
        XCTAssertEqual(group.turns.map(\.kind), [.parallelTopic, .parallelReply], model.error ?? "")
        XCTAssertEqual(Set(group.sessions.values).count, 2)
        XCTAssertTrue(group.turns.first?.answer?.contains("WARM-613") == true)
        XCTAssertTrue(group.turns.last?.answer?.contains("SWEET-613") == true)
        let starts = group.turns.compactMap { submitted[$0.id] }
        let completed = try XCTUnwrap(firstCompletion)
        XCTAssertEqual(starts.count, 2)
        if let later = starts.max() { XCTAssertLessThan(later, completed, "两位助手应在第一条回复结束前都已提交") }
        print("群聊提交时间 \(starts)，首条回复完成时间 \(completed)")
    }

    @MainActor
    func testGroupEveryoneRunsEveryMemberWithinParallelLimit() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("模拟 ACP 需要系统 Python。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let members = ["规划", "验收", "汇报"].map { Role(name: $0, summary: "", template: .blank) }
        for role in members { try roles.create(role, instructions: "") }
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let model = GroupWorkspaceModel(roleStore: roles)
        let groupID = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "协作",
            goal: "", memberIDs: members.map(\.id), relayLimit: 0, replyMode: .parallel, casualReplyLimit: 1,
            firstTask: "", firstSpeaker: nil, runtime: runtime))
        XCTAssertTrue(model.submit(groupID: groupID, roleID: nil, question: "并行进程验证", attachments: [],
            runtime: runtime, toEveryone: true))
        XCTAssertEqual(model.discussions.first?.turns.map(\.state), [.running, .running, .queued])
        try await waitUntil {
            model.discussions.first?.turns.map(\.state) == [.completed, .completed, .completed]
        }
        let persisted = try XCTUnwrap(GroupDiscussionStore(root: root).discussions().first)
        XCTAssertEqual(persisted.turns.map(\.roleID), members.map(\.id))
        XCTAssertEqual(persisted.turns.filter(\.initiatedByUser).count, 1)
        XCTAssertTrue(persisted.turns.allSatisfy { $0.answer?.contains("进程 ") == true })
    }

    @MainActor
    func testGroupParallelProcessesAndIdleLimitAcrossConversations() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("模拟 ACP 需要系统 Python。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let warm = Role(name: "暖暖", summary: "", template: .general)
        let sweet = Role(name: "糖糖", summary: "", template: .writing)
        for role in [warm, sweet] { try roles.create(role, instructions: "测试：两个会话同时建立") }
        let executable = root.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = HermesRuntime(executable: executable)
        let model = GroupWorkspaceModel(roleStore: roles)
        let groupID = try XCTUnwrap(model.saveSettings(groupID: nil, proposalID: nil, title: "闲聊",
            goal: "", memberIDs: [warm.id, sweet.id], relayLimit: 0, replyMode: .parallel, casualReplyLimit: 2,
            idleChatMinutes: 2, firstTask: "", firstSpeaker: nil, runtime: runtime))
        let conversationID = try XCTUnwrap(model.newConversation(in: groupID))
        XCTAssertTrue(model.submit(groupID: conversationID, roleID: nil, question: "并行进程验证", attachments: [], runtime: runtime))
        let turns = try XCTUnwrap(model.discussions.first { $0.id == conversationID }?.turns)
        XCTAssertEqual(turns.map(\.state), [.running, .running])
        XCTAssertFalse(model.setConversationArchived(conversationID, archived: true))
        try await waitUntil {
            turns.allSatisfy { model.liveText(groupID: conversationID, turnID: $0.id)?.contains("进程 ") == true }
        }
        let pids = turns.compactMap { model.liveText(groupID: conversationID, turnID: $0.id) }
        XCTAssertEqual(Set(pids).count, 2)
        try await waitUntil {
            model.discussions.first(where: { $0.id == conversationID })?.turns.allSatisfy { $0.state == .completed } == true
        }
        XCTAssertTrue(model.discussions.first { $0.id == groupID }?.turns.isEmpty == true)

        let now = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        let discussionStore = GroupDiscussionStore(root: root)
        for var saved in model.discussions {
            saved.updated = now.addingTimeInterval(-1200)
            for index in saved.turns.indices { saved.turns[index].created = saved.updated }
            try discussionStore.save(saved)
        }
        let idleModel = GroupWorkspaceModel(roleStore: roles)
        idleModel.visibleThreadID = conversationID
        idleModel.startIdleChats(now: now, runtime: runtime)
        try await waitUntil {
            idleModel.discussions.first(where: { $0.id == conversationID })?.turns.count == 3 &&
                idleModel.discussions.first(where: { $0.id == conversationID })?.turns.last?.state == .completed
        }
        idleModel.startIdleChats(now: now.addingTimeInterval(1800), runtime: runtime)
        XCTAssertEqual(idleModel.discussions.flatMap(\.turns).filter { $0.kind == .proactiveTopic }.count, 1)
        let beforeRename = try XCTUnwrap(idleModel.discussions.first { $0.id == conversationID })
        XCTAssertEqual(beforeRename.displayConversationTitle, "并行进程验证")
        idleModel.renameConversation(conversationID, title: "  并行联调记录  ")
        XCTAssertEqual(idleModel.discussions.first { $0.id == conversationID }?.updated, beforeRename.updated)
        _ = idleModel.saveSettings(groupID: groupID, proposalID: nil, title: "闲聊改名",
            goal: "", memberIDs: [warm.id], relayLimit: 0, firstTask: "", firstSpeaker: nil, runtime: runtime)
        let reloaded = GroupWorkspaceModel(roleStore: roles)
        let child = try XCTUnwrap(reloaded.discussions.first { $0.id == conversationID })
        XCTAssertEqual(child.memberIDs, [warm.id])
        XCTAssertEqual(child.title, "闲聊改名")
        XCTAssertEqual(child.displayConversationTitle, "并行联调记录")
        XCTAssertEqual(child.turns.count, 3)
    }

    @MainActor
    func testLivePrivateRoleCanRecallItsRecentGroupChat() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_GROUP_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_GROUP_TEST=1，联调私聊的群聊回顾。")
        }
        try await verifyPrivateRoleRecall(runtime: XCTUnwrap(HermesRuntime.discover()))
    }

    @MainActor
    func testPrivateRoleRecallSendsScopeOnceWithNoTools() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("模拟 ACP 需要系统 Python。")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent("mock-hermes")
        try Data(Self.fixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await verifyPrivateRoleRecall(runtime: HermesRuntime(executable: executable))
    }

    @MainActor
    private func verifyPrivateRoleRecall(runtime: HermesRuntime) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let warm = Role(name: "暖暖", summary: "", template: .general)
        let sweet = Role(name: "糖糖", summary: "", template: .writing)
        for role in [warm, sweet] { try store.create(role, instructions: "用自己的语气答复。") }
        var group = GroupDiscussion(title: "闲聊联调", goal: "", memberIDs: [warm.id, sweet.id])
        group.chatActivity = .lively
        group.casualReplyLimit = 2
        group.addTopic("我今天吃了番茄牛肉面。", attachments: [], activeMembers: [warm, sweet])
        group.recordReply("暖暖：听起来挺香。", at: 0, activeMembers: [warm, sweet])
        group.recordReply("糖糖：我下次也想试试番茄牛肉面，这次没有生气。", at: 1, activeMembers: [warm, sweet])
        try GroupDiscussionStore(root: root).save(group)
        let studio = StudioModel(dataStore: store, runtime: runtime, runPreferences: .init())
        defer { runtime.reset(home: store.runtime(for: warm.id)) }
        studio.select(warm)
        for question in ["刚才糖糖不会生我气吧？请用一句话接话，提到刚才那道菜的完整名字。", "行啊"] {
            let start = ContinuousClock.now
            studio.draft = question
            studio.send()
            var modelWait: Duration?
            try await waitUntil(timeout: .seconds(65)) {
                if modelWait == nil && studio.activity == "等待模型回复" { modelWait = start.duration(to: .now) }
                return !studio.isGeneratingHere
            }
            let messages = try XCTUnwrap(studio.conversation?.messages, studio.chatError ?? "")
            let answer = try XCTUnwrap(messages.last, studio.chatError ?? "")
            XCTAssertEqual(answer.author, .assistant)
            XCTAssertTrue(answer.text.contains("番茄牛肉面"), answer.text)
            XCTAssertFalse(messages.contains { $0.author == .tool })
            XCTAssertNil(studio.conversation?.sessionID)
            print("群聊回顾耗时 \(start.duration(to: .now))，提交前 \(modelWait ?? .zero)，工具调用 0 次")
        }
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw StudioError.message("等待会话状态超时。") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private static let fixture = #"""
        #!/usr/bin/python3
        import json, os, re, select, signal, sys, time, uuid
        from pathlib import Path

        if sys.argv[1:] != ["acp"]:
            fixture_skills = Path(__file__).resolve().parent / "fixture-skills"
            if sys.argv[-1] == "skills" and fixture_skills.is_dir():
                print(json.dumps({"external_dirs": [str(fixture_skills)]}))
            else:
                print('{"default":"tester","provider":"fixture"}' if sys.argv[-1] == "model" else "{}")
            sys.exit(0)

        def send(**message):
            print(json.dumps(dict(jsonrpc="2.0", **message)), flush=True)

        def update(session, text):
            send(method="session/update", params={"sessionId": session, "update": {
                "sessionUpdate": "agent_message_chunk", "messageId": "reply", "content": {"text": text}}})

        directories = {}
        recall_session = None
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            request = json.loads(line)
            method = request["method"]
            params = request["params"]
            soul = Path(os.environ["HERMES_HOME"]) / "SOUL.md"
            if soul.exists() and "测试群进程复用" in soul.read_text():
                with (soul.parent / "warm-events.jsonl").open("a") as log:
                    log.write(json.dumps({"method": method, "pid": os.getpid()}) + "\n")
            result = {"ok": True}
            if method == "session/new":
                home = Path(os.environ["HERMES_HOME"])
                soul = home / "SOUL.md"
                if soul.exists() and "测试：两个会话同时建立" in soul.read_text() and json.loads((home / "config.yaml").read_text()).get("agent", {}).get("max_turns") != 1:
                    shared = home.parents[2]
                    (shared / ("ready-" + home.parent.name)).touch()
                    deadline = time.monotonic() + 5.0
                    while len(list(shared.glob("ready-*"))) < 2:
                        assert time.monotonic() < deadline, "两个角色的会话启动未重叠"
                        time.sleep(0.025)
                result = {"sessionId": uuid.uuid4().hex}
                directories[result["sessionId"]] = params["cwd"]
            elif method == "session/load":
                directories[params["sessionId"]] = params["cwd"]
            elif method == "session/prompt":
                session, name = params["sessionId"], params["prompt"][0]["text"]
                if "请看看这些附件。" in name:
                    images = [block for block in params["prompt"] if block.get("type") == "image"]
                    assert len(images) == 1 and len(images[0]["data"]) > 100, "群聊图片没有作为图片输入发送"
                reason = "end_turn"
                if name.startswith("当前任务选择了 Hermes 技能「发送验证技能」"):
                    assert name.endswith("studio-send-fixture 获取技能指令。")
                    assert len(params["prompt"]) == 2 and params["prompt"][1]["text"].startswith("回复方式：")
                    update(session, "已收到单独发送的技能")
                elif name == "待发图片":
                    images = [block for block in params["prompt"] if block.get("type") == "image"]
                    assert len(images) == 1 and len(images[0]["data"]) > 100, "待发图片没有作为图片发送"
                    update(session, "收到待发图片")
                elif name == "甲" and (soul.parent / ("stopped-" + session)).exists():
                    update(session, "从原会话继续完成")
                elif name in ("甲", "乙"):
                    update(session, name + "开始")
                    send(id="permission", method="session/request_permission", params={
                        "sessionId": session, "toolCall": {"toolCallId": "shared", "title": name + "的审批"},
                        "options": [{"optionId": "allow", "name": "允许", "kind": "allow_once"}]})
                    ready, _, _ = select.select([sys.stdin], [], [], 15)
                    if not ready:
                        sys.exit(1)
                    response = json.loads(sys.stdin.readline())
                    if response.get("method") == "session/cancel":
                        assert response["params"]["sessionId"] == session
                        # 模拟 Hermes 在登记执行前忽略第一次停止，并仍发出一段迟到的内容。
                        update(session, "停止后的内容")
                        ready, _, _ = select.select([sys.stdin], [], [], 3)
                        assert ready
                        retry = json.loads(sys.stdin.readline())
                        assert retry["method"] == "session/cancel" and retry["params"]["sessionId"] == session
                        (soul.parent / ("stopped-" + session)).touch()
                        reason = "cancelled"
                    else:
                        assert response["result"]["outcome"]["optionId"] == "allow"
                        update(session, name + "完成")
                elif name == "丙":
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    update(session, "丙开始")
                    time.sleep(8)
                elif name.startswith("用户请你为助手"):
                    update(session, "准备交接的过程说明")
                    send(method="session/update", params={"sessionId": session, "update": {
                        "sessionUpdate": "tool_call", "toolCallId": "handoff-step",
                        "title": "工具内部详情", "status": "completed"}})
                    update(session, "已完成整理，待验证清单")
                elif name.startswith("根据用户的任务说明接手"):
                    assert "接手验证清单" in name and "已完成整理，待验证清单" in name
                    assert "已有历史中的内部原文" not in name and "工具内部详情" not in name
                    assert len(params["prompt"]) == 2
                    assert directories[session] == os.path.join(os.environ["HERMES_HOME"], "workspace")
                    update(session, "已接手验证清单")
                elif name.startswith("用户请你向助手"):
                    update(session, "代拟的协作问题")
                elif name.startswith("用户在对话中点名向你提问"):
                    home = os.environ["HERMES_HOME"]
                    assert "hermes-studio-consultation-" in home
                    assert name.endswith(("仅把这个问题发给 B", "代拟的协作问题", "他呀"))
                    assert "A 的私有聊天上下文" not in name
                    with open(os.path.join(home, "SOUL.md")) as file:
                        assert file.read() == "B 的角色设定"
                    with open(os.path.join(home, "config.yaml")) as file:
                        config = json.load(file)
                        assert config["platform_toolsets"]["acp"] == [] and not config["memory"]["memory_enabled"]
                        assert "mcp_servers" not in config
                    if name.endswith("他呀"):
                        assert "前文线索-643" in name and "前文线索-643完成" not in name
                        update(session, "B 已接上前文")
                    else:
                        update(session, "B 的协作答复")
                elif name.startswith(("你看她", "刚才助手 B 说了什么")):
                    assert "当前私聊" in name and "B 的协作答复" in name and "仅把这个问题发给 B" in name
                    assert "下面已附上的群聊片段" not in name
                    update(session, "A 读到了本对话里的协作原话")
                elif name.startswith("请继续原任务") and "B 的协作答复" in name:
                    update(session, "A 已参考 B 的回复")
                elif "下面已附上的群聊片段" in name:
                    home = os.environ["HERMES_HOME"]
                    assert "hermes-studio-group-recall-" in home
                    assert "番茄牛肉面" in name and "刚才糖糖不会生我气吧" in name
                    assert len(params["prompt"]) == 1
                    if name.startswith("行啊"):
                        assert recall_session is not None and recall_session != session
                    recall_session = session
                    with open(os.path.join(home, "config.yaml")) as file:
                        config = json.load(file)
                        assert config["platform_toolsets"]["acp"] == [] and not config["memory"]["memory_enabled"]
                        assert "mcp_servers" not in config
                    update(session, "刚才聊到番茄牛肉面，糖糖说她也想试试。")
                elif name.startswith("你作为「"):
                    speaker = name.split("」", 1)[0].removeprefix("你作为「")
                    assert not os.path.exists(os.path.join(os.environ["HERMES_HOME"], "memories", "MEMORY.md"))
                    next_role = None
                    if speaker == "规划搭档" and "给你的当前任务：\n执行三人接力" in name:
                        next_role = "验收搭档"
                    elif speaker == "验收搭档" and "给你的当前任务：\n继续接力" in name:
                        assert "规划搭档回复：" in name
                        next_role = "汇报搭档"
                    reply = speaker + "完成发言"
                    if "并行进程验证" in name:
                        update(session, "进程 " + str(os.getpid()))
                        time.sleep(1.3)
                    if next_role:
                        role_id = re.search(next_role + "（([A-F0-9-]+)）", name).group(1)
                        reply += "\n[[接力 " + role_id + "]] 继续接力"
                    update(session, reply)
                else:
                    update(session, name + "完成")
                result = {"stopReason": reason}
            send(id=request["id"], result=result)
        """#
}
