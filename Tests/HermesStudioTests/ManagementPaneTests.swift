import AppKit
import SwiftUI
import XCTest
import StudioCore
@testable import HermesStudio

final class ManagementPaneTests: XCTestCase {
    func testConversationBatchesLoadEightMoreThreadsWithoutPassingTheTotal() {
        XCTAssertEqual(ConversationBatch.size, 8)
        XCTAssertEqual(ConversationBatch.nextVisibleCount(current: 8, total: 19), 16)
        XCTAssertEqual(ConversationBatch.nextVisibleCount(current: 16, total: 19), 19)
        XCTAssertEqual(ConversationBatch.nextVisibleCount(current: 19, total: 19), 19)
    }

    func testConversationBatchesHandleEmptyAndExactResults() {
        XCTAssertEqual(ConversationBatch.nextVisibleCount(current: 0, total: 0), 0)
        XCTAssertEqual(ConversationBatch.nextVisibleCount(current: 8, total: 8), 8)
        XCTAssertEqual(ConversationBatch.nextVisibleCount(current: 8, total: 16), 16)
    }

    @MainActor
    func testConversationHistoryDoesNotAppendBatchesDuringLayout() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let role = Role(name: "历史记录回归", summary: "", template: .blank)
        try store.create(role, instructions: "")
        for number in 1...44 {
            var thread = Conversation(roleID: role.id)
            thread.title = "历史对话 \(number)"
            try store.save(thread)
        }
        let studio = StudioModel(dataStore: store, runtime: HermesRuntime(executable: URL(fileURLWithPath: "/usr/bin/false")),
            runPreferences: .init())
        let pane = ManagementPane(studio: studio, page: .constant(.conversations), toolbarLeading: 16,
            create: {}, edit: { _ in }, details: { _ in }, terminalDetails: { _ in }, editFile: { _, _ in }, createProject: { _ in })
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 1020)
        let hosting = NSHostingView(rootView: pane)
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func findScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
            return view.subviews.lazy.compactMap { findScroll(in: $0) }.first
        }

        for size in [bounds.size, CGSize(width: 680, height: 650), bounds.size] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(180))
            hosting.layoutSubtreeIfNeeded()
            let document = try XCTUnwrap(findScroll(in: hosting)?.documentView)
            XCTAssertGreaterThan(document.frame.height, 400)
            XCTAssertLessThan(document.frame.height, 800, "调整窗口尺寸时应只渲染首批对话。")
        }
    }

    @MainActor
    func testRoleLibraryMovesGroupsAndSearchesTheirNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        var role = Role(name: "柚子", summary: "擅长复盘", template: .blank)
        role.pinned = true
        try store.create(role, instructions: "原始角色指令")
        let studio = StudioModel(dataStore: store, runtime: nil, runPreferences: .init())
        let group = try studio.createLibraryGroup(" 日常陪伴  ")
        XCTAssertThrowsError(try studio.createLibraryGroup("日常陪伴"))
        XCTAssertTrue(studio.moveRole(role.id, to: group))
        let moved = try XCTUnwrap(store.list().first)
        XCTAssertEqual(Role.libraryGroupNames(in: try store.list()), ["日常陪伴"])
        XCTAssertTrue(RoleLibraryFilter.group(group).matches(moved, query: "陪伴"))
        XCTAssertTrue(RoleLibraryFilter.all.matches(moved, query: "复盘"))
        XCTAssertFalse(RoleLibraryFilter.ungrouped.matches(moved, query: "柚子"))
        XCTAssertEqual(moved.pinned, true)
        let renamed = try studio.renameLibraryGroup(group, to: "日常协作")
        XCTAssertEqual(studio.libraryGroups, ["日常协作"])
        XCTAssertTrue(RoleLibraryFilter.group(renamed).matches(try XCTUnwrap(studio.roles.first), query: "协作"))
        XCTAssertTrue(studio.moveRole(moved.id, to: nil))
        let ungrouped = try XCTUnwrap(store.list().first)
        XCTAssertTrue(RoleLibraryFilter.ungrouped.matches(ungrouped, query: "柚子"))
        XCTAssertEqual(try store.file(.soul, for: role.id), "原始角色指令")
        var edited = ungrouped
        edited.libraryGroup = "工作"
        try studio.updateRole(edited, changeLibraryGroup: true)
        XCTAssertEqual(try store.list().first?.libraryGroup, "工作")
        XCTAssertEqual(studio.libraryGroups, ["日常协作", "工作"])
    }

    @MainActor
    func testRoleLibraryRendersAnEmptyGroupAndFiltersAtNarrowWidth() async throws {
        guard let output = ProcessInfo.processInfo.environment["HERMES_STUDIO_SNAPSHOT_DIR"] else {
            throw XCTSkip("设置 HERMES_STUDIO_SNAPSHOT_DIR 后生成角色库布局截图。")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        var sugar = Role(name: "糖糖", summary: "日常聊天和情绪陪伴", template: .general)
        sugar.libraryGroup = "日常陪伴"
        try store.create(sugar, instructions: "")
        try store.create(Role(name: "小米", summary: "研发讨论和代码评审", template: .engineering), instructions: "")
        try store.createLibraryGroup("工作协作")
        let studio = StudioModel(dataStore: store, runtime: HermesRuntime(executable: URL(fileURLWithPath: "/usr/bin/false")),
            runPreferences: .init())
        let pane = ManagementPane(studio: studio, page: .constant(.roles), toolbarLeading: 16,
            create: {}, edit: { _ in }, details: { _ in }, terminalDetails: { _ in }, editFile: { _, _ in }, createProject: { _ in })
        for width in [700, 1080] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: 720)
            let hosting = NSHostingView(rootView: pane.preferredColorScheme(.dark))
            hosting.frame = bounds
            let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("角色库-分组-\(width).png"))
        }
    }
}
