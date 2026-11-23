import AppKit
import StudioCore
import SwiftUI
import XCTest
@testable import HermesStudio

final class ComposerEditorTests: XCTestCase {
    @MainActor
    func testChoosingAnAssistantMentionKeepsTheTaskInTheComposer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoleStore(root: root)
        let source = Role(name: "工程助手", summary: "", template: .blank)
        let target = Role(name: "测试助手", summary: "", template: .blank)
        try store.create(source, instructions: "")
        try store.create(target, instructions: "")
        let studio = StudioModel(dataStore: store, runtime: HermesRuntime(executable: URL(fileURLWithPath: "/usr/bin/false")),
            runPreferences: .init())
        studio.select(source)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: ChatComposer(studio: studio, focused: .constant(true), focusRequest: UUID()))
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 320)
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(inputView(in: hosting))
        editor.insertText("核对清单 @测试", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(studio.draft, "核对清单 @测试")
        XCTAssertEqual(editor.coordinator?.parent.handle(.complete), true)
        XCTAssertEqual(studio.selectedHandoffTargetID, target.id)
        XCTAssertEqual(studio.collaborationMode, .question)
        XCTAssertEqual(studio.draft.trimmingCharacters(in: .whitespaces), "核对清单")
        XCTAssertNil(studio.conversation)
    }

    @MainActor
    func testGroupComposerSendsATopicAndChoosesMentionRecipients() async throws {
        let role = Role(name: "暖暖", summary: "", template: .blank)
        let other = Role(name: "糖糖", summary: "", template: .blank)
        let state = GroupDraftState()
        var submitted: (recipient: GroupRecipient, text: String)?
        var submittedAttachments = 0
        let composer = GroupComposerTestHost(state: state, members: [role, other]) { recipient, text, files in
            submitted = (recipient, text)
            submittedAttachments = files.count
            return true
        }
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 200)
        let hosting = NSHostingView(rootView: composer)
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(inputView(in: hosting))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("我今天吃了番茄牛肉面", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.coordinator?.parent.handle(.send), true)
        let sent = try XCTUnwrap(submitted)
        XCTAssertEqual(sent.recipient, .topic)
        XCTAssertEqual(sent.text, "我今天吃了番茄牛肉面")

        for (mention, recipient) in [("@所", GroupRecipient.everyone), ("@暖", .member(role.id))] {
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(editor.string.isEmpty)
            editor.insertText("核对清单 \(mention)", replacementRange: NSRange(location: 0, length: 0))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(editor.coordinator?.parent.handle(.complete), true)
            XCTAssertEqual(state.draft.recipient, recipient)
            XCTAssertEqual(state.draft.text.trimmingCharacters(in: .whitespaces), "核对清单")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(editor.coordinator?.parent.handle(.send), true)
            XCTAssertEqual(submitted?.recipient, recipient)
            XCTAssertEqual(submitted?.text.trimmingCharacters(in: .whitespaces), "核对清单")
        }
        try await Task.sleep(for: .milliseconds(100))
        editor.insertText("各说一句 @暖", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.coordinator?.parent.handle(.complete), true)
        try await Task.sleep(for: .milliseconds(100))
        for mention in ["@糖", "@暖"] {
            editor.insertText(mention, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(editor.coordinator?.parent.handle(.complete), true)
            try await Task.sleep(for: .milliseconds(100))
        }
        let recipients = GroupRecipient.members([role.id, other.id])
        XCTAssertEqual(state.draft.recipient, recipients)
        XCTAssertEqual(recipients.selecting(.member(role.id), toggle: true), .member(other.id))
        XCTAssertEqual(recipients.selecting(.everyone, toggle: true), .everyone)
        XCTAssertEqual(editor.coordinator?.parent.handle(.send), true)
        XCTAssertEqual(submitted?.recipient, recipients)
        XCTAssertEqual(submitted?.text.trimmingCharacters(in: .whitespaces), "各说一句")
        let picture = NSImage(size: NSSize(width: 20, height: 20))
        picture.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        picture.unlockFocus()
        let image = try ImagePayload.prepare(name: "测试.png", data: XCTUnwrap(picture.tiffRepresentation))
        state.draft.attachments = [GroupAttachment(image: image.image)]
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.coordinator?.parent.handle(.send), true)
        XCTAssertEqual(submitted?.text, "")
        XCTAssertEqual(submittedAttachments, 1)
        XCTAssertTrue(state.draft.attachments.isEmpty)
    }

    private func inputView(in view: NSView) -> InputTextView? {
        if let editor = view as? InputTextView { return editor }
        return view.subviews.lazy.compactMap { self.inputView(in: $0) }.first
    }

    @MainActor
    func testMarkedPinyinHidesPlaceholderAndDoesNotEnterTheDraftUntilCommit() async {
        let editor = InputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        editor.placeholder = "发消息…"
        var draft = ""
        var selection = NSRange(location: 0, length: 0)
        let coordinator = ComposerEditor(
            text: Binding(get: { draft }, set: { draft = $0 }),
            focused: .constant(true),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            height: .constant(30),
            focusRequest: UUID(), placeholder: editor.placeholder, completion: nil,
            handle: { _ in false }, pasteImage: { false }
        ).makeCoordinator()
        editor.coordinator = coordinator
        editor.delegate = coordinator

        XCTAssertTrue(editor.showsPlaceholder)
        let currentSelection = NSRange(location: NSNotFound, length: 0)
        editor.setMarkedText("tianqi", selectedRange: NSRange(location: 6, length: 0), replacementRange: currentSelection)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(editor.showsPlaceholder)
        XCTAssertTrue(draft.isEmpty)

        editor.insertText("天气", replacementRange: editor.markedRange())
        await Task.yield()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(draft, "天气")
        XCTAssertFalse(editor.showsPlaceholder)

        editor.string = ""
        XCTAssertTrue(editor.showsPlaceholder)
    }
}

private final class GroupDraftState: ObservableObject {
    @Published var draft = GroupComposerDraft()
}

private struct GroupComposerTestHost: View {
    @ObservedObject var state: GroupDraftState
    let members: [Role]
    let submit: (GroupRecipient, String, [GroupAttachment]) -> Bool

    var body: some View {
        GroupComposer(members: members, store: RoleStore(root: FileManager.default.temporaryDirectory),
            draft: $state.draft, available: true, status: EmptyView(), report: { XCTFail($0) }, submit: submit)
    }
}
