import AppKit
import StudioCore
import SwiftUI
import XCTest
@testable import HermesStudio

final class RoleAvatarPickerTests: XCTestCase {
    @MainActor
    func testEveryIllustrationHasAnImage() {
        for item in RoleIllustration.allCases {
            XCTAssertNotNil(RolePortrait.illustration(item), "缺少头像图片：\(item.rawValue)")
        }
    }

    @MainActor
    func testScrolledAvatarCanBeSelectedSavedAndShownWhenReopened() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        var role = Role(name: "测试角色", summary: "", template: .blank)
        role.avatar = .illustration(.sunrise)
        try store.create(role, instructions: "")
        let studio = StudioModel(dataStore: store, runtime: HermesRuntime(executable: URL(fileURLWithPath: "/usr/bin/false")),
            runPreferences: .init())

        try await withEditor(studio, role: role) { window, strip in
            let clip = strip.contentView
            let document = try XCTUnwrap(strip.documentView)
            let maxOffset = document.frame.width - clip.bounds.width
            XCTAssertGreaterThan(maxOffset, 0)
            XCTAssertEqual(clip.bounds.minX, 0, accuracy: 1)
            let scroller = try XCTUnwrap(strip.horizontalScroller)
            let action = try XCTUnwrap(scroller.action)
            for _ in 0..<RoleIllustration.people.count where clip.bounds.minX < maxOffset - 1 {
                let previousOffset = clip.bounds.minX
                scroller.floatValue = 1
                NSApplication.shared.sendAction(action, to: strip, from: scroller)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertGreaterThan(clip.bounds.minX, previousOffset)
            }
            XCTAssertEqual(clip.bounds.minX, maxOffset, accuracy: 1)
            try click(clip.convert(CGPoint(x: clip.bounds.maxX - 18, y: clip.bounds.midY), to: nil), in: window)
            try await Task.sleep(for: .milliseconds(50))
            try click(CGPoint(x: 661, y: 28), in: window)
        }

