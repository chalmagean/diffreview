import AppKit
import SwiftUI

/// A multi-line text editor whose placeholder is drawn by the text view itself, at the same
/// origin as typed text (an overlaid SwiftUI Text can't know TextEditor's internal insets).
struct PlaceholderTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var focusOnAppear = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let old = scroll.documentView as! NSTextView
        let textView = PlaceholderTextView(frame: old.frame, textContainer: old.textContainer)
        textView.autoresizingMask = old.autoresizingMask
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = old.maxSize
        textView.minSize = old.minSize
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.delegate = context.coordinator
        scroll.documentView = textView
        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PlaceholderTextView else { return }
        context.coordinator.text = $text
        if textView.string != text { textView.string = text }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            textView.needsDisplay = true
        }
    }
}

final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font, .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
}
