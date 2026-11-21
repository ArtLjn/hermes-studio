import AppKit
import StudioCore
import SwiftUI

enum ComposerKey {
    case send, up, down, dismiss, complete, acceptInline
}

struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var selection: NSRange
    @Binding var height: CGFloat
    let focusRequest: UUID
    let placeholder: String
    let completion: String?
    let handle: (ComposerKey) -> Bool
    let pasteImage: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = InputTextView()
        editor.drawsBackground = false
        editor.isRichText = false
        editor.importsGraphics = false
        editor.font = .systemFont(ofSize: 14)
        editor.placeholder = placeholder
        editor.textColor = NSColor(white: 0.96, alpha: 1)
        editor.insertionPointColor = NSColor(white: 0.90, alpha: 1)
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.textContainer?.lineFragmentPadding = 1
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.autoresizingMask = .width
        editor.delegate = context.coordinator
        editor.coordinator = context.coordinator
        editor.setAccessibilityLabel("消息输入框")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? InputTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        let focusChanged = coordinator.focusRequest != focusRequest
        coordinator.focusRequest = focusRequest
        editor.placeholder = placeholder
        editor.completion = completion
        if !editor.hasMarkedText(), editor.string != text || focusChanged {
            coordinator.updating = true
            editor.string = text
            let length = text.utf16.count
            let cursor = NSRange(location: focusChanged ? length : min(selection.location, length), length: 0)
            editor.setSelectedRange(cursor)
            if selection != cursor {
                DispatchQueue.main.async { [weak editor] in
                    guard let editor, editor.string == text, editor.selectedRange() == cursor else { return }
                    editor.coordinator?.parent.selection = cursor
                }
            }
            coordinator.updating = false
        }
        if focused, !coordinator.requestedFocus || focusChanged {
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.coordinator?.parent.focused == true else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
        coordinator.requestedFocus = focused
        coordinator.measure(editor)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        var updating = false
        var requestedFocus = false
        var focusRequest: UUID

        init(_ parent: ComposerEditor) {
            self.parent = parent
            focusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            synchronize(view)
        }

        func synchronize(_ view: NSTextView) {
            guard !updating else { return }
            view.needsDisplay = true
            measure(view)
            // 拼音预编辑保留在 AppKit，候选词提交后再更新草稿。
            guard !view.hasMarkedText() else { return }
            if parent.text != view.string { parent.text = view.string }
            if parent.selection != view.selectedRange() { parent.selection = view.selectedRange() }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !updating, !view.hasMarkedText() else { return }
            parent.selection = view.selectedRange()
        }

        func measure(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = min(142, max(30, ceil(max(layout.usedRect(for: container).maxY,
                layout.extraLineFragmentRect.maxY)) + 10))
            if height != parent.height {
                DispatchQueue.main.async { [weak self] in self?.parent.height = height }
            }
        }

        func focusDidChange(_ focused: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.focused != focused else { return }
                self.requestedFocus = focused
                self.parent.focused = focused
            }
        }
    }
}

final class InputTextView: NSTextView {
    weak var coordinator: ComposerEditor.Coordinator?
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var completion: String? {
        didSet { if completion != oldValue { needsDisplay = true } }
    }
    var showsPlaceholder: Bool { string.isEmpty && !hasMarkedText() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsPlaceholder {
            let origin = textContainerOrigin
            let x = origin.x + (textContainer?.lineFragmentPadding ?? 0)
            drawHint(placeholder, in: NSRect(x: x, y: origin.y, width: visibleRect.maxX - x - 3, height: 22))
            return
        }
        let end = string.utf16.count
        guard !hasMarkedText(), let completion, let window, window.firstResponder === self,
            selectedRange() == NSRange(location: end, length: 0) else { return }
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let cursor = convert(window.convertFromScreen(screenRect), from: nil)
        let x = cursor.minX + 1
        let width = visibleRect.maxX - textContainerInset.width - 3 - x
        drawHint(completion, in: NSRect(x: x, y: cursor.minY, width: width, height: cursor.height))
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
        coordinator?.measure(self)
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            coordinator?.synchronize(self)
        }
    }

    private func drawHint(_ text: String, in rect: NSRect) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(StudioPalette.muted),
                .paragraphStyle: style
            ])
    }

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText(), let coordinator else {
            super.keyDown(with: event)
            return
        }
        let key: ComposerKey?
        switch event.keyCode {
        case 36, 76:
            if event.modifierFlags.contains(.shift) {
                insertNewline(self)
                return
            }
            if event.isARepeat { return }
            key = .send
        case 126: key = .up
        case 125: key = .down
        case 53: key = .dismiss
        case 48 where event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty:
            key = .complete
        case 124 where event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty:
            key = .acceptInline
        default: key = nil
        }
        if let key, coordinator.parent.handle(key) { return }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if coordinator?.parent.pasteImage() != true { super.paste(sender) }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), ClipboardImages.canRead(from: .general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { coordinator?.focusDidChange(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { coordinator?.focusDidChange(false) }
        return result
    }
}
