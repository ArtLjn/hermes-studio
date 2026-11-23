import Foundation
import XCTest
@testable import StudioCore

final class GroupDiscussionTests: XCTestCase {
    func testUserCenteredChatReturnsTheFloorToUserAndPersistsFocus() throws {
        let members = ["甲", "乙", "丙"].map { Role(name: $0, summary: "", template: .blank) }
        var group = GroupDiscussion(title: "陪伴", goal: "", memberIDs: members.map(\.id))
        group.chatActivity = .lively
        group.casualReplyLimit = 30
        group.addTopic("你们都不关心我", attachments: [], activeMembers: members)
        group.recordReply("刚才把你晾着了，你现在想聊什么？", at: 0, activeMembers: members)
        XCTAssertEqual(group.turns.count, 1)
        group.addTopic("今天真的好累", attachments: [], activeMembers: members)
        group.recordReply("先在这儿歇一会儿。", at: 1, activeMembers: members)
        XCTAssertEqual(group.turns.count, 3)
        XCTAssertTrue(group.prompt(for: 2, members: members).contains("这次直接对用户说话"))
        group.recordReply("我在，慢慢说。", at: 2, activeMembers: members)
        XCTAssertEqual(group.turns.count, 3)
        group.chatFocus = .free
        let loaded = try JSONDecoder().decode(GroupDiscussion.self, from: JSONEncoder().encode(group))
        var child = GroupDiscussion(title: "子会话", goal: "", memberIDs: [])
        child.inheritGroupSettings(from: loaded)
        XCTAssertEqual(child.effectiveChatFocus, .free)
    }

    func testDefaultMembersCanConverseWithoutEveryoneEchoingAndStopAtBudget() throws {
        let members = ["甲", "乙", "丙"].map { Role(name: $0, summary: "", template: .blank) }
        var group = GroupDiscussion(title: "闲聊", goal: "", memberIDs: members.map(\.id))
        XCTAssertEqual(group.casualMessagesPerTopic, 3)
        group.addTopic("今天好累", attachments: [], activeMembers: members)
        group.recordReply("先坐下歇一会儿。", at: 0, activeMembers: members)
        XCTAssertEqual(group.turns.count, 2)
        XCTAssertEqual(group.turns[1].requesterID, members[0].id)
        XCTAssertTrue(group.turns[1].mayPass == true)
        group.recordReply("给你留了个靠窗的位置。", at: 1, activeMembers: members)
        XCTAssertEqual(group.turns.count, 2)

        group.chatActivity = .lively
        group.casualReplyLimit = nil
        group.chatFocus = .free
        XCTAssertEqual(group.casualMessagesPerTopic, 5)
        group.addTopic("周末去哪玩？", attachments: [], activeMembers: members)
        for index in 2..<7 { group.recordReply("接着聊一个具体细节。", at: index, activeMembers: members) }
        XCTAssertEqual(group.turns.count, 7)
        XCTAssertNil(group.queuedTurnIndex())
    }

    func testClosingsAndNewMessagesStopOldAutomaticConversation() throws {
        let members = ["甲", "乙"].map { Role(name: $0, summary: "", template: .blank) }
        var group = GroupDiscussion(title: "闲聊", goal: "", memberIDs: members.map(\.id))
        group.chatActivity = .lively
        group.chatFocus = .free
        group.addTopic("谢谢大家！", attachments: [], activeMembers: members)
        group.recordReply("不客气。", at: 0, activeMembers: members)
        XCTAssertEqual(group.turns.count, 1)
        group.addTopic("聊聊周末", attachments: [], activeMembers: members)
        group.recordReply("去海边吗？", at: 1, activeMembers: members)
        XCTAssertEqual(group.turns[2].kind, .reaction)
        group.addTopic("先停一下，说个别的", attachments: [], activeMembers: members)
        group.supersedeAutomaticReplies()
        XCTAssertEqual(group.turns[2].state, .cancelled)
        XCTAssertEqual(group.turns.last?.state, .queued)
        group.recordReply("旧话题里还想再问一句？", at: 2, activeMembers: members)
        XCTAssertEqual(group.turns.count, 4)
    }

