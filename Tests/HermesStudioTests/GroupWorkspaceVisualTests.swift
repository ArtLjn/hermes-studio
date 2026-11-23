import AppKit
import StudioCore
import SwiftUI
import XCTest
@testable import HermesStudio

final class GroupWorkspaceVisualTests: XCTestCase {
    @MainActor
    func testGroupHistoryPreviewKeepsFiveRowsAndRetainsOlderSelection() {
        var threads = (1...12).map { index in
            GroupDiscussion(title: "对话 \(index)", goal: "", memberIDs: [])
        }
        XCTAssertEqual(GroupWorkspace.recentThreads(threads, selectedID: nil).map(\.id), Array(threads.prefix(5).map(\.id)))
        let older = GroupWorkspace.recentThreads(threads, selectedID: threads[9].id)
        XCTAssertEqual(older.map(\.id), Array(threads.prefix(4).map(\.id)) + [threads[9].id])
        XCTAssertEqual(GroupWorkspace.recentThreads(Array(threads.prefix(2)), selectedID: UUID()).count, 2)
        threads[8].pinnedAt = Date()
        let pinned = GroupWorkspace.recentThreads(threads, selectedID: threads[8].id)
        XCTAssertEqual(pinned.map(\.id), [threads[8].id] + Array(threads.prefix(5).map(\.id)))
    }

