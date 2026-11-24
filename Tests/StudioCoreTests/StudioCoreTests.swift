import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import StudioCore

final class StudioCoreTests: XCTestCase {
    func testRoleLibraryDissolvesLegacyAndArchivedMembersAndPersistsEmptyGroupOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        var active = Role(name: "柚子", summary: "", template: .blank)
        var archived = Role(name: "糖糖", summary: "", template: .blank)
        try store.create(active, instructions: "原指令", initialMemory: [.memory: "原记忆"])
        try store.create(archived, instructions: "")
        active.libraryGroup = "旧分组"
        archived.libraryGroup = "旧分组"
        archived.archivedAt = Date()
        for role in [active, archived] {
            try JSONEncoder().encode(role).write(to: store.roleDirectory(role.id).appendingPathComponent("role.json"), options: .atomic)
        }
        var thread = Conversation(roleID: active.id)
        thread.messages = [Message(.user, "保留这段对话")]
        try store.save(thread)

        XCTAssertEqual(try store.libraryGroups(), ["旧分组"])
        XCTAssertEqual(try store.list().first?.libraryGroup, "旧分组")
        XCTAssertEqual(try store.createLibraryGroup(" 工作协作 "), "工作协作")
        XCTAssertTrue(try store.reorderLibraryGroup("工作协作", to: "旧分组"))
        let reopened = RoleStore(root: root)
        XCTAssertEqual(try reopened.libraryGroups(), ["工作协作", "旧分组"])
        XCTAssertEqual(try reopened.archivedRoles().first?.libraryGroup, "旧分组")

