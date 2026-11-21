import AppKit
import SwiftUI
import XCTest
@testable import HermesStudio

final class ComposerEditorTests: XCTestCase {
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