    @MainActor
    func testGroupWorkspaceRendersAtWideAndCompactSizes() async throws {
        guard let output = ProcessInfo.processInfo.environment["HERMES_STUDIO_GROUP_VISUALS"] else {
            throw XCTSkip("设置 HERMES_STUDIO_GROUP_VISUALS 为截图输出目录。")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let a = Role(name: "通用协作", summary: "梳理目标和工作分工", template: .general)
        let b = Role(name: "研发搭档", summary: "分析改动并核对交付", template: .engineering)
        let c = Role(name: "写作编辑", summary: "整理说明和发布公告", template: .writing)
        let d = Role(name: "体验顾问", summary: "检查设置和对话是否容易使用", template: .general)
        for role in [a, b, c, d] { try roles.create(role, instructions: "") }
        let groups = GroupDiscussionStore(root: root)
        var group = GroupDiscussion(title: "新版交付前核对", goal: "核对小范围试用的检查项与对外说明",
            memberIDs: [a.id, b.id, c.id])
        group.relayLimit = 2
        var behavior = GroupMemberChatPreferences()
        behavior.initiative = .proactive
        behavior.tone = .cool
        behavior.intensity = .vivid
        group.memberChatPreferences = [b.id: behavior]
        group.turns = [GroupTurn(role: a, question: "列出试用前需要核对的两项内容，请研发搭档继续。")]
        group.recordReply("""
            建议先确认**旧记录能正常打开**，再验证**三位助手可以顺序接力**。研发搭档负责核对结果，写作编辑整理用户可读的更新说明。
            @研发搭档 核对旧记录和接力结果，标出需要写进说明的事项。
            """, at: 0, activeMembers: [a, b, c])
        group.recordReply("""
            两项检查均已通过。建议说明里加入「输入 @ 选择发言人」和「暂停队列后可继续」这两条操作。
            [[接力 \(c.id)]] 根据前两位的结果，准备三句话的更新说明。
            """, at: 1, activeMembers: [a, b, c])
        group.recordReply("更新说明已整理。", at: 2, activeMembers: [a, b, c])
        group.relayLimit = 0
        group.turns.append(GroupTurn(role: a, question: "谢谢，也帮我看一下发布节奏。"))
        group.recordReply("可以，先让小范围用户试用。\n@研发搭档 看一下试用后的验收时间。", at: 3, activeMembers: [a, b, c])
        try groups.save(group)
        for (index, title) in ["发布说明草稿", "试用反馈整理", "回滚流程复核", "发布节奏", "窗口尺寸测试", "更新通知"].enumerated() {
            var draft = GroupDiscussion(title: group.title, goal: group.goal, memberIDs: group.memberIDs)
            draft.parentGroupID = group.id
            draft.conversationTitle = title
            draft.updated = group.updated.addingTimeInterval(-60 * Double(index + 1))
            if index == 5 { draft.pinnedAt = Date() }
            try groups.save(draft)
        }
        var anotherGroup = GroupDiscussion(title: "周末闲聊", goal: "", memberIDs: [a.id, c.id])
        anotherGroup.updated = group.updated.addingTimeInterval(-120)
        try groups.save(anotherGroup)
        let proposal = try groups.propose(authorID: a.id, title: "下一轮试用评审", goal: "准备检查清单和使用说明",
            members: [(b.id, "复核队列取消和旧记录保留"), (c.id, "整理给试用团队的操作说明")],
            firstTask: "先汇总需要在试用前走通的关键路径。", using: roles)
        let studio = StudioModel(dataStore: roles,
            runtime: HermesRuntime(executable: URL(fileURLWithPath: "/usr/bin/false")), runPreferences: .init())
        studio.groupWorkspace.drafts[group.id] = GroupComposerDraft(recipient: .members([a.id, b.id]))
        let workspace = GroupWorkspace(studio: studio, model: studio.groupWorkspace)
        _ = NSApplication.shared
        try await render(workspace, size: CGSize(width: 1140, height: 740), into: directory.appendingPathComponent("群聊-宽窗口.png"))
        try await render(workspace, size: CGSize(width: 706, height: 570), into: directory.appendingPathComponent("群聊-窄窗口.png"))
        let controls = HStack(spacing: 10) {
            Label("停止回复", systemImage: "stop")
            Label("暂停队列", systemImage: "pause")
        }.font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
        let expanded = GroupReplyProgressStack(entries: [
            .init(id: a.id, role: a, name: a.name, activity: "正在回复"),
            .init(id: b.id, role: b, name: b.name, activity: "排队中", waiting: true, cancel: {}),
            .init(id: c.id, role: c, name: c.name, activity: "排队中", waiting: true, cancel: {})
        ], store: roles, expanded: .constant(true), controls: controls)
        try await render(expanded.padding(10), size: CGSize(width: 460, height: 128),
            into: directory.appendingPathComponent("群聊-进度展开.png"))
        let collapsed = GroupReplyProgressStack(entries: expanded.entries, store: roles, expanded: .constant(false), controls: controls)
        try await render(collapsed.padding(10), size: CGSize(width: 460, height: 46),
            into: directory.appendingPathComponent("群聊-进度折叠.png"))
        try await render(GroupHistorySheet(groupName: group.title,
            threads: studio.groupWorkspace.discussions.filter { $0.groupID == group.id }, selectedID: group.id) { _ in },
            size: CGSize(width: 400, height: 400), into: directory.appendingPathComponent("群聊-全部对话.png"))
        XCTAssertTrue(studio.groupWorkspace.setConversationArchived(anotherGroup.id, archived: true))
        try await render(GroupArchiveSheet(model: studio.groupWorkspace) { _ in },
            size: CGSize(width: 400, height: 400), into: directory.appendingPathComponent("群聊-已归档对话.png"))
        try await render(GroupEditor(source: .proposal(proposal), studio: studio, model: studio.groupWorkspace) { _ in },
            size: CGSize(width: 528, height: 595), into: directory.appendingPathComponent("群聊-建群提案.png"))
        try await render(GroupEditor(source: .settings(group), studio: studio, model: studio.groupWorkspace) { _ in },
            size: CGSize(width: 528, height: 490), into: directory.appendingPathComponent("群聊-成员设置.png"))
        studio.groupWorkspace.fullAccess = true
        try await render(GroupEditor(source: .settings(group), studio: studio, model: studio.groupWorkspace, page: .chat) { _ in },
            size: CGSize(width: 528, height: 550), into: directory.appendingPathComponent("群聊-聊天规则.png"))
        try await render(GroupEditor(source: .settings(group), studio: studio, model: studio.groupWorkspace, page: .tools) { _ in },
            size: CGSize(width: 528, height: 490), into: directory.appendingPathComponent("群聊-工具权限.png"))
        try await render(GroupMemberBehaviorEditor(role: b, store: roles, settings: .constant(behavior)),
            size: CGSize(width: 340, height: 300), into: directory.appendingPathComponent("群聊-成员个性.png"))
    }

    @MainActor
    func testGroupSettingsScrollOnlyTheMemberList() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let roles = try (1...9).map { number in
            let role = Role(name: "助手 \(number)", summary: "负责整理会议行动项", template: .general)
            try store.create(role, instructions: "")
            return role
        }
        let group = GroupDiscussion(title: "群聊设置测试", goal: "核对成员列表", memberIDs: roles.prefix(2).map(\.id))
        let studio = StudioModel(dataStore: store,
            runtime: HermesRuntime(executable: URL(fileURLWithPath: "/usr/bin/false")), runPreferences: .init())
        let settings = GroupEditor(source: .settings(group), studio: studio, model: studio.groupWorkspace) { _ in }
        let snapshot = ProcessInfo.processInfo.environment["HERMES_STUDIO_GROUP_VISUALS"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("群聊-设置成员滚动区.png")
        }
        try await render(settings, size: CGSize(width: 528, height: 455), into: snapshot) { view in
            let scroll = try XCTUnwrap(self.overflowingScrollView(in: view))
            let clip = scroll.contentView
            let viewport = scroll.convert(scroll.bounds, to: view)
            XCTAssertEqual(viewport.height, 188, accuracy: 1)
            XCTAssertGreaterThan(viewport.minY, 65)
            XCTAssertLessThan(viewport.maxY, view.bounds.height - 65)
            let document = try XCTUnwrap(scroll.documentView)
            let bottom = document.frame.height - clip.bounds.height
            clip.scroll(to: CGPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(clip)
            XCTAssertGreaterThan(clip.bounds.minY, 0)
        }
    }

    private func overflowingScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView,
            let document = scroll.documentView, document.frame.height > scroll.contentSize.height + 1 { return scroll }
        return view.subviews.lazy.compactMap { self.overflowingScrollView(in: $0) }.first
    }

