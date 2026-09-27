// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import TersoCore

/// Everything about how the editor looks, gathered so SwiftUI re-renders
/// the representable when any of it changes.
struct EditorConfig: Equatable {
    var font: EditorFont
    var fontSize: Double
    var lineSpacing: Double
    var columnWidth: Double
    var syntax: SyntaxVisibility
    var smartQuotes: Bool
    var focusMode: Bool
    var typewriter: Bool
    var dimInactive: Bool

    @MainActor init(prefs: Preferences, model: WorkspaceModel) {
        font = prefs.font; fontSize = prefs.fontSize; lineSpacing = prefs.lineSpacing
        columnWidth = prefs.columnWidth; syntax = prefs.syntax; smartQuotes = prefs.smartQuotes
        focusMode = model.focusMode; typewriter = model.typewriter; dimInactive = prefs.dimInactiveParagraphs
    }
}

final class TersoTextView: NSTextView {
    var columnWidth: CGFloat = 700 { didSet { updateInsets() } }
    var typewriter = false { didSet { updateInsets() } }
    var onClick: ((Int) -> Void)?
    /// Character index under the pointer (nil when not over text).
    var onHover: ((Int?) -> Void)?
    private var hoverArea: NSTrackingArea?

    var reviewPassageRange: NSRange? { didSet { needsDisplay = true } }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let range = reviewPassageRange, range.length > 0,
              NSMaxRange(range) <= (string as NSString).length,
              let lm = layoutManager, let container = textContainer else { return }
        lm.ensureLayout(for: container)
        let paragraphs = (string as NSString).paragraphRange(for: range)
        let glyphs = lm.glyphRange(forCharacterRange: paragraphs, actualCharacterRange: nil)
        var paragraphRect = NSRect.null
        lm.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, _, _ in
            paragraphRect = paragraphRect.union(line)
        }
        guard !paragraphRect.isNull else { return }
        paragraphRect.origin.x = textContainerOrigin.x - 10
        paragraphRect.origin.y += textContainerOrigin.y
        paragraphRect.size.width = container.size.width + 20
        guard paragraphRect.intersects(rect) else { return }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        HighlightStyle.passageAccent.withAlphaComponent(contrast ? 0.10 : 0.045).setFill()
        NSBezierPath(roundedRect: paragraphRect, xRadius: 4, yRadius: 4).fill()
        HighlightStyle.passageAccent.setFill()
        NSBezierPath(roundedRect: NSRect(x: paragraphRect.minX, y: paragraphRect.minY,
                                        width: 3, height: paragraphRect.height), xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    func updateInsets() {
        let h = max(28, (bounds.width - columnWidth) / 2)
        let visible = enclosingScrollView?.contentView.bounds.height ?? 600
        let v: CGFloat = typewriter ? visible / 2 : 56
        let inset = NSSize(width: h.rounded(), height: v.rounded())
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(characterIndex(under: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    /// The character actually under `point`, or nil in margins and blank space.
    func characterIndex(under point: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.insetBy(dx: -1, dy: -2).contains(p) else { return nil }
        return lm.characterIndexForGlyph(at: glyph)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        onClick?(characterIndexForInsertion(at: point))
    }
}

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    let model: WorkspaceModel
    let config: EditorConfig

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(model: model, text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = TersoTextView(frame: .zero, textContainer: container)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        // Spelling and grammar are drawn by Terso's own toggleable layer.
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = true
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.insertionPointColor = .controlAccentColor
        tv.setAccessibilityLabel("Document")

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let c = context.coordinator
        c.textView = tv
        c.scrollView = scroll
        c.config = config
        tv.string = text
        storage.delegate = c
        tv.delegate = c
        tv.onClick = { [weak c] index in c?.handleClick(at: index) }
        tv.onHover = { [weak c] index in c?.handleHover(at: index) }
        c.applyConfig(config, force: true)
        model.editor = c
        model.scheduleAnalysis()
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.textBinding = $text
        guard let tv = c.textView else { return }
        if tv.string != text {
            // External change (revert, reload from disk).
            tv.string = text
            model.textDidChange()
        }
        c.applyConfig(config, force: false)
    }
}

@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, EditorController {
    let model: WorkspaceModel
    var textBinding: Binding<String>
    weak var textView: TersoTextView?
    weak var scrollView: NSScrollView?
    var config: EditorConfig?
    var popover: NSPopover?
    /// Clusters currently drawn, for hit-testing clicks and hovers.
    var clusters: [AnnotationCluster] = []

    init(model: WorkspaceModel, text: Binding<String>) {
        self.model = model
        self.textBinding = text
    }

    // MARK: EditorController / TextMutationTarget

    var currentSnapshot: DocumentSnapshot {
        DocumentSnapshot(revision: model.revision, text: textView?.string ?? "", fileName: model.fileURL?.lastPathComponent)
    }

    var selection: TextSpan { TextSpan(textView?.selectedRange() ?? NSRange(location: 0, length: 0)) }
    var undoManager: UndoManager? { textView?.undoManager }

    func replace(_ range: TextSpan, with text: String, actionName: String) {
        guard let tv = textView, range.upperBound <= (tv.string as NSString).length else { return }
        guard tv.shouldChangeText(in: range.nsRange, replacementString: text) else { return }
        tv.textStorage?.replaceCharacters(in: range.nsRange, with: text)
        tv.didChangeText()
        tv.undoManager?.setActionName(actionName)
    }

    func reveal(_ range: TextSpan, select: Bool) {
        guard let tv = textView, range.upperBound <= (tv.string as NSString).length else { return }
        tv.scrollRangeToVisible(range.nsRange)
        if select { tv.setSelectedRange(range.nsRange) }
        // No find-indicator flash: the selected finding's fill marks the place.
    }

    func wrapSelection(prefix: String, suffix: String, placeholder: String) {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        let inner = sel.length > 0 ? ns.substring(with: sel) : placeholder
        // Toggle off when already wrapped.
        if sel.length > 0, inner.hasPrefix(prefix), inner.hasSuffix(suffix), inner.count >= prefix.count + suffix.count {
            let stripped = String(inner.dropFirst(prefix.count).dropLast(suffix.count))
            replace(TextSpan(sel), with: stripped, actionName: "Format")
            tv.setSelectedRange(NSRange(location: sel.location, length: stripped.utf16Length))
            return
        }
        replace(TextSpan(sel), with: prefix + inner + suffix, actionName: "Format")
        tv.setSelectedRange(NSRange(location: sel.location + prefix.utf16Length, length: inner.utf16Length))
    }

    func prefixLines(_ marker: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let lines = ns.lineRange(for: tv.selectedRange())
        let block = ns.substring(with: lines)
        let parts = block.components(separatedBy: "\n")
        let hasTrailingNewline = block.hasSuffix("\n")
        let body = hasTrailingNewline ? Array(parts.dropLast()) : parts
        let allMarked = body.allSatisfy { $0.hasPrefix(marker) || $0.isEmpty }
        var n = 0
        let out = body.map { line -> String in
            if line.isEmpty { return line }
            if allMarked { return String(line.dropFirst(marker.count)) }
            n += 1
            let m = marker == "1. " ? "\(n). " : marker
            return m + line
        }.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        replace(TextSpan(lines), with: out, actionName: "Format")
    }

    // MARK: Text view delegate

    func textDidChange(_ notification: Notification) {
        guard let tv = textView else { return }
        textBinding.wrappedValue = tv.string
        model.textDidChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        applyDimming()
        if model.typewriter { centerCaret() }
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Text storage delegate callbacks arrive on the main thread for a text view's storage.
        nonisolated(unsafe) let textStorage = textStorage
        MainActor.assumeIsolated {
            let full = textStorage.length < 150_000
            let ns = textStorage.string as NSString
            let r = full ? NSRange(location: 0, length: ns.length) : ns.paragraphRange(for: editedRange)
            MarkdownStyler.style(textStorage, range: r, config: config)
        }
    }

    // MARK: Configuration and decorations

    func applyConfig(_ new: EditorConfig, force: Bool) {
        guard let tv = textView else { return }
        let old = config
        config = new
        tv.columnWidth = new.columnWidth
        tv.typewriter = new.typewriter
        tv.isAutomaticQuoteSubstitutionEnabled = new.smartQuotes
        let styleChanged = force || old?.font != new.font || old?.fontSize != new.fontSize || old?.lineSpacing != new.lineSpacing || old?.syntax != new.syntax
        if styleChanged, let storage = tv.textStorage {
            storage.beginEditing()
            MarkdownStyler.style(storage, range: NSRange(location: 0, length: storage.length), config: new)
            storage.endEditing()
            tv.typingAttributes = MarkdownStyler.baseAttributes(new)
        }
        if force || old?.focusMode != new.focusMode || old?.dimInactive != new.dimInactive || old?.typewriter != new.typewriter {
            popover?.close()
            refreshDecorations()
            applyDimming()
            if new.typewriter { DispatchQueue.main.async { self.centerCaret() } }
        }
    }

    func applyDimming() {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        let ns = tv.string as NSString
        let all = NSRange(location: 0, length: ns.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        guard model.focusMode, config?.dimInactive == true, ns.length > 0 else { return }
        lm.addTemporaryAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, forCharacterRange: all)
        let sel = tv.selectedRange()
        let current = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: sel.length))
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: current)
    }

    func centerCaret() {
        guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer, let scroll = scrollView else { return }
        let ns = tv.string as NSString
        let loc = min(tv.selectedRange().location, ns.length)
        let glyph = lm.glyphIndexForCharacter(at: max(0, loc == ns.length ? loc - 1 : loc))
        var rect = ns.length == 0 ? .zero : lm.lineFragmentRect(forGlyphAt: min(glyph, max(0, lm.numberOfGlyphs - 1)), effectiveRange: nil)
        rect.origin.y += tv.textContainerOrigin.y
        _ = container
        let clip = scroll.contentView
        let y = max(0, rect.midY - clip.bounds.height / 2)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        }
        scroll.reflectScrolledClipView(clip)
    }
}