        try reopened.dissolveLibraryGroup("旧分组")
        XCTAssertEqual(try reopened.libraryGroups(), ["工作协作"])
        XCTAssertNil(try reopened.list().first?.libraryGroup)
        XCTAssertNil(try reopened.archivedRoles().first?.libraryGroup)
        XCTAssertThrowsError(try reopened.moveRoleToLibraryGroup(active.id, to: "旧分组"))
        try reopened.createLibraryGroup("旧分组")
        XCTAssertNil(try reopened.restore(archived.id).libraryGroup)
        XCTAssertNil(try reopened.list().first { $0.id == active.id }?.libraryGroup)
        XCTAssertEqual(try reopened.moveRoleToLibraryGroup(active.id, to: "工作协作")?.libraryGroup, "工作协作")
        active.pinned = true
        XCTAssertEqual(try reopened.update(active).libraryGroup, "工作协作")
        XCTAssertEqual(try reopened.file(.soul, for: active.id), "原指令")
        XCTAssertEqual(try reopened.file(.memory, for: active.id), "原记忆")
        XCTAssertEqual(try reopened.conversations(for: active.id).first?.messages, thread.messages)
    }

    func testRoleLibraryRenameKeepsLegacyMembersAndRejectsDuplicateNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        var active = Role(name: "柚子", summary: "", template: .blank)
        var archived = Role(name: "糖糖", summary: "", template: .blank)
        try store.create(active, instructions: "原始角色指令")
        try store.create(archived, instructions: "")
        active.libraryGroup = "旧分组"
        archived.libraryGroup = "旧分组"
        archived.archivedAt = Date()
        for role in [active, archived] {
            let record = store.roleDirectory(role.id).appendingPathComponent("role.json")
            try JSONEncoder().encode(role).write(to: record, options: .atomic)
        }

        XCTAssertEqual(try store.renameLibraryGroup("旧分组", to: " 日常协作 "), "日常协作")
        let memberID = try XCTUnwrap(store.list().first?.libraryGroupID)
        XCTAssertEqual(try store.archivedRoles().first?.libraryGroupID, memberID)
        try store.createLibraryGroup("Work")
        for invalid in ["  ", "未分组", "work", "多行\n名称"] {
            XCTAssertThrowsError(try store.renameLibraryGroup("日常协作", to: invalid))
        }
        XCTAssertThrowsError(try store.renameLibraryGroup("不存在", to: "新分组"))
        XCTAssertEqual(try store.renameLibraryGroup("Work", to: "WORK"), "WORK")
        try store.createLibraryGroup("旧分组")

        let reopened = RoleStore(root: root)
        XCTAssertEqual(try reopened.libraryGroups(), ["日常协作", "WORK", "旧分组"])
        XCTAssertEqual(try reopened.list().first?.libraryGroup, "日常协作")
        XCTAssertEqual(try reopened.restore(archived.id).libraryGroup, "日常协作")
        XCTAssertEqual(try reopened.list().first?.libraryGroupID, memberID)
        XCTAssertEqual(try reopened.file(.soul, for: active.id), "原始角色指令")
    }

    func testGatewayRepairDiscardsOnlyTheDeadOwnerPointerFromTheOldHome() throws {
        let files = FileManager.default
        let parent = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: parent) }
        let store = RoleStore(root: parent.appendingPathComponent("hermesgroup"))
        let role = Role(name: "网关验收", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let runtime = store.runtime(for: role.id)
        let oldHome = parent.appendingPathComponent("旧角色目录")
        let oldSocket = parent.appendingPathComponent(HermesGatewayRendezvous.fallbackDirectory(for: oldHome))
            .appendingPathComponent("control.sock")
        let pointer = runtime.appendingPathComponent("gateway.sock.path")
        let owner = runtime.appendingPathComponent("gateway.pid")
        try Data(oldSocket.path.utf8).write(to: pointer)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pointer.path)

        func writeOwner(_ pid: Int32) throws {
            let record = try JSONSerialization.data(withJSONObject: ["pid": pid, "hermes_home": oldHome.path])
            try record.write(to: owner)
        }

        try writeOwner(ProcessInfo.processInfo.processIdentifier)
        try HermesGatewayRendezvous.cleanRelocatedPointer(in: runtime)
        XCTAssertTrue(files.fileExists(atPath: pointer.path))

        let stopped = Process()
        stopped.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try stopped.run()
        stopped.waitUntilExit()
        try writeOwner(stopped.processIdentifier)
        try HermesGatewayRendezvous.cleanRelocatedPointer(in: runtime)
        XCTAssertFalse(files.fileExists(atPath: pointer.path))
        XCTAssertTrue(files.fileExists(atPath: owner.path))
    }

    func testMovingDataRootKeepsRolesMemoryAndProjectFolders() throws {
        let files = FileManager.default
        let parent = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: parent) }
        let legacy = RoleStore(root: parent.appendingPathComponent("旧数据"))
        let destination = RoleStore(root: parent.appendingPathComponent("hermesgroup"))
        let role = Role(name: "迁移验证", summary: "", template: .blank)
        try legacy.create(role, instructions: "原有角色指令")
        try legacy.writeFile(.memory, for: role.id, text: "原有角色记忆")
        let internalProject = try legacy.createProject(name: "内置项目", directory: nil, for: role.id)
        let external = parent.appendingPathComponent("外部目录")
        try files.createDirectory(at: external, withIntermediateDirectories: true)
        let externalProject = try legacy.createProject(name: "外部项目", directory: external, for: role.id)
        var thread = Conversation(roleID: role.id)
        thread.projectID = internalProject.id
        thread.messages = [Message(.user, "原有消息")]
        try legacy.save(thread)
        let pointer = legacy.runtime(for: role.id).appendingPathComponent("gateway.sock.path")
        try Data("旧地址".utf8).write(to: pointer)

        try destination.migrateDataIfNeeded(from: legacy.root)
        XCTAssertEqual(try destination.list(), [role])
        XCTAssertEqual(try destination.conversations(for: role.id), [thread])
        XCTAssertEqual(try destination.file(.memory, for: role.id), "原有角色记忆")
        XCTAssertTrue(files.fileExists(atPath: pointer.path))
        XCTAssertFalse(files.fileExists(atPath: destination.runtime(for: role.id)
            .appendingPathComponent("gateway.sock.path").path))
        let projects = try destination.projects(for: role.id)
        let relocated = try XCTUnwrap(projects.first { $0.id == internalProject.id })
        XCTAssertTrue(relocated.path.hasPrefix(destination.root.resolvingSymlinksInPath().path + "/"))
        XCTAssertTrue(files.fileExists(atPath: relocated.path))
        XCTAssertEqual(projects.first { $0.id == externalProject.id }, externalProject)
        try destination.writeFile(.memory, for: role.id, text: "升级后的修改")
        try destination.migrateDataIfNeeded(from: legacy.root)
        XCTAssertEqual(try destination.file(.memory, for: role.id), "升级后的修改")
        XCTAssertEqual(try legacy.file(.memory, for: role.id), "原有角色记忆")
    }

    func testConversationPinArchiveAndRestorePreserveHistoryAndProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "整理对话", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let project = try store.createProject(name: "归档验证", directory: nil, for: role.id)
        var thread = Conversation(roleID: role.id)
        thread.projectID = project.id
        thread.sessionID = "测试会话"
        thread.messages = [Message(.user, "历史问题"), Message(.assistant, "历史答复")]
        try store.save(thread)

        let pinned = try store.setConversationPinned(true, id: thread.id, for: role.id)
        XCTAssertNotNil(pinned.pinnedAt)
        let archived = try store.setConversationArchived(true, id: thread.id, for: role.id)
        XCTAssertNotNil(archived.archivedAt)
        let reopened = RoleStore(root: root)
        XCTAssertEqual(try reopened.conversations(for: role.id), [archived])
        XCTAssertThrowsError(try reopened.setConversationPinned(false, id: thread.id, for: role.id))
        XCTAssertEqual(try reopened.setConversationArchived(false, id: thread.id, for: role.id), pinned)
        XCTAssertEqual(try reopened.setConversationPinned(false, id: thread.id, for: role.id), thread)
    }

    func testDeletingDraftRoleMovesItsDataToTrashAndKeepsLinkedFolder() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "草稿箱删除验证", summary: "", template: .blank)
        try store.create(role, instructions: "角色指令")
        let linked = root.appendingPathComponent("外部项目")
        try files.createDirectory(at: linked, withIntermediateDirectories: true)
        _ = try store.createProject(name: "外部项目", directory: linked, for: role.id)
        let owned = try store.createProject(name: "角色内项目", directory: nil, for: role.id)
        try store.save(Conversation(roleID: role.id))
        XCTAssertThrowsError(try store.trashArchivedRole(role.id))
        _ = try store.archive(role.id)
        let trash = try XCTUnwrap(store.trashArchivedRole(role.id))
        defer { try? files.removeItem(at: trash) }

        XCTAssertTrue(try store.archivedRoles().isEmpty)
        XCTAssertTrue(files.fileExists(atPath: linked.path))
        XCTAssertFalse(files.fileExists(atPath: owned.path))
        XCTAssertTrue(files.fileExists(atPath: trash.appendingPathComponent("conversations.json").path))
        XCTAssertTrue(files.fileExists(atPath: trash.appendingPathComponent("Projects/角色内项目").path))
    }

    func testRoleFilesAndConversationsAreIsolatedAfterReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        var first = Role(name: "同名角色", summary: "", template: .writing)
        var second = Role(name: "同名角色", summary: "", template: .engineering)
        first.created = Date(timeIntervalSince1970: 10)
        second.created = Date(timeIntervalSince1970: 20)
        second.pinned = true
        try store.create(first, instructions: "写作指令")
        try store.create(second, instructions: "研发指令")
        try store.writeFile(.memory, for: first.id, text: "写作记忆")
        try store.writeFile(.user, for: second.id, text: "研发偏好")
        var thread = Conversation(roleID: first.id)
        thread.sessionID = "test-session"
        try store.save(thread)
        thread.messages.append(Message(.user, "继续对话"))
        try store.save(thread)

        let reopened = RoleStore(root: root)
        XCTAssertEqual(try reopened.list().map(\.id), [first.id, second.id])
        XCTAssertEqual(try reopened.list().last?.pinned, true)
        XCTAssertEqual(try reopened.file(.soul, for: first.id), "写作指令")
        XCTAssertEqual(try reopened.file(.soul, for: second.id), "研发指令")
        XCTAssertEqual(try reopened.file(.memory, for: first.id), "写作记忆")
        XCTAssertEqual(try reopened.file(.memory, for: second.id), "")
        XCTAssertEqual(try reopened.file(.user, for: first.id), "")
        XCTAssertEqual(try reopened.file(.user, for: second.id), "研发偏好")
        XCTAssertEqual(try reopened.conversations(for: first.id), [thread])
        XCTAssertEqual(try reopened.conversations(for: second.id), [])
    }

    func testProjectsCreateAndLinkRealFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "项目角色", summary: "", template: .blank)
        let other = Role(name: "另一个助手", summary: "", template: .blank)
        try store.create(role, instructions: "")
        try store.create(other, instructions: "")
        let created = try store.createProject(name: "开发与研究", directory: nil, for: role.id)
        let separate = try store.createProject(name: "开发与研究", directory: nil, for: other.id)
        XCTAssertTrue(try created.directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        XCTAssertEqual(created.directory.lastPathComponent, "开发与研究")
        XCTAssertNotEqual(separate.directory, created.directory)
        XCTAssertThrowsError(try store.createProject(name: "重复", directory: created.directory, for: role.id))
        XCTAssertThrowsError(try store.createProject(name: "../异常目录", directory: nil, for: role.id))
        let chosen = root.appendingPathComponent("已有目录", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let linked = try store.createProject(name: "关联项目", directory: chosen, for: role.id)
        var thread = Conversation(roleID: role.id)
        thread.sessionID = "已有会话"
        thread.messages.append(Message(.user, "历史消息"))
        try store.save(thread)
        let moved = try store.moveConversation(thread.id, for: role.id, to: linked.id)
        thread.projectID = linked.id
        let reopened = RoleStore(root: root)
        XCTAssertEqual(try reopened.projects(for: role.id), [linked, created])
        XCTAssertEqual(try reopened.projects(for: other.id), [separate])
        XCTAssertEqual(moved, thread)
        XCTAssertEqual(try reopened.conversations(for: role.id), [thread])
        XCTAssertThrowsError(try store.moveConversation(thread.id, for: role.id, to: UUID()))
        XCTAssertThrowsError(try store.moveConversation(thread.id, for: role.id, to: separate.id))
        XCTAssertThrowsError(try store.moveConversation(UUID(), for: role.id, to: created.id))
        var foreignThread = Conversation(roleID: other.id)
        foreignThread.projectID = linked.id
        XCTAssertThrowsError(try store.save(foreignThread))
        XCTAssertEqual(try reopened.conversations(for: other.id), [])
        XCTAssertEqual(try reopened.conversations(for: role.id), [thread])
        XCTAssertNil(try store.moveConversation(thread.id, for: role.id, to: nil).projectID)
    }

    func testLegacyProjectsStayWithTheirExistingConversations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        var first = Role(name: "最早创建的助手", summary: "", template: .blank)
        first.created = Date.distantPast
        let second = Role(name: "项目助手", summary: "", template: .blank)
        let archived = Role(name: "已归档助手", summary: "", template: .blank)
        for role in [first, second, archived] {
            try store.create(role, instructions: "")
        }
        _ = try store.archive(archived.id)
        let shared = UUID()
        let unused = UUID()
        let path = root.appendingPathComponent("原目录").path
        let records: [[String: Any]] = [
            ["id": shared.uuidString, "name": "已有对话", "path": path, "created": 10],
            ["id": unused.uuidString, "name": "未开始", "path": path + "-空", "created": 20]
        ]
        try JSONSerialization.data(withJSONObject: records).write(to: root.appendingPathComponent("projects.json"))
        var previous: [UUID: Conversation] = [:]
        for role in [second, archived] {
            var thread = Conversation(roleID: role.id)
            thread.projectID = shared
            thread.sessionID = "原会话-\(role.id)"
            thread.messages = [Message(.user, role.name)]
            previous[role.id] = thread
            let file = store.roleDirectory(role.id).appendingPathComponent("conversations.json")
            try JSONEncoder().encode([thread]).write(to: file)
        }

        XCTAssertEqual(try store.projects(for: first.id).map(\.id), [unused])
        let reopened = RoleStore(root: root)
        for role in [second, archived] {
            let project = try XCTUnwrap(reopened.projects(for: role.id).first)
            XCTAssertEqual(project.id, shared)
            XCTAssertEqual(project.roleID, role.id)
            XCTAssertEqual(project.path, path)
            XCTAssertEqual(try reopened.conversations(for: role.id), [try XCTUnwrap(previous[role.id])])
        }
        XCTAssertEqual(try reopened.projects(for: first.id).map(\.id), [unused])
    }

    func testImageAttachmentPersistsInsideItsRole() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "图片角色", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let image = try makeRedImage()
        let saved = try store.saveImage(image, for: role.id)
        XCTAssertEqual(try Data(contentsOf: store.imageURL(saved, for: role.id)), image.data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(saved, for: UUID()).path))
        XCTAssertThrowsError(try ImagePayload.prepare(name: "坏图", data: Data("错误数据".utf8)))
    }

    func testClipboardPrefersImageDataOverTextAndReadsFinderFiles() throws {
        let board = NSPasteboard(name: .init("studio.clipboard.test.\(UUID())"))
        defer { board.releaseGlobally() }
        let data = try makeRedImage().data
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("与图片一起复制的文本", forType: .string))
        XCTAssertTrue(item.setData(data, forType: .init(UTType.jpeg.identifier)))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        XCTAssertTrue(ClipboardImages.canRead(from: board))
        guard case .pixels(let images) = ClipboardImages.read(from: board) else {
            return XCTFail("混合剪贴板应识别为图片。")
        }
        XCTAssertEqual(images, [data])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([url as NSURL]))
        guard case .files(let files) = ClipboardImages.read(from: board) else {
            return XCTFail("访达复制的图片文件应识别为附件。")
        }
        XCTAssertEqual(files.map(\.path), [url.path])
        board.clearContents()
        XCTAssertTrue(board.setString("纯文本保留默认粘贴", forType: .string))
        XCTAssertNil(ClipboardImages.read(from: board))
    }

    func testMarkdownUnderstandsStreamedCodeTablesAndLists() {
        let input = """
            ## 结果
            - [x] 完成
            > 引用内容
            | 角色 | 状态 |
            | --- | :--- |
            | Hermes | **已完成** |
            ```swift
            print("继续流式输出")
            """
        let blocks = MarkdownBlock.parse(input)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks.first, .heading(2, "结果"))
        XCTAssertEqual(blocks[2], .quote("引用内容"))
        XCTAssertEqual(blocks[3], .table([["角色", "状态"], ["Hermes", "**已完成**"]]))
        XCTAssertEqual(blocks.last, .code("swift", "print(\"继续流式输出\")"))
    }

    func testLiveHermesReadsIsolatedMemoryAndResumesAcrossProcesses() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后使用已配置的实际模型验证。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let first = Role(name: "测试 A", summary: "", template: .blank)
        let second = Role(name: "测试 B", summary: "", template: .blank)
        for (role, code) in [(first, "ORBIT-316"), (second, "COMET-825")] {
            try store.create(role, instructions: "收到“发送码”时，回传本角色长期记忆里的发送码。询问“上一条标签”时，先输出上一条用户消息里的标签，再补充项目要求的标识。")
            try store.writeFile(.memory, for: role.id, text: "本角色的发送码是 \(code)。")
        }
        var conversation = Conversation(roleID: first.id)
        let project = try store.createProject(name: "测试项目", directory: nil, for: first.id)
        try Data("当用户询问上一条标签时，在最后另起一行加上 DIR-731。".utf8)
            .write(to: project.directory.appendingPathComponent("AGENTS.md"))
        let (id, reply) = try await ask("发送码。我的标签是 LABEL-592。", in: conversation,
            store: store, runtime: runtime)
        XCTAssertTrue(reply.contains("ORBIT-316"), "角色 A 应能读到自己的记忆。")
        XCTAssertFalse(reply.contains("COMET-825"))
        conversation.sessionID = try XCTUnwrap(id)
        try store.save(conversation)
        let moved = try store.moveConversation(conversation.id, for: first.id, to: project.id)
        XCTAssertEqual(moved.sessionID, conversation.sessionID)

        let (_, secondReply) = try await ask("发送码", in: Conversation(roleID: second.id), store: store, runtime: runtime)
        XCTAssertTrue(secondReply.contains("COMET-825"), "角色 B 应能读到自己的记忆。")
        XCTAssertFalse(secondReply.contains("ORBIT-316"))
        runtime.reset(home: store.runtime(for: first.id))
        let (_, resumedReply) = try await ask(
            "上一条标签是什么？再按当前项目要求补充项目标识。", in: moved, store: store,
            runtime: runtime, workspace: project.directory)
        XCTAssertTrue(resumedReply.contains("LABEL-592"), "新进程应能恢复上一次的对话上下文。")
        XCTAssertTrue(resumedReply.contains("DIR-731"), "项目会话应能读取当前工作目录的项目指令。")
    }

    func testLiveHermesUsesProjectFileAndTerminalToolsAfterResume() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后测试真实的项目工具调用。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "项目工具验证", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let project = try store.createProject(name: "项目工具测试", directory: nil, for: role.id)
        let readMarker = UUID().uuidString
        let terminalMarker = UUID().uuidString
        try Data(readMarker.utf8).write(to: project.directory.appendingPathComponent("read-check.txt"))
        try Data(terminalMarker.utf8).write(to: project.directory.appendingPathComponent("terminal-check.txt"))
        var conversation = Conversation(roleID: role.id)
        conversation.projectID = project.id
        let home = store.runtime(for: role.id)
        runtime.warm(home: home, conversation: nil)

        var fileResult = false
        let (id, _) = try await ask(
            "请直接调用 read_file 读取相对路径 ./read-check.txt，然后原样回复文件内容。",
            in: conversation, store: store, runtime: runtime, workspace: project.directory
        ) { tool in
            if tool.title?.hasPrefix("read_file:") == true, tool.status == "completed",
                tool.details?.contains(readMarker) == true { fileResult = true }
        }
        XCTAssertTrue(fileResult, "新建项目会话应通过文件工具读取项目相对路径。")

        conversation.sessionID = try XCTUnwrap(id)
        runtime.reset(home: home)
        var terminalResult = false
        _ = try await ask(
            "请直接调用 terminal 执行 cat ./terminal-check.txt，不指定工作目录，然后原样回复输出。",
            in: conversation, store: store, runtime: runtime, workspace: project.directory
        ) { tool in
            if tool.title?.hasPrefix("terminal:") == true, tool.status == "completed",
                tool.details?.contains(terminalMarker) == true { terminalResult = true }
        }
        XCTAssertTrue(terminalResult, "恢复项目会话后，终端应在项目工作目录运行。")
    }

    func testLiveHermesRestoresNativeTerminalAndWebInAnOldUnscopedConversation() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后验证旧对话的原生终端和网页读取。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "原生工具验证", summary: "", template: .blank)
        try store.create(role, instructions: "")
        let home = store.runtime(for: role.id)
        let workspace = home.appendingPathComponent("workspace")
        let configURL = home.appendingPathComponent("config.yaml")
        let environment = try runtime.prepare(home: home, withVision: true, skillIDs: nil, draft: false)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL))
        var oldConfig = try XCTUnwrap(raw as? [String: Any])
        oldConfig["platform_toolsets"] = ["acp": ["memory", "session_search"]]
        oldConfig.removeValue(forKey: "security")
        try JSONSerialization.data(withJSONObject: oldConfig).write(to: configURL, options: .atomic)

        let oldWorker = runtime.process(arguments: ["acp"], directory: workspace, overrides: environment)
        let input = Pipe()
        let output = Pipe()
        oldWorker.standardInput = input
        oldWorker.standardOutput = output
        try oldWorker.run()
        defer { if oldWorker.isRunning { oldWorker.terminate() } }
        let oldACP = ACPConnection(input: input.fileHandleForWriting, output: output.fileHandleForReading)
        _ = try oldACP.call("initialize", parameters: ["protocolVersion": 1, "clientCapabilities": [:]])
        let old = try oldACP.call("session/new", parameters: ["cwd": workspace.path, "mcpServers": []])
        var conversation = Conversation(roleID: role.id)
        conversation.sessionID = try XCTUnwrap(old["sessionId"] as? String)
        oldWorker.terminate()

        let control = TurnControl()
        let timeout = Task {
            try await Task.sleep(for: .seconds(95))
            control.cancel()
        }
        defer {
            timeout.cancel()
            runtime.reset(home: home)
        }
        var terminal = false
        var web = false
        var reply = ""
        var tools: [String: ToolRun] = [:]
        let prompt = "请调用 terminal 运行 pwd，再调用原生 web_extract 读取 https://example.com/，最后原样输出读到的网页英文标题。请实际调用这两个工具。"
        for await event in runtime.turn(home: home, conversation: conversation, text: prompt,
            interactive: true, control: control) {
            switch event {
            case .permission(let request):
                _ = control.respond(to: request.id, optionID: request.options.first { $0.kind == "allow_once" }?.id)
            case .tool(let update):
                let tool = tools[update.id]?.updating(with: update) ?? update
                tools[tool.id] = tool
                if tool.status == "completed" {
                    let title = tool.title ?? ""
                    let details = tool.details ?? ""
                    terminal = terminal || (title.hasPrefix("terminal") && details.contains("/workspace"))
                    web = web || title.hasPrefix("web_extract")
                }
            case .text(let text, _): reply += text
            case .session:
                XCTFail("应恢复旧的 Hermes 会话。")
            case .finished(let reason): XCTAssertEqual(reason, "end_turn")
            case .failed(let message): throw StudioError.message(message)
            default: break
            }
        }
        let calls = tools.values.map {
            "\($0.title ?? "未知工具") [\($0.status ?? "")] \($0.details?.prefix(250) ?? "")"
        }.sorted()
        XCTAssertTrue(terminal, calls.joined(separator: "，"))
        XCTAssertTrue(web, calls.joined(separator: "，"))
        XCTAssertTrue(reply.localizedCaseInsensitiveContains("Example Domain"), reply)
    }

    func testLiveHermesLoadsSelectedSkill() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_LIVE_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_LIVE_TEST=1 后测试真实技能调用。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        guard let skill = runtime.installedSkills().first(where: { $0.name == "project-readme-and-docs" }) else {
            throw XCTSkip("本机未安装验证所用的技能。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "技能验证", summary: "", template: .blank)
        try store.create(role, instructions: "只做技能加载验证，请勿运行命令、访问网络或修改文件。")
        let control = TurnControl()
        let timeout = Task {
            try await Task.sleep(for: .seconds(65))
            control.cancel()
        }
        defer { timeout.cancel() }
        var finished = false
        var loadedSkill = false
        for await event in runtime.turn(home: store.runtime(for: role.id), conversation: Conversation(roleID: role.id),
            text: "请调用 skill_view 读取选中的技能，读取后只回复已加载。", skill: skill, skillIDs: [skill.id], control: control) {
            switch event {
            case .tool(let tool):
                if tool.status == "completed" { loadedSkill = true }
            case .finished(let reason): finished = reason == "end_turn"
            case .failed(let message): throw StudioError.message(message)
            default: break
            }
        }
        XCTAssertTrue(finished)
        XCTAssertTrue(loadedSkill, "应收到 Hermes 的真实工具完成事件。")
    }

    func testLiveHermesAcceptsImageInput() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_STUDIO_VISION_TEST"] == "1" else {
            throw XCTSkip("设置 HERMES_STUDIO_VISION_TEST=1 后使用具有视觉能力的模型测试。")
        }
        let runtime = try XCTUnwrap(HermesRuntime.discover())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "图片验证", summary: "", template: .blank)
        try store.create(role, instructions: "请根据实际看到的图片回答。")
        let (_, reply) = try await ask("图片中央是什么颜色？用中文只回答颜色。", in: Conversation(roleID: role.id),
            store: store, runtime: runtime, images: [try makeRedImage()])
        XCTAssertTrue(reply.contains("红"), "默认模型需要具备视觉能力，才能识别测试图中的颜色。")
    }

    private func ask(
        _ text: String, in conversation: Conversation, store: RoleStore, runtime: HermesRuntime,
        workspace: URL? = nil, images: [ImagePayload] = [], onTool: (ToolRun) -> Void = { _ in }
    ) async throws -> (String?, String) {
        let control = TurnControl()
        let timeout = Task {
            try await Task.sleep(for: .seconds(55))
            control.cancel()
        }
        defer { timeout.cancel() }
        var sessionID: String?
        var reply = ""
        var tools: [String: ToolRun] = [:]
        for await event in runtime.turn(home: store.runtime(for: conversation.roleID), conversation: conversation,
            text: text, images: images, workspace: workspace, control: control) {
            switch event {
            case .session(let id): sessionID = id
            case .text(let text, _): reply += text
            case .finished(let reason):
                XCTAssertEqual(reason, "end_turn")
            case .failed(let message): throw StudioError.message(message)
            case .tool(let tool):
                let updated = tools[tool.id]?.updating(with: tool) ?? tool
                tools[tool.id] = updated
                onTool(updated)
            case .activity, .image, .permission, .permissionExpired, .followUpReady, .followUpStarted, .followUpRejected,
                .runSettings, .insertionReady, .insertionAccepted, .insertionDeferred, .insertionFailed: break
            }
        }
        return (sessionID, reply)
    }

    private func makeRedImage() throws -> ImagePayload {
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 160, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        let bytes = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return try ImagePayload.prepare(name: "红色.png", data: bytes as Data)
    }
}