    @MainActor
    func testLongHandoffKeepsItsSendStatusAboveTheComposer() async throws {
        guard let output = ProcessInfo.processInfo.environment["HERMES_STUDIO_GROUP_VISUALS"] else {
            throw XCTSkip("设置 HERMES_STUDIO_GROUP_VISUALS 为截图输出目录。")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let a = Role(name: "研发搭档", summary: "", template: .engineering)
        let b = Role(name: "写作编辑", summary: "", template: .writing)
        for role in [a, b] { try roles.create(role, instructions: "") }
        let brief = (1...18).map { "\($0). 整理对应的试用核对项和用户可见的操作说明。" }.joined(separator: "\n")
        var task = Message(.user, "把检查清单交给写作编辑整理发布说明。")
        task.handoff = RoleHandoff(target: b)
        task.handoff?.brief = brief
        var chat = Conversation(roleID: a.id)
        chat.messages = [task, Message(.assistant, brief)]
        try roles.save(chat)
        let studio = StudioModel(dataStore: roles,
            runtime: HermesRuntime(executable: URL(fileURLWithPath: "/usr/bin/false")), runPreferences: .init())
        studio.select(a)
        studio.select(chat)
        _ = NSApplication.shared
        try await render(ChatPane(studio: studio), size: CGSize(width: 660, height: 530),
            into: directory.appendingPathComponent("交接-待发送.png"))
    }

    @MainActor
    private func render<Content: View>(_ content: Content, size: CGSize, into output: URL?,
        check: (NSView) throws -> Void = { _ in }) async throws {
        let bounds = CGRect(origin: .zero, size: size)
        let hosting = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .foregroundStyle(StudioPalette.ink)
            .background(StudioPalette.background)
            .tint(StudioPalette.accent)
            .preferredColorScheme(.dark))
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(180))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        if let output {
            let representation = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: bounds))
            hosting.cacheDisplay(in: bounds, to: representation)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(to: output, options: .atomic)
        }
        try check(hosting)
    }
}
