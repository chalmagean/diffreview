import AppKit
import SwiftUI

/// The code part of one diff line, drawn with TextKit so text can be selected by dragging,
/// across lines too. A click without a drag is reported as a line click.
struct CodeLineView: NSViewRepresentable {
    let code: AttributedString
    let font: NSFont
    let fileID: Int
    let lineIndex: Int
    let highlight: LineHighlight?
    /// Word-level changes to mark, and their colour.
    var emphasis: [NSRange] = []
    var emphasisColor: NSColor = .clear
    let noNewlineAtEnd: Bool
    let onClick: (_ extend: Bool) -> Void
    let onDragBegin: (_ offset: Int) -> Void
    let onDragMove: (_ lineIndex: Int, _ offset: Int) -> Void
    let onDragEnd: () -> Void

    func makeNSView(context: Context) -> CodeLineNSView {
        let view = CodeLineNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CodeLineNSView, context: Context) {
        view.fileID = fileID
        view.lineIndex = lineIndex
        view.onClick = onClick
        view.onDragBegin = onDragBegin
        view.onDragMove = onDragMove
        view.onDragEnd = onDragEnd
        view.configure(code: code, font: font, highlight: highlight, noNewlineAtEnd: noNewlineAtEnd)
        view.setEmphasis(emphasis, color: emphasisColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodeLineNSView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? nsView.naturalWidth
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

final class CodeLineNSView: NSView {
    var fileID = 0
    var lineIndex = 0
    var onClick: (Bool) -> Void = { _ in }
    var onDragBegin: (Int) -> Void = { _ in }
    var onDragMove: (Int, Int) -> Void = { _, _ in }
    var onDragEnd: () -> Void = {}

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private var code: AttributedString?
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var highlight: LineHighlight?
    private var emphasis: [NSRange] = []
    private var emphasisColor: NSColor = .clear
    private var noNewlineAtEnd = false
    private var mouseDownLocation: NSPoint?
    private var mouseDownOffset = 0
    private var dragging = false
    /// Width of the text on one unwrapped line. Narrower than this, the line wraps.
    private var unwrappedWidth: CGFloat = 0
    /// The last width asked about and its height, as SwiftUI asks several times per layout.
    private var measured: (width: CGFloat, height: CGFloat)?

    private static let iconWidth: CGFloat = 16
    private static let noNewlineIcon = NSImage(systemSymbolName: "nosign", accessibilityDescription: "No newline at end of file")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed])))

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        // Resizing shouldn't redraw every line each frame: the text stays where it is unless
        // it wraps differently (see setFrameSize).
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func configure(code: AttributedString, font: NSFont, highlight: LineHighlight?, noNewlineAtEnd: Bool) {
        if code != self.code || font != self.font || noNewlineAtEnd != self.noNewlineAtEnd {
            self.code = code
            self.font = font
            self.noNewlineAtEnd = noNewlineAtEnd
            storage.setAttributedString(Self.attributed(code, font: font))
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            unwrappedWidth = ceil(layoutManager.usedRect(for: container).width)
            measured = nil
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
        if highlight != self.highlight {
            self.highlight = highlight
            needsDisplay = true
        }
        toolTip = noNewlineAtEnd ? "No newline at end of file" : nil
    }

    func setEmphasis(_ ranges: [NSRange], color: NSColor) {
        guard ranges != emphasis || color != emphasisColor else { return }
        emphasis = ranges
        emphasisColor = color
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private static func attributed(_ code: AttributedString, font: NSFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
        let text = String(code.characters)
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        // Keep colours from a syntax highlighter (AppKit or SwiftUI attributes).
        for run in code.runs {
            let range = NSRange(run.range, in: code)
            if let color = run.appKit.foregroundColor {
                result.addAttribute(.foregroundColor, value: color, range: range)
            } else if let color = run.swiftUI.foregroundColor {
                result.addAttribute(.foregroundColor, value: NSColor(color), range: range)
            }
        }
        return result
    }

    // MARK: Layout

    private var textWidthLimit: CGFloat { noNewlineAtEnd ? Self.iconWidth : 0 }

    private func wraps(atWidth width: CGFloat) -> Bool {
        width - textWidthLimit < unwrappedWidth
    }

    /// Lines that fit keep one fixed container width, so resizing doesn't throw their layout away.
    private func layout(width: CGFloat) {
        let w = wraps(atWidth: width) ? max(1, width - textWidthLimit) : unwrappedWidth + 1
        if container.size.width != w {
            container.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
    }

    var naturalWidth: CGFloat {
        unwrappedWidth + textWidthLimit
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        guard wraps(atWidth: width) else { return lineHeight }
        if let measured, measured.width == width { return measured.height }
        layout(width: width)
        let height = max(lineHeight, ceil(layoutManager.usedRect(for: container).height))
        measured = (width, height)
        return height
    }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        if newSize.height != old.height || wraps(atWidth: newSize.width) || wraps(atWidth: old.width) {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        layout(width: bounds.width)
        let glyphs = layoutManager.glyphRange(for: container)
        drawEmphasis()
        if let highlight {
            NSColor.selectedTextBackgroundColor.setFill()
            let lineHeight = layoutManager.defaultLineHeight(for: font)
            if highlight.range.length > 0 {
                let selected = layoutManager.glyphRange(forCharacterRange: highlight.range, actualCharacterRange: nil)
                layoutManager.enumerateEnclosingRects(forGlyphRange: selected,
                                                      withinSelectedGlyphRange: selected,
                                                      in: container) { rect, _ in
                    rect.fill()
                }
            }
            if highlight.continues {
                // A sliver after the line end, like an editor shows for the selected newline.
                let end = endOfTextRect(lineHeight: lineHeight)
                NSRect(x: end.maxX, y: end.minY, width: 6, height: end.height).fill()
            }
        }
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        if noNewlineAtEnd, let icon = Self.noNewlineIcon {
            let end = endOfTextRect(lineHeight: layoutManager.defaultLineHeight(for: font))
            let size = icon.size
            let origin = NSPoint(x: end.maxX + 4, y: end.midY - size.height / 2)
            icon.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// Rounded marks behind the words that changed, like GitHub's darker inline highlight.
    private func drawEmphasis() {
        guard !emphasis.isEmpty else { return }
        emphasisColor.setFill()
        let length = storage.length
        for range in emphasis {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clamped.length > 0 else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                                  withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: container) { rect, _ in
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    /// A zero-width rect at the end of the text's last line.
    private func endOfTextRect(lineHeight: CGFloat) -> NSRect {
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return NSRect(x: 0, y: 0, width: 0, height: lineHeight) }
        var effective = NSRange()
        let fragment = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphCount - 1, effectiveRange: &effective)
        return NSRect(x: fragment.maxX, y: fragment.minY, width: 0, height: fragment.height)
    }

    // MARK: Hit testing

    /// The character offset nearest to `point` (in this view's coordinates).
    func offset(at point: NSPoint) -> Int {
        layout(width: bounds.width)
        let length = storage.length
        guard length > 0 else { return 0 }
        let used = layoutManager.usedRect(for: container)
        if point.y < used.minY { return 0 }
        if point.y >= used.maxY { return length }
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let char = layoutManager.characterIndexForGlyph(at: glyph)
        guard char < length else { return length }
        let composed = (storage.string as NSString).rangeOfComposedCharacterSequence(at: char)
        return fraction > 0.5 ? NSMaxRange(composed) : composed.location
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        mouseDownOffset = offset(at: convert(event.locationInWindow, from: nil))
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let location = event.locationInWindow
        if !dragging {
            guard hypot(location.x - start.x, location.y - start.y) > 3 else { return }
            dragging = true
            onDragBegin(mouseDownOffset)
        }
        autoscroll(with: event)
        if let (target, point) = codeLine(at: location) {
            onDragMove(target.lineIndex, target.offset(at: point))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil; dragging = false }
        guard mouseDownLocation != nil else { return }
        if dragging {
            onDragEnd()
        } else {
            onClick(event.modifierFlags.contains(.shift))
        }
    }

    /// The code line of the same file under `windowPoint`. Every line's code column spans the
    /// same x range, so x is clamped into this view's column: dragging over the gutter or past
    /// the right edge still finds the row under the pointer.
    private func codeLine(at windowPoint: NSPoint) -> (CodeLineNSView, NSPoint)? {
        guard let window, let content = window.contentView else { return nil }
        let column = convert(bounds, to: nil)
        let probe = NSPoint(x: min(max(windowPoint.x, column.minX + 1), column.maxX - 1), y: windowPoint.y)
        let probeInSuperview = content.superview?.convert(probe, from: nil) ?? probe
        var hit = content.hitTest(probeInSuperview)
        while let view = hit, !(view is CodeLineNSView) { hit = view.superview }
        guard let line = hit as? CodeLineNSView, line.fileID == fileID else { return nil }
        return (line, line.convert(windowPoint, from: nil))
    }
}
