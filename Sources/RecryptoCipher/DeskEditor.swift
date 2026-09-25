import AppKit
import SwiftUI

/// A plain text editor that takes a dropped file instead of inserting its path.
struct DeskEditor: NSViewRepresentable {
    @Binding var text: String
    var ink: NSColor
    var monospaced: Bool
    var onFile: ([URL]) -> Void
    var onHover: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 160)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = DeskScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textView = DeskTextView()
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        var types = textView.registeredDraggedTypes
        if !types.contains(.fileURL) { types.append(.fileURL) }
        if !types.contains(.string) { types.append(.string) }
        textView.registerForDraggedTypes(types)
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? DeskTextView else { return }
        context.coordinator.text = $text
        textView.onFile = onFile
        textView.onHover = onHover
        let body = NSFont.systemFont(ofSize: 16)
        let serif = NSFont(descriptor: body.fontDescriptor.withDesign(.serif) ?? body.fontDescriptor, size: 16) ?? body
        textView.font = monospaced ? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular) : serif
        textView.textColor = ink
        textView.insertionPointColor = ink
        let width = max(scroll.contentSize.width, scroll.bounds.width)
        if width > 1 {
            textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
        }
        if let font = textView.font {
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: ink,
            ]
        }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if text.wrappedValue != view.string {
                text.wrappedValue = view.string
            }
        }
    }
}

struct WordField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var ink: NSColor
    var onFile: (([URL]) -> Void)?
    var onHover: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> WordTextField {
        let field = WordTextField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = wordFont()
        field.textColor = ink
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: WordTextField, context: Context) {
        context.coordinator.text = $text
        field.onFile = onFile
        field.onHover = onHover
        field.textColor = ink
        field.font = wordFont()
        if field.stringValue != text {
            field.abortEditing()
            field.stringValue = text
        }
        let font = wordFont()
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: font,
                .foregroundColor: ink.withAlphaComponent(0.45),
            ]
        )
    }

    private func wordFont() -> NSFont {
        let body = NSFont.systemFont(ofSize: 16)
        return NSFont(descriptor: body.fontDescriptor.withDesign(.serif) ?? body.fontDescriptor, size: 16) ?? body
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }
    }
}

final class WordTextField: NSTextField {
    var onFile: (([URL]) -> Void)?
    var onHover: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.registerForDraggedTypes([.string])
        }
        return accepted
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onFile != nil, !Self.fileURLs(from: sender).isEmpty else { return [] }
        onHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onFile != nil, !Self.fileURLs(from: sender).isEmpty else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHover?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onFile != nil && !Self.fileURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onHover?(false)
        onFile?(urls)
        return true
    }

    private static func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}

/// The sheet’s text can be many lines. The scroll view must not report that height,
/// or the window grows to fit the sheet and runs off the bottom of the screen.
final class DeskScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var fittingSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

final class DeskTextView: NSTextView {
    var onFile: (([URL]) -> Void)?
    var onHover: ((Bool) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !Self.fileURLs(from: sender).isEmpty {
            onHover?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !Self.fileURLs(from: sender).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !Self.fileURLs(from: sender).isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHover?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onHover?(false)
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender)
        if !urls.isEmpty {
            onHover?(false)
            onFile?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    private static func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}
