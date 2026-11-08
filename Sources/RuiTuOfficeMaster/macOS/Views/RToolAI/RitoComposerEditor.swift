#if os(macOS)
import AppKit
import SwiftUI

/// 原生多行编辑器；提示文字用同一 TextKit 字体、容器及原点绘制。
struct RitoComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    var isEnabled: Bool
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = RitoComposerTextView(frame: NSRect(x: 0, y: 0, width: 0, height: 38))
        editor.minSize = NSSize(width: 0, height: 38)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = .width
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Rito AI 消息输入框")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? RitoComposerTextView else { return }
        // 输入法组合期间不回写字符串，以免破坏中文候选词。
        if editor.string != text && !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        editor.isEditable = isEnabled
        editor.textColor = NSColor(AppColors.textPrimary)
        editor.insertionPointColor = NSColor(AppColors.primary)
        editor.placeholderColor = NSColor(AppColors.textSecondary).withAlphaComponent(0.65)
        editor.onSend = onSend
        editor.onFocusChange = { [weak coordinator = context.coordinator] focused in
            guard let coordinator, coordinator.parent.isFocused != focused else { return }
            coordinator.parent.isFocused = focused
        }
        editor.onLayout = { [weak coordinator = context.coordinator] height in
            guard let coordinator, abs(coordinator.parent.measuredHeight - height) > 0.5 else { return }
            coordinator.parent.measuredHeight = height
        }
        editor.needsDisplay = true
        editor.reportHeight()
        if isEnabled && isFocused && editor.window?.firstResponder !== editor {
            editor.window?.makeFirstResponder(editor)
        } else if !isFocused && editor.window?.firstResponder === editor {
            editor.window?.makeFirstResponder(nil)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RitoComposerEditor
        init(_ parent: RitoComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            editor.needsDisplay = true
            (editor as? RitoComposerTextView)?.reportHeight()
        }
        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }
        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

final class RitoComposerTextView: NSTextView {
    var onLayout: ((CGFloat) -> Void)?
    private var reportPending = false
    func reportHeight() {
        guard !reportPending else { return }
        reportPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reportPending = false
            guard let layout = self.layoutManager, let container = self.textContainer else { return }
            layout.ensureLayout(for: container)
            self.onLayout?(min(140, max(44, ceil(layout.usedRect(for: container).height + self.textContainerInset.height * 2))))
        }
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); reportHeight() }
    var placeholderColor: NSColor = .placeholderTextColor
    var onSend: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if (event.keyCode == 36 || event.keyCode == 76) && (modifiers.isEmpty || modifiers == .command) && !hasMarkedText() {
            onSend?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let container = textContainer else { return }
        let storage = NSTextStorage(string: "描述你想完成的办公任务…", attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: placeholderColor,
            .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default
        ])
        let layout = NSLayoutManager()
        let placeholderContainer = NSTextContainer(size: container.containerSize)
        placeholderContainer.lineFragmentPadding = container.lineFragmentPadding
        layout.addTextContainer(placeholderContainer)
        storage.addLayoutManager(layout)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: placeholderContainer), at: textContainerOrigin)
    }
}
#endif