    func testPooledRuntimeSharesThreadsButSeparatesGroupsRolesAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = GroupDiscussionStore(root: root)
        let role = Role(name: "甲", summary: "", template: .blank)
        var group = GroupDiscussion(title: "闲聊", goal: "", memberIDs: [role.id])
        var child = GroupDiscussion(title: "新会话", goal: "", memberIDs: [role.id])
        child.parentGroupID = group.id
        let home = store.pooledRuntimeStore(for: group, role: role, fullAccess: true).runtime(for: role.id)
        XCTAssertEqual(home, store.pooledRuntimeStore(for: child, role: role, fullAccess: true).runtime(for: role.id))
        XCTAssertNotEqual(home, store.pooledRuntimeStore(for: group, role: role, fullAccess: false).runtime(for: role.id))
        group.toolPermissions = GroupToolPermissions()
        group.toolPermissions?.terminal = false
        XCTAssertNotEqual(home, store.pooledRuntimeStore(for: group, role: role, fullAccess: true).runtime(for: role.id))
        child.parentGroupID = nil
        XCTAssertNotEqual(home, store.pooledRuntimeStore(for: child, role: role, fullAccess: true).runtime(for: role.id))
    }

    func testGroupToolSelectionIsInheritedAndPreservesLegacyFullAccess() throws {
        var group = GroupDiscussion(title: "工作", goal: "", memberIDs: [])
        XCTAssertNil(GroupToolPermissions().toolsets)
        var settings = GroupToolPermissions()
        settings.terminal = false
        settings.browser = false
        settings.externalMCP = false
        settings.skills = false
        XCTAssertEqual(settings.toolsets, ["file", "web"])
        group.toolPermissions = settings
        var thread = GroupDiscussion(title: "子对话", goal: "", memberIDs: [])
        thread.inheritGroupSettings(from: try JSONDecoder().decode(GroupDiscussion.self, from: JSONEncoder().encode(group)))
        XCTAssertEqual(thread.toolPermissions, settings)
    }
    func testIdleBudgetAndGroupPermissionSurviveReload() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 14))!
        let role = Role(name: "暖暖", summary: "", template: .blank)
        var group = GroupDiscussion(title: "聊天", goal: "", memberIDs: [role.id])
        group.idleChatMinutes = 15
        group.allowsFullAccess = false
        var user = GroupTurn(role: role, question: "午饭吃了面")
        user.created = now.addingTimeInterval(-1200)
        user.state = .completed
        group.turns = [user]
        group.updated = user.created
        XCTAssertTrue(group.canStartIdleTopic(now: now, groupTurns: group.turns, allTurns: group.turns, calendar: calendar))
        XCTAssertTrue(group.addIdleTopic(now: now, activeMembers: [role]))
        group.recordReply("那家面的汤怎么样？\n@暖暖 要不要再说说？", at: 1, activeMembers: [role])
        XCTAssertEqual(group.turns.count, 2)
        XCTAssertFalse(group.canStartIdleTopic(now: now.addingTimeInterval(1800),
            groupTurns: group.turns, allTurns: group.turns, calendar: calendar))
        var thread = GroupDiscussion(title: "新对话", goal: "", memberIDs: [])
        thread.inheritGroupSettings(from: try JSONDecoder().decode(GroupDiscussion.self, from: JSONEncoder().encode(group)))
        XCTAssertFalse(thread.usesFullAccess(global: true))
        XCTAssertEqual(thread.effectiveIdleDailyLimit, 1)
        XCTAssertFalse(thread.usesFullAccess(global: false))
        let otherRequests = Array(repeating: group.turns[1], count: 3)
        XCTAssertFalse(group.canStartIdleTopic(now: now, groupTurns: [user], allTurns: otherRequests, calendar: calendar))
        XCTAssertFalse(group.canStartIdleTopic(now: now.addingTimeInterval(3600),
            groupTurns: [user], allTurns: [], calendar: calendar))
    }

    func testNaturalChatDoesNotScheduleAnAudienceForEveryMessage() {
        let members = ["暖暖", "糖糖"].map { Role(name: $0, summary: "", template: .blank) }
        var group = GroupDiscussion(title: "聊天", goal: "", memberIDs: members.map(\.id))
        group.addTopic("今天吃了面", attachments: [], activeMembers: members)
        group.recordReply("哪家的？", at: 0, activeMembers: members)
        XCTAssertEqual(group.turns.count, 1)
        XCTAssertNil(group.queuedTurnIndex())
    }
    func testGroupMemoryIsSharedAcrossThreadsAndRequiresAnExplicitRunningTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let a = Role(name: "暖暖", summary: "", template: .general)
        let b = Role(name: "刺梨", summary: "", template: .writing)
        let outsider = Role(name: "其他", summary: "", template: .writing)
        for role in [a, b, outsider] { try roles.create(role, instructions: "") }
        let groups = GroupDiscussionStore(root: root)
        let group = GroupDiscussion(title: "协作群", goal: "", memberIDs: [a.id, b.id])
        var child = GroupDiscussion(title: group.title, goal: "", memberIDs: group.memberIDs)
        child.parentGroupID = group.id
        child.conversationTitle = "决定记录"
        child.addTopic("请记住：周报在星期五发", attachments: [], activeMembers: [a, b], remembers: true)
        child.turns[0].state = .running
        try groups.save(group)
        try groups.save(child)
        let scope = GroupToolScope(threadID: child.id, turnID: child.turns[0].id)
        let collaboration = GroupCollaboration(roles: roles)
        XCTAssertTrue(GroupCollaboration.requestsMemory("记住：周报在星期五发"))
        XCTAssertFalse(GroupCollaboration.requestsMemory("你还记得以前的群记忆吗？"))
        XCTAssertThrowsError(try collaboration.saveMemory(title: "周报", text: "星期三", from: b.id, scope: scope))
        let saved = try collaboration.saveMemory(title: "周报时间", text: "星期五发送", from: a.id, scope: scope)
        let repeatSave = try collaboration.saveMemory(title: "周报时间", text: "星期三发送", from: a.id, scope: scope)
        XCTAssertEqual(repeatSave.text, saved.text)
        XCTAssertEqual(try collaboration.searchMemory(for: b.id, threadID: group.id, query: "周报", limit: 4).map(\.text),
            ["星期五发送"])
        XCTAssertTrue(try collaboration.searchMemory(for: outsider.id, threadID: nil, query: "", limit: 8).isEmpty)
        XCTAssertThrowsError(try collaboration.searchMemory(for: outsider.id, threadID: group.id, query: "", limit: 8))
        XCTAssertFalse(child.prompt(for: 0, members: [a, b], groupMemoryAvailable: true).contains(saved.title))
        XCTAssertTrue(child.prompt(for: 0, members: [a, b], groupMemoryAvailable: true).contains("search_group_memory"))
    }

    func testScopedGroupToolsAcceptOnlyTargetsAndLinksFromTheCurrentTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let caller = Role(name: "暖暖", summary: "", template: .general)
        let invitee = Role(name: "刺梨", summary: "", template: .general)
        let other = Role(name: "糖糖", summary: "", template: .writing)
        for role in [caller, invitee, other] { try roles.create(role, instructions: "") }
        let text = "你们谁把刺梨邀请进来"
        XCTAssertEqual(try GroupCollaboration.inviteTargets(in: text, roles: [caller, invitee, other]).map(\.id), [invitee.id])
        XCTAssertTrue(try GroupCollaboration.inviteTargets(in: "不要把刺梨邀请进来", roles: [invitee]).isEmpty)
        XCTAssertEqual(try GroupCollaboration.inviteTargets(in: "谁邀请下刺梨", roles: [invitee]).map(\.id), [invitee.id])
        XCTAssertEqual(try GroupCollaboration.inviteTargets(in: "帮我邀请一下刺梨进群", roles: [invitee]).map(\.id), [invitee.id])
        let link = try XCTUnwrap(GroupSharedPage.requestedURL(in: "http://localhost:4173/?view=feed 打开"))
        XCTAssertEqual(link.absoluteString, "http://localhost:4173/?view=feed")
        XCTAssertNil(GroupSharedPage.requestedURL(in: "不要打开 http://localhost:4173/"))
        XCTAssertNil(GroupSharedPage.requestedURL(in: "打开 https://user:pass@example.test/"))

        let groups = GroupDiscussionStore(root: root)
        var group = GroupDiscussion(title: "联调群", goal: "", memberIDs: [caller.id, other.id])
        group.addTopic(text, attachments: [], activeMembers: [caller, other], invitationTargets: [invitee.id])
        group.turns[0].state = .running
        try groups.save(group)
        let scope = GroupToolScope(threadID: group.id, turnID: group.turns[0].id)
        let collaboration = GroupCollaboration(roles: roles)
        XCTAssertEqual(try collaboration.memberships(for: caller.id, scope: scope).count, 1)
        XCTAssertThrowsError(try collaboration.memberships(for: invitee.id, scope: scope))
        XCTAssertThrowsError(try collaboration.stageInvitation(other.id, from: caller.id, scope: scope))
        XCTAssertThrowsError(try collaboration.stageInvitation(invitee.id, from: other.id, scope: scope))
        XCTAssertThrowsError(try collaboration.sharedPageURL(for: caller.id, scope: scope))
        _ = try collaboration.stageInvitation(invitee.id, from: caller.id, scope: scope)
        _ = try collaboration.stageInvitation(invitee.id, from: caller.id, scope: scope)
        XCTAssertEqual(collaboration.requestedInvitations([invitee.id, other.id], scope: scope), [invitee.id])
        collaboration.finishInvitations(scope: scope)
        XCTAssertTrue(collaboration.requestedInvitations([invitee.id], scope: scope).isEmpty)
        group.turns[0].state = .completed
        try groups.save(group)
        XCTAssertThrowsError(try collaboration.stageInvitation(invitee.id, from: caller.id, scope: scope))
        group.turns[0].sharedLink = link.absoluteString
        group.turns[0].state = .running
        try groups.save(group)
        XCTAssertEqual(try collaboration.sharedPageURL(for: caller.id, scope: scope), link)
        var callerSettings = GroupMemberChatPreferences()
        var disabled = GroupToolPermissions()
        disabled.invitations = false
        disabled.sharedLinks = false
        callerSettings.toolPermissions = disabled
        group.memberChatPreferences = [caller.id: callerSettings]
        try groups.save(group)
        XCTAssertThrowsError(try collaboration.stageInvitation(invitee.id, from: caller.id, scope: scope))
        XCTAssertThrowsError(try collaboration.sharedPageURL(for: caller.id, scope: scope))
        XCTAssertFalse(group.addDirectedMessage("读取链接", attachments: [], to: [caller.id],
            activeMembers: [caller, other], sharedLink: link))
        XCTAssertTrue(group.addTopic("读取链接", attachments: [], activeMembers: [caller, other], sharedLink: link))
        XCTAssertEqual(group.turns.last?.roleID, other.id)
        XCTAssertTrue(group.permissions(for: other.id).sharedLinks)
        group.toolPermissions = disabled
        XCTAssertFalse(group.permissions(for: other.id).sharedLinks)
        try groups.save(group)
        XCTAssertThrowsError(try collaboration.stageInvitation(invitee.id, from: caller.id, scope: scope))
        XCTAssertThrowsError(try collaboration.sharedPageURL(for: caller.id, scope: scope))
    }

    func testCustomReplyLimitAlsoBoundsParallelOpeners() {
        let a = Role(name: "暖暖", summary: "", template: .general)
        let b = Role(name: "糖糖", summary: "", template: .writing)
        let members = [a, b]
        var group = GroupDiscussion(title: "聊天", goal: "", memberIDs: members.map(\.id))
        group.replyMode = .parallel
        group.casualReplyLimit = 1
        group.addTopic("大家好", attachments: [], activeMembers: members)
        group.recordReply("你好。", at: 0, activeMembers: members)
        XCTAssertEqual(group.turns.count, 1)
        group.turns = []
        group.replyMode = .natural
        group.chatActivity = .lively
        group.casualReplyLimit = 9
        group.chatFocus = .free
        group.addTopic("大家好", attachments: [], activeMembers: members)
        for index in 0..<9 {
            guard index < group.turns.count else { return XCTFail("自定义上限提前停止") }
            group.recordReply("第 \(index + 1) 条", at: index, activeMembers: members)
        }
        XCTAssertEqual(group.turns.count, 9)
    }
    func testGroupChatSearchRespectsMembershipAndParticipation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GroupDiscussionStore(root: root)
        let warm = Role(name: "暖暖", summary: "", template: .general)
        let sweet = Role(name: "糖糖", summary: "", template: .writing)
        var group = GroupDiscussion(title: "闲聊群", goal: "", memberIDs: [warm.id, sweet.id])
        group.chatActivity = .lively
        group.casualReplyLimit = 2
        group.turns.append(GroupTurn(role: warm, question: "糖糖还没参与的话题"))
        group.recordReply("只对暖暖说的内容", at: 0, activeMembers: [warm, sweet])
        group.addTopic("大家聊了番茄牛肉面", attachments: [], activeMembers: [warm, sweet])
        group.recordReply("听起来很想吃", at: 1, activeMembers: [warm, sweet])
        group.recordReply("暖暖觉得挺好", at: 2, activeMembers: [warm, sweet])
        try store.save(group)

        let visible = try store.searchChat(for: sweet.id)
        XCTAssertEqual(visible.map(\.text), ["大家聊了番茄牛肉面", "听起来很想吃", "暖暖觉得挺好"])
        XCTAssertEqual(try store.searchChat(for: sweet.id, matching: "暖暖").map(\.text), ["听起来很想吃", "暖暖觉得挺好"])
        var conversation = Conversation(roleID: sweet.id)
        let roles = [warm, sweet]
        let question = "刚才暖暖不会生我气吧"
        let prompt = try XCTUnwrap(GroupChatRecall.prompt(for: question, in: conversation, roles: roles, discussions: [group]))
        XCTAssertTrue(prompt.contains("番茄牛肉面"))
        XCTAssertFalse(prompt.contains("只对暖暖说的内容"))
        conversation.messages = [Message(.user, question), Message(.assistant, "旧版回答"), Message(.tool, "私聊日志")]
        let followUp = try XCTUnwrap(GroupChatRecall.prompt(for: "行啊", in: conversation, roles: roles, discussions: [group]))
        XCTAssertTrue(followUp.contains(question) && followUp.contains("番茄牛肉面"))
        XCTAssertFalse(followUp.contains("私聊日志") || followUp.contains("旧版回答"))
        XCTAssertNil(GroupChatRecall.prompt(for: "帮我创建一个群聊", in: conversation, roles: roles, discussions: [group]))
        XCTAssertNil(GroupChatRecall.prompt(for: "刚才我和暖暖私聊了什么", in: conversation, roles: roles, discussions: [group]))
        let stale = try XCTUnwrap(GroupChatRecall.prompt(for: question, in: conversation, roles: roles,
            discussions: [group], now: Date().addingTimeInterval(3 * 3600)))
        XCTAssertTrue(stale.hasSuffix("[]"))

        group.memberIDs = [warm.id]
        try store.save(group)
        XCTAssertTrue(try store.searchChat(for: sweet.id).isEmpty)
    }

    func testCasualTopicCanAlternateFourTimesAndToolMarkupStopsContinuation() {
        let warm = Role(name: "暖暖", summary: "", template: .general)
        let sweet = Role(name: "糖糖", summary: "", template: .writing)
        let members = [warm, sweet]
        var group = GroupDiscussion(title: "闲聊", goal: "", memberIDs: members.map(\.id))
        group.replyMode = .sequential
        group.addTopic("今天吃面", attachments: [], activeMembers: members)
        for index in 0..<4 {
            group.recordReply("第 \(index + 1) 句", at: index, activeMembers: members)
        }
        XCTAssertEqual(group.turns.map(\.roleID), [warm.id, sweet.id, warm.id, sweet.id])
        XCTAssertEqual(group.turns.last?.requesterID, warm.id)
        XCTAssertNil(group.queuedTurnIndex())

        group.addTopic("看看这个页面", attachments: [], activeMembers: members)
        let index = group.turns.count - 1
        group.recordReply("< | | DSML | | calls>本段模型标记", at: index, activeMembers: members)
        XCTAssertTrue(group.turns[index].answer?.contains("暖光提示") == true)
        XCTAssertFalse(group.turns[index].answer?.contains("DSML") == true)
        XCTAssertNil(group.queuedTurnIndex())
        XCTAssertEqual(TextOnlyReply.parse("回复<｜｜DSM", streaming: true).text, "回复")
    }

    func testParallelTopicCanStartBothRolesWithoutSharingAnEarlierParallelReply() {
        let warm = Role(name: "暖暖", summary: "", template: .general)
        let sweet = Role(name: "糖糖", summary: "", template: .writing)
        let members = [warm, sweet]
        var group = GroupDiscussion(title: "聊天", goal: "", memberIDs: members.map(\.id))
        group.replyMode = .parallel
        group.casualReplyLimit = 2
        group.addTopic("大家好", attachments: [], activeMembers: members)
        XCTAssertEqual(group.turns.map(\.kind), [.parallelTopic, .parallelReply])
        XCTAssertEqual(group.queuedTurnIndex(), 0)
        group.turns[0].state = .running
        XCTAssertEqual(group.queuedTurnIndex(), 1)
        group.recordReply("先收到的并行回复", at: 0, activeMembers: members)
        XCTAssertFalse(group.prompt(for: 1, members: members).contains("先收到的并行回复"))
        group.recordReply("另一条独立回复", at: 1, activeMembers: members)
        XCTAssertEqual(group.turns.count, 2)
    }

    func testEveryoneMentionIncludesQuietMembersAndQueuesEachMemberOnce() {
        let a = Role(name: "暖暖", summary: "", template: .general)
        let b = Role(name: "糖糖", summary: "", template: .writing)
        let c = Role(name: "编辑", summary: "", template: .blank)
        let unavailable = Role(name: "不可用成员", summary: "", template: .blank)
        let outsider = Role(name: "群外成员", summary: "", template: .blank)
        let available = [c, b, a, outsider]
        var group = GroupDiscussion(title: "聊天", goal: "", memberIDs: [a.id, b.id, c.id, unavailable.id])
        group.casualReplyLimit = 1
        group.relayLimit = 3
        var quiet = GroupMemberChatPreferences()
        quiet.initiative = .reserved
        group.memberChatPreferences = [a.id: quiet]

        XCTAssertFalse(group.addTopic("核对清单", attachments: [], activeMembers: [outsider], toEveryone: true))
        XCTAssertTrue(group.addTopic("核对清单", attachments: [], activeMembers: available, toEveryone: true))
        XCTAssertEqual(group.turns.map(\.roleID), [a.id, b.id, c.id])
        XCTAssertEqual(group.turns.map(\.kind), [.everyoneTopic, .everyoneReply, .everyoneReply])
        XCTAssertEqual(group.turns.filter(\.initiatedByUser).count, 1)
        XCTAssertEqual(Set(group.turns.map(\.taskID)).count, 1)
        XCTAssertEqual(group.queuedTurnIndex(), 0)
        group.turns[0].state = .running
        XCTAssertNil(group.queuedTurnIndex())
        group.replyMode = .parallel
        XCTAssertEqual(group.queuedTurnIndex(), 1)
        group.turns[1].state = .running
        XCTAssertNil(group.queuedTurnIndex())

        group.recordReply("已核对第一项\n[[接力 \(c.id)]] 再核对一次", at: 0, activeMembers: available)
        XCTAssertNil(group.turns[0].relay)
        XCTAssertFalse(group.prompt(for: 2, members: available).contains("已核对第一项"))
        XCTAssertTrue(group.prompt(for: 2, members: available).contains("核对清单"))
        for index in 1...2 { group.recordReply("已核对", at: index, activeMembers: available) }
        XCTAssertEqual(group.turns.count, 3)
        XCTAssertNil(group.queuedTurnIndex())
    }

    func testNaturalChatKeepsALinkToOneReplyAndLetsMembersPass() {
        let a = Role(name: "暖暖", summary: "", template: .general)
        let b = Role(name: "糖糖", summary: "", template: .writing)
        let members = [a, b]
        var group = GroupDiscussion(title: "闲聊", goal: "", memberIDs: members.map(\.id))
        XCTAssertEqual(group.effectiveReplyMode, .natural)
        group.addTopic("https://example.com/?view=feed", attachments: [], activeMembers: members)
        group.recordReply("具体想看页面的哪一部分？", at: 0, activeMembers: members)
        XCTAssertEqual(group.turns.count, 1)
        group.addTopic("周末大家想吃什么？", attachments: [], activeMembers: members)
        var proactive = GroupMemberChatPreferences()
        proactive.initiative = .proactive
        group.memberChatPreferences = Dictionary(uniqueKeysWithValues: members.map { ($0.id, proactive) })
        group.recordReply("可以试试牛肉面。", at: 1, activeMembers: members)
        XCTAssertEqual(group.turns.count, 3)
        XCTAssertTrue(group.prompt(for: 2, members: members).contains("只输出 [[略过]]"))
        XCTAssertEqual(group.turns[2].visibleStreamedReply("[[略"), "")
        XCTAssertEqual(group.turns[2].visibleStreamedReply("新建议"), "新建议")
        group.recordReply("[[略过]]", at: 2, activeMembers: members)
        XCTAssertNil(group.turns[2].answer)
        XCTAssertEqual(group.turns[2].state, .completed)
        XCTAssertNil(group.queuedTurnIndex())
    }

    func testGroupActivityAndMemberStyleControlSeparatePartsOfTheConversation() throws {
        let a = Role(name: "暖暖", summary: "", template: .general)
        let b = Role(name: "糖糖", summary: "", template: .writing)
        let c = Role(name: "小米", summary: "", template: .engineering)
        let members = [a, b, c]
        var group = GroupDiscussion(title: "闲聊", goal: "", memberIDs: members.map(\.id))
        var reserved = GroupMemberChatPreferences()
        reserved.initiative = .reserved
        reserved.tone = .cool
        reserved.intensity = .vivid
        var active = GroupMemberChatPreferences()
        active.initiative = .proactive
        active.tone = .custom
        active.customTone = "热情俏皮，直接回应别人"
        group.memberChatPreferences = [a.id: reserved, c.id: active]
        group.chatActivity = .lively
        group.chatFocus = .free
        group.casualReplyLimit = 6
        group.addTopic("大家好", attachments: [], activeMembers: members)
        XCTAssertEqual(group.turns[0].roleID, b.id)
        group.recordReply("大家好。", at: 0, activeMembers: members)
        XCTAssertEqual(group.turns[1].roleID, c.id)
        let prompt = group.prompt(for: 1, members: members)
        XCTAssertTrue(prompt.contains("热情俏皮，直接回应别人"))
        XCTAssertFalse(prompt.contains("清冷沉稳"))
        for index in 1..<6 {
            guard index < group.turns.count else { return XCTFail("热络模式提前停止了接话") }
            group.recordReply("接话 \(index)", at: index, activeMembers: members)
        }
        XCTAssertEqual(group.turns.count, 6)
        group.turns.append(GroupTurn(role: a, question: "暖暖也说说"))
        XCTAssertTrue(group.prompt(for: 6, members: members).contains("本群的说话风格（鲜明）"))

        var child = GroupDiscussion(title: "新对话", goal: "", memberIDs: [])
        let saved = try JSONEncoder().encode(group)
        child.inheritGroupSettings(from: try JSONDecoder().decode(GroupDiscussion.self, from: saved))
        XCTAssertEqual(child.memberChatPreferences?[a.id], reserved)
        XCTAssertEqual(child.effectiveChatActivity, .lively)
        child.chatActivity = .quiet
        child.addTopic("安静待会儿", attachments: [], activeMembers: members)
        child.recordReply("好的。", at: 0, activeMembers: members)
        XCTAssertEqual(child.turns.count, 1)
        child.idleChatMinutes = 2
        XCTAssertTrue(child.addIdleTopic(now: child.updated.addingTimeInterval(180), activeMembers: members))
        XCTAssertEqual(child.turns.last?.roleID, c.id)
    }

    func testSingleMentionCanLeadToOptionalRepliesAndRespectsMemberSpeechPermissions() throws {
        let sugar = Role(name: "糖糖", summary: "", template: .blank)
        let pomelo = Role(name: "柚子", summary: "", template: .blank)
        let pear = Role(name: "小梨", summary: "", template: .blank)
        let members = [sugar, pomelo, pear]
        var group = GroupDiscussion(title: "闲聊", goal: "", memberIDs: members.map(\.id))
        group.chatActivity = .lively
        group.chatFocus = .free
        group.continuesAfterMention = true
        group.relayLimit = 1
        group.idleChatMinutes = 15
        var sugarSettings = GroupMemberChatPreferences()
        sugarSettings.canRequestRelay = false
        sugarSettings.canOpenIdleTopic = false
        var pomeloSettings = GroupMemberChatPreferences()
        pomeloSettings.initiative = .mentionedOnly
        group.memberChatPreferences = [sugar.id: sugarSettings, pomelo.id: pomeloSettings]
        XCTAssertTrue(group.addDirectedMessage("哄哄她", attachments: [], to: [sugar.id], activeMembers: members))
        XCTAssertTrue(group.prompt(for: 0, members: members).contains("未给你开启发起接力"))
        group.recordReply("先吃一颗糖。\n@柚子 还生气吗？", at: 0, activeMembers: members)
        XCTAssertNil(group.turns[0].relay)
        let reaction = try XCTUnwrap(group.turns.dropFirst().first)
        XCTAssertEqual(reaction.roleID, pear.id)
        XCTAssertEqual(reaction.kind, .reaction)
        XCTAssertEqual(reaction.mayPass, true)
        XCTAssertTrue(group.prompt(for: 1, members: members).contains("先吃一颗糖"))
        group.recordReply("[[略过]]", at: 1, activeMembers: members)
        XCTAssertNil(group.turns[1].answer)
        XCTAssertEqual(group.turns.count, 2)
        XCTAssertTrue(group.addIdleTopic(now: group.updated.addingTimeInterval(901), activeMembers: members))
        XCTAssertEqual(group.turns.last?.roleID, pear.id)
        XCTAssertTrue(group.addDirectedMessage("你也说说", attachments: [], to: [pomelo.id], activeMembers: members))
        XCTAssertEqual(group.turns.last?.roleID, pomelo.id)

        let restored = try JSONDecoder().decode(GroupDiscussion.self, from: JSONEncoder().encode(group))
        var child = GroupDiscussion(title: "新对话", goal: "", memberIDs: [])
        child.inheritGroupSettings(from: restored)
        XCTAssertEqual(child.continuesAfterMention, true)
        XCTAssertEqual(child.memberChatPreferences, group.memberChatPreferences)
        XCTAssertFalse(child.addTopic("随便聊聊", attachments: [], activeMembers: [pomelo]))
        child.chatActivity = .quiet
        XCTAssertTrue(child.addDirectedMessage("哄哄她", attachments: [], to: [sugar.id], activeMembers: members))
        child.recordReply("先吃一颗糖。", at: 0, activeMembers: members)
        XCTAssertEqual(child.turns.count, 1)
    }

    func testConsultationContextIncludesVisibleRepliesAndRoleDirectoryHints() {
        let warm = Role(name: "暖暖", summary: "整理日常事项", template: .general)
        let caller = Role(name: "糖糖", summary: "", template: .writing)
        var thread = Conversation(roleID: caller.id)
        let question = Message(.user, "暖暖是谁？")
        var tool = Message(.tool, "工具内部内容")
        tool.tool = ToolRun(id: "private", title: nil, status: "completed", details: "内部日志")
        let reply = Message(.assistant, "暖暖是同工作台的助手。")
        thread.messages = [question, Message(.assistant, "中间准备"), tool, reply]
        let context = RoleConsultation.recentContext(in: thread, sourceName: caller.name)
        XCTAssertEqual(context.map(\.id), [question.id, reply.id])
        let hint = RoleDirectoryEntry.promptForMentions(in: question.text, roles: [caller, warm], caller: caller.id)
        XCTAssertTrue(hint.contains(warm.summary))
        XCTAssertEqual(RoleDirectoryEntry.promptForMentions(in: "/暖暖", roles: [warm], caller: caller.id), "/暖暖")
    }

    func testOpenTopicLetsTwoMembersTalkAndPrefersAnExplicitMention() {
        let a = Role(name: "暖暖", summary: "", template: .blank)
        let b = Role(name: "糖糖", summary: "", template: .blank)
        let c = Role(name: "小满", summary: "", template: .blank)
        let members = [a, b, c]
        var group = GroupDiscussion(title: "闲聊", goal: "", memberIDs: [a.id, b.id, c.id])
        group.replyMode = .sequential
        XCTAssertTrue(group.addTopic("我今天吃了番茄牛肉面", attachments: [], activeMembers: members))
        group.recordReply("好棒，番茄牛肉面听起来很暖胃。", at: 0, activeMembers: members)
        XCTAssertEqual(group.turns.map(\.roleID), [a.id, b.id])
        XCTAssertEqual(group.turns[1].kind, .reaction)
        XCTAssertEqual(group.turns[1].requesterID, a.id)
        XCTAssertEqual(group.turns[1].taskID, group.turns[0].id)
        XCTAssertTrue(group.prompt(for: 1, members: members).contains("暖暖刚才说：好棒"))
        group.recordReply("暖暖，我也觉得！\n[[接力 \(a.id)]] 你平时也爱吃面吗？", at: 1, activeMembers: members)
        XCTAssertEqual(group.turns.count, 2)
        XCTAssertEqual(group.turns[1].relay?.enqueued, false)

        XCTAssertTrue(group.addTopic("还喝了柠檬水", attachments: [], activeMembers: members))
        group.recordReply("好清爽！\n@暖暖 你平时喝什么？", at: 2, activeMembers: members)
        XCTAssertEqual(group.turns.last?.roleID, a.id)
        XCTAssertEqual(group.turns.last?.requesterID, b.id)
        XCTAssertNil(group.turns.last?.kind)
        XCTAssertEqual(group.turns[2].relay?.enqueued, true)
        let relay = group.turns[2].relay
        let answer = "好清爽！\n@暖暖 你平时喝什么？"
        XCTAssertEqual(group.turns[2].answer, answer)
        XCTAssertEqual(relay?.removingNamedMention(from: answer, recipientName: a.name), "好清爽！")
        XCTAssertEqual(relay?.removingNamedMention(from: answer, recipientName: b.name), answer)
        XCTAssertEqual(relay?.removingNamedMention(from: "@暖暖：你平时喝什么？", recipientName: a.name), "")
        XCTAssertEqual(relay?.removingNamedMention(from: "@暖暖 今天想喝水吗？", recipientName: a.name), "@暖暖 今天想喝水吗？")
    }

    func testRelayBudgetMembershipAndRepeatedSpeakers() {
        let a = Role(name: "设计", summary: "", template: .blank)
        let b = Role(name: "开发", summary: "", template: .blank)
        let c = Role(name: "验收", summary: "", template: .blank)
        let outsider = Role(name: "群外助手", summary: "", template: .blank)
        let members = [a, b, c, outsider]
        var group = GroupDiscussion(title: "交付讨论", goal: "验证改动", memberIDs: [a.id, b.id, c.id])
        group.relayLimit = 1
        group.turns.append(GroupTurn(role: a, question: "提出方案"))
        group.recordReply("初步方案\n[[接力 \(b.id)]] 实施并说明具体步骤", at: 0, activeMembers: members)
        XCTAssertEqual(group.turns.count, 2)
        XCTAssertEqual(group.turns[0].answer, "初步方案")
        XCTAssertEqual(group.turns[1].taskID, group.turns[0].id)
        XCTAssertEqual(group.turns[1].requesterID, a.id)
        group.recordReply("实施说明\n[[接力 \(c.id)]] 核对结果", at: 1, activeMembers: members)
        XCTAssertEqual(group.turns.count, 2)
        XCTAssertEqual(group.turns[1].relay?.enqueued, false)
        group.relayLimit = 3
        group.recordReply("请再看一次\n[[接力 \(a.id)]] 重复发言", at: 1, activeMembers: members)
        XCTAssertEqual(group.turns.count, 2)
        group.recordReply("建议询问\n[[接力 \(outsider.id)]] 群外问题", at: 1, activeMembers: members)
        XCTAssertNil(group.turns[1].relay)
        XCTAssertFalse(group.prompt(for: 1, members: members).contains(outsider.id.uuidString))
    }

    func testProposalIsOnlyADraftAndRejectsUnavailableMembers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roles = RoleStore(root: root)
        let a = Role(name: "策划", summary: "", template: .blank)
        let b = Role(name: "验收", summary: "", template: .blank)
        try roles.create(a, instructions: "私有设定")
        try roles.create(b, instructions: "")
        let store = GroupDiscussionStore(root: root)
        let draft = try store.propose(authorID: a.id, title: "联合验收", goal: "核对上线清单",
            members: [(b.id, "设计用例")], firstTask: "提出验收计划", using: roles)
        XCTAssertEqual(try store.proposals(), [draft])
        XCTAssertTrue(try store.discussions().isEmpty)
        XCTAssertEqual(try store.propose(authorID: a.id, title: "联合验收", goal: "核对上线清单",
            members: [(b.id, "设计用例")], firstTask: "提出验收计划", using: roles).id, draft.id)
        _ = try roles.archive(b.id)
        XCTAssertThrowsError(try store.propose(authorID: a.id, title: "联合验收", goal: "核对上线清单",
            members: [(b.id, "设计用例")], firstTask: "提出验收计划", using: roles))
    }
}