        let saved = try XCTUnwrap(store.list().first { $0.id == role.id })
        XCTAssertEqual(saved.avatar, .illustration(.jadeBun))
        try await withEditor(studio, role: saved) { window, strip in
            let clip = strip.contentView
            let document = try XCTUnwrap(strip.documentView)
            XCTAssertEqual(clip.bounds.maxX, document.frame.width, accuracy: 1)
            try snapshot("角色头像-已滚动.png", in: window)
        }
    }

    @MainActor
    func testAIProfileUpdateStaysInTheEditorUntilSaved() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let executable = root.appendingPathComponent("草稿测试助手")
        var role = Role(name: "会议搭档", summary: "原来的简介", template: .blank)
        role.avatar = .illustration(.nuannuan)
        role.skillIDs = ["保留的技能"]
        try store.create(role, instructions: "保留已有角色指令。")
        try Data(Self.draftFixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let studio = StudioModel(dataStore: store, runtime: HermesRuntime(executable: executable), runPreferences: .init())

        try await withEditor(studio, role: nil) { window, _ in
            try snapshot("AI-创建角色.png", in: window)
        }
        try await withEditor(studio, role: role) { window, strip in
            try click(CGPoint(x: 640, y: 534), in: window)
            try await Task.sleep(for: .milliseconds(150))
            let view = try XCTUnwrap(window.contentView)
            let field = try XCTUnwrap(textField(at: CGPoint(x: 365, y: 438), in: view))
            XCTAssertTrue(window.makeFirstResponder(field))
            let input = try XCTUnwrap(field.currentEditor() as? NSTextInputClient)
            input.insertText("改简介并换成青绿盘发头像", replacementRange: input.selectedRange())
            try await Task.sleep(for: .milliseconds(100))
            try click(CGPoint(x: 625, y: 387), in: window)
            for _ in 0..<30 where strip.contentView.bounds.minX < 1 {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertGreaterThan(strip.contentView.bounds.minX, 0)
            XCTAssertEqual(try store.list().first, role)
            try snapshot("AI-编辑角色资料.png", in: window)
            try click(CGPoint(x: 661, y: 28), in: window)
        }

        let saved = try XCTUnwrap(store.list().first)
        XCTAssertEqual(saved.name, role.name)
        XCTAssertEqual(saved.skillIDs, role.skillIDs)
        XCTAssertEqual(saved.summary, "整理会议行动项。")
        XCTAssertEqual(saved.avatar, .illustration(.jadeBun))
        XCTAssertEqual(try store.file(.soul, for: role.id), "保留已有角色指令。")
    }

    @MainActor
    func testAIRoleBehaviorDraftUsesPeerProfilesAndOnlyPersistsWhenSaved() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let executable = root.appendingPathComponent("草稿测试助手")
        let role = Role(name: "柚子", summary: "陪伴复盘。", template: .blank)
        var peer = Role(name: "糖糖", summary: "擅长安慰和接梗。", template: .blank)
        peer.libraryGroup = "日常陪伴"
        try store.create(role, instructions: "保留已有角色指令。")
        try store.create(peer, instructions: "另一角色的详细指令", initialMemory: [.memory: "不应进入草稿的记忆"])
        try Data(Self.draftFixture.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let studio = StudioModel(dataStore: store, runtime: HermesRuntime(executable: executable), runPreferences: .init())
        let revised = "保留已有角色指令。心情低落时，先问需要倾听还是建议。"

        try await withEditor(studio, role: role) { window, _ in
            try click(CGPoint(x: 640, y: 534), in: window)
            try await Task.sleep(for: .milliseconds(150))
            let view = try XCTUnwrap(window.contentView)
            let field = try XCTUnwrap(textField(at: CGPoint(x: 365, y: 438), in: view))
            XCTAssertTrue(window.makeFirstResponder(field))
            let input = try XCTUnwrap(field.currentEditor() as? NSTextInputClient)
            input.insertText("调整行为，参考糖糖但保留自己的职责", replacementRange: input.selectedRange())
            try await Task.sleep(for: .milliseconds(100))
            try click(CGPoint(x: 625, y: 387), in: window)
            for _ in 0..<30 where !hasTextEditor(revised, in: view) {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(hasTextEditor(revised, in: view))
            XCTAssertEqual(try store.file(.soul, for: role.id), "保留已有角色指令。")
            try snapshot("AI-角色指令草稿.png", in: window)
            try click(CGPoint(x: 661, y: 28), in: window)
        }

        XCTAssertEqual(try store.file(.soul, for: role.id), revised)
        XCTAssertEqual(try store.file(.soul, for: peer.id), "另一角色的详细指令")
        XCTAssertEqual(try store.list().first { $0.id == role.id }, role)
    }

    @MainActor
    private func snapshot(_ name: String, in window: NSWindow) throws {
        guard let directory = ProcessInfo.processInfo.environment["HERMES_STUDIO_SNAPSHOT_DIR"],
            let view = window.contentView else { return }
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @MainActor
    private func withEditor(_ studio: StudioModel, role: Role?,
        check: (NSWindow, NSScrollView) async throws -> Void) async throws {
        let bounds = CGRect(x: 0, y: 0, width: 710, height: 565)
        let hosting = NSHostingView(rootView: RoleEditor(studio: studio, role: role).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        try await check(window, XCTUnwrap(horizontalScrollView(in: hosting)))
    }

    private func horizontalScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.hasHorizontalScroller { return scroll }
        return view.subviews.lazy.compactMap { self.horizontalScrollView(in: $0) }.first
    }

    private func textField(at point: CGPoint, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.convert(field.bounds, to: nil).contains(point) { return field }
        return view.subviews.lazy.compactMap { self.textField(at: point, in: $0) }.first
    }

    private func hasTextEditor(_ text: String, in view: NSView) -> Bool {
        if let editor = view as? NSTextView, editor.string == text { return true }
        return view.subviews.contains { hasTextEditor(text, in: $0) }
    }

    @MainActor
    private func click(_ point: CGPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private static let draftFixture = #"""
        #!/usr/bin/python3
        import json, sys

        if sys.argv[1:] != ["acp"]:
            print('{"default":"tester","provider":"fixture"}' if sys.argv[-1] == "model" else "{}")
            sys.exit(0)

        for line in sys.stdin:
            request = json.loads(line)
            method = request["method"]
            result = {"ok": True}
            if method == "session/new":
                result = {"sessionId": "draft"}
            elif method == "session/prompt":
                prompt = request["params"]["prompt"][0]["text"]
                assert "保留已有角色指令。" in prompt
                if "调整行为" in prompt:
                    assert "糖糖" in prompt and "擅长安慰和接梗" in prompt and "日常陪伴" in prompt
                    assert "另一角色的详细指令" not in prompt and "不应进入草稿的记忆" not in prompt
                    draft = json.dumps({"instructions": "保留已有角色指令。心情低落时，先问需要倾听还是建议。",
                                        "designNotes": ["与糖糖区分：先确认对方想倾听还是建议。"]})
                else:
                    assert "改简介并换成青绿盘发头像" in prompt and "保留的技能" in prompt
                    draft = json.dumps({"summary": "整理会议行动项。", "avatarID": "jadeBun"})
                update = {"sessionUpdate": "agent_message_chunk", "messageId": "reply", "content": {"text": draft}}
                print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "sessionId": "draft", "update": update}}), flush=True)
                result = {"stopReason": "end_turn"}
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        """#
}
