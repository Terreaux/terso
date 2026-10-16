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
    var renderMode: RenderMode
    var syntax: SyntaxVisibility
    var smartQuotes: Bool
    var focusMode: Bool
    var typewriter: Bool
    var dimInactive: Bool
    var theme: EditorTheme
    var mixedRendered: Set<MixedElement>
    /// Manutius: book pages, justified and hyphenated, at a book measure,
    /// set as the book design asks.
    var book: BookDesign?
    /// The editor's own size, which sets the scale of a book's pages while
    /// `fontSize` is the book's type.
    var pageScale: Double
    /// TeX source: styled as LaTeX rather than Markdown.
    var latex: Bool

    @MainActor init(prefs: Preferences, model: WorkspaceModel, latex: Bool = false) {
        self.latex = latex
        renderMode = model.renderMode
        font = prefs.font; fontSize = prefs.fontSize; lineSpacing = prefs.lineSpacing
        columnWidth = prefs.columnWidth; syntax = prefs.syntax; smartQuotes = prefs.smartQuotes
        focusMode = model.focusMode; typewriter = model.typewriter; dimInactive = prefs.dimInactiveParagraphs
        theme = prefs.theme; mixedRendered = prefs.mixedRendered
        book = model.manutius ? model.bookDesign : nil
        pageScale = prefs.fontSize
        if let book {
            font = book.typeface ?? prefs.font
            fontSize = book.screenSize(editorSize: prefs.fontSize)
            lineSpacing = book.lineSpacing
        }
    }
}

final class TersoTextView: NSTextView {
    var documentUndoManager: UndoManager?
    override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }
    var columnWidth: CGFloat = 700 { didSet { updateInsets() } }
    var typewriter = false { didSet { updateInsets() } }
    var onGeometryChange: (() -> Void)?
    var onClick: ((Int) -> Void)?
    /// Character index under the pointer (nil when not over text).
    var onHover: ((Int?) -> Void)?
    /// Items put at the top of the context menu for the character clicked
    /// (spelling corrections, since the system checker is off here).
    var contextItems: ((Int) -> [NSMenuItem])?
    /// New words typed: keyboard, dictation and input methods only.
    var onTypedWords: ((Int) -> Void)?
    private var hoverArea: NSTrackingArea?

    var reviewPassageRange: NSRange? { didSet { needsDisplay = true } }
    /// The book as designed; `book` is it as laid out here, in spreads when
    /// the design asks for facing pages and the view has room for two.
    var bookLayout: BookPage? { didSet { if bookLayout != oldValue { updateSpread() } } }
    private(set) var book: BookPage? {
        didSet {
            guard book != oldValue else { return }
            updateInsets()
            (textContainer as? PagedTextContainer)?.book = book
            needsDisplay = true
            setFrameSize(frame.size)
        }
    }
    var facingPages = true { didSet { if facingPages != oldValue { updateSpread() } } }

    private func updateSpread() {
        book = bookLayout.map { page in
            var page = page
            page.spread = false
            var spread = page
            spread.spread = true
            page.spread = facingPages && bounds.width >= spread.viewWidth + 48
            return page
        }
    }
    var bookDecoration = BookDecoration() { didSet { if book != nil { needsDisplay = true } } }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let book {
            drawBookPages(book, in: rect, decoration: bookDecoration)
            drawBookOrnaments(book, in: rect, decoration: bookDecoration)
        }
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
        HighlightStyle.passageAccent.withAlphaComponent(contrast ? 0.14 : 0.08).setFill()
        NSBezierPath(roundedRect: paragraphRect, xRadius: 4, yRadius: 4).fill()
        HighlightStyle.passageAccent.setFill()
        NSBezierPath(roundedRect: NSRect(x: paragraphRect.minX, y: paragraphRect.minY,
                                        width: 4, height: paragraphRect.height), xRadius: 2, yRadius: 2).fill()
    }

    /// NSTextView moves the container up to where its text starts; a book's
    /// pages start at the top, with front matter before any text.
    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return book == nil ? origin : NSPoint(x: origin.x, y: textContainerInset.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        var newSize = newSize
        // The last page is shown whole, however little text is on it, and
        // the back matter after it.
        if let book, let lm = layoutManager, let container = textContainer {
            let rows = bookPageTotal(book).map(book.rows) ?? book.pages(through: lm.usedRect(for: container).maxY)
            newSize.height = max(newSize.height, textContainerOrigin.y * 2 + CGFloat(rows) * book.stride)
        }
        super.setFrameSize(newSize)
        if widthChanged, bookLayout != nil { updateSpread() }
        updateInsets()
        if widthChanged { DispatchQueue.main.async { [weak self] in self?.onGeometryChange?() } }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onGeometryChange?()
    }

    func updateInsets() {
        let h = max(28, (bounds.width - (book?.containerWidth ?? columnWidth)) / 2)
        let visible = enclosingScrollView?.contentView.bounds.height ?? 600
        let v: CGFloat = typewriter ? visible / 2 : 56
        let inset = NSSize(width: h.rounded(), height: v.rounded())
        if textContainerInset != inset { textContainerInset = inset }
    }

    // Paste, drops and programmatic edits don't come through here.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        let ns = self.string as NSString
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let before = range.location > 0 ? Character(ns.substring(with: ns.rangeOfComposedCharacterSequence(at: range.location - 1))) : nil
        let end = NSMaxRange(range)
        let after = end < ns.length ? Character(ns.substring(with: ns.rangeOfComposedCharacterSequence(at: end))) : nil
        super.insertText(string, replacementRange: replacementRange)
        let words = TypedWords.count(typed, before: before, after: after)
        if words > 0 { onTypedWords?(words) }
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let index = characterIndex(under: convert(event.locationInWindow, from: nil)),
              let items = contextItems?(index), !items.isEmpty else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, toggleTask(at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        onClick?(characterIndexForInsertion(at: point))
    }

    /// A click on a drawn task checkbox ticks it in the source, leaving the
    /// caret where it was so the checkbox stays drawn.
    private func toggleTask(at point: NSPoint) -> Bool {
        guard isEditable, let layout = layoutManager as? MathLayoutManager, let container = textContainer else { return false }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
        let index = layout.characterIndexForGlyph(at: glyph)
        guard let item = layout.rendered.first(where: { $0.range.location == index && $0.toggle != nil }), let box = item.toggle,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return false }
        let ticked = (string as NSString).substring(with: box).lowercased() == "[x]" ? "[ ]" : "[x]"
        guard shouldChangeText(in: box, replacementString: ticked) else { return false }
        textStorage?.replaceCharacters(in: box, with: ticked)
        didChangeText()
        undoManager?.setActionName("Toggle Task")
        return true
    }
}

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    let model: WorkspaceModel
    let config: EditorConfig

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(model: model, text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = MathLayoutManager()
        storage.addLayoutManager(layout)
        let container = PagedTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
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
        tv.documentUndoManager = model.documentUndoManager
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
        tv.onGeometryChange = { [weak c] in c?.updateMathPresentation() }
        tv.onClick = { [weak c] index in c?.handleClick(at: index) }
        tv.onHover = { [weak c] index in c?.handleHover(at: index) }
        tv.contextItems = { [weak c] index in c?.spellingMenuItems(at: index) ?? [] }
        tv.onTypedWords = { [weak c] words in
            guard let c else { return }
            WritingStats.shared.record(words, in: c.model.fileURL)
        }
        c.applyConfig(config, force: true)
        model.editor = c
        model.refreshDocumentBook()
        model.scheduleAnalysis()
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: EditorCoordinator) {
        coordinator.mathTask?.cancel()
        coordinator.popover?.close()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.textBinding = $text
        guard let tv = c.textView else { return }
        if tv.string != text {
            // External change (revert, reload from disk).
            tv.string = text
            model.textDidChange()
            c.updateMathPresentation()
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
    let mathRenderer = MathImageRenderer()
    let imageLoader = InlineImageLoader()
    var mathTask: Task<Void, Never>?
    var outlineTask: Task<Void, Never>?
    var mathSource = ""
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
        if model.renderMode == .preview {
            model.renderMode = .mixed
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
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
        updateMathPresentation()
        if tv.book != nil { scheduleBookOutline() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateMathPresentation()
        applyDimming()
        if model.typewriter { centerCaret() }
        if textView?.book != nil { refreshBookPosition() }
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Text storage delegate callbacks arrive on the main thread for a text view's storage.
        nonisolated(unsafe) let textStorage = textStorage
        MainActor.assumeIsolated {
            if let layout = textView?.layoutManager as? MathLayoutManager {
                layout.processCharacterEdit(range: editedRange, changeInLength: delta)
                mathSource = textStorage.string
            }
            let full = textStorage.length < 150_000
            let ns = textStorage.string as NSString
            let r = full ? NSRange(location: 0, length: ns.length) : ns.paragraphRange(for: editedRange)
            MarkdownStyler.style(textStorage, range: r, config: config)
            // A full restyle relays every line, so the book's chapters only
            // need relaying themselves in a long document.
            applyBook(editedAt: editedRange.location, restyledAll: full)
        }
    }

    // MARK: Configuration and decorations

    func applyConfig(_ new: EditorConfig, force: Bool) {
        guard let tv = textView else { return }
        let old = config
        config = new
        tv.isEditable = new.renderMode != .preview
        if old?.renderMode == .preview, new.renderMode != .preview {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        var page = new.book.map { BookPage(trim: $0.trim, fontSize: new.pageScale) }
        page?.front = tv.bookLayout?.front ?? 0
        page?.back = tv.bookLayout?.back ?? 0
        tv.columnWidth = page?.column ?? CGFloat(new.columnWidth)
        (tv.textContainer as? PagedTextContainer)?.opener = new.book?.openers ?? .continuous
        tv.facingPages = new.book?.facingPages ?? true
        tv.bookLayout = page
        tv.typewriter = new.typewriter
        tv.isAutomaticQuoteSubstitutionEnabled = new.smartQuotes
        if force || old?.theme != new.theme {
            tv.backgroundColor = new.theme.background
            scrollView?.backgroundColor = new.theme.background
            tv.insertionPointColor = new.theme.accent
            tv.selectedTextAttributes = [.backgroundColor: new.theme.palette.map { $0.accent.withAlphaComponent(0.3) } ?? .selectedTextBackgroundColor]
        }
        let styleChanged = force || old?.renderMode != new.renderMode || old?.font != new.font || old?.fontSize != new.fontSize || old?.lineSpacing != new.lineSpacing || old?.syntax != new.syntax || old?.theme != new.theme || old?.book != new.book
        if styleChanged, let storage = tv.textStorage {
            storage.beginEditing()
            MarkdownStyler.style(storage, range: NSRange(location: 0, length: storage.length), config: new)
            storage.endEditing()
            tv.typingAttributes = MarkdownStyler.baseAttributes(new)
        }
        if styleChanged { applyBook(); scheduleBookOutline() }
        if styleChanged || old?.columnWidth != new.columnWidth || old?.mixedRendered != new.mixedRendered || old?.latex != new.latex { updateMathPresentation() }
        if force || old?.focusMode != new.focusMode || old?.dimInactive != new.dimInactive || old?.typewriter != new.typewriter {
            popover?.close()
            refreshDecorations()
            applyDimming()
            if new.typewriter { DispatchQueue.main.async { self.centerCaret() } }
        }
    }

    /// Manutius's chapters: where headings open a page, which lines stand
    /// beside a drop cap, and what the pages draw around the text.
    /// When they change the text is laid out again: at once, or after an
    /// edit at `editedAt` once the layout manager has seen it — unless the
    /// edit restyled, and so relays, everything anyway.
    func applyBook(editedAt location: Int? = nil, restyledAll: Bool = false) {
        guard let tv = textView, let container = tv.textContainer as? PagedTextContainer else { return }
        let ns = tv.string as NSString
        var decoration = BookDecoration()
        var openers: Set<Int> = []
        var caps: [DropCapSpan] = []
        if let config, var design = config.book, !config.latex {
            // Source shows the text as written: no drawn caps or numerals.
            if config.renderMode == .source { design.dropCaps = false; design.headings = .plain }
            let chapters = BookChapter.scan(tv.string)
            let body = config.font.font(size: config.fontSize)
            let spacing = config.fontSize * max(0, config.lineSpacing - 1)
            openers = Set(chapters.flatMap(\.lineStarts))
            if design.dropCaps {
                caps = chapters.compactMap { chapter in
                    chapter.initial(in: ns).map { initial in
                        let cap = DropCap(letter: ns.substring(with: initial), body: body, lineSpacing: spacing)
                        return DropCapSpan(opening: initial.location, end: chapter.end, indent: cap.indent, depth: cap.depth)
                    }
                }
            }
            let meta = BookMetadata.read(tv.string)
            let matter = config.renderMode == .source ? (front: [], back: []) : MatterPage.layout(design.matter, meta: meta, chapters: chapters.count)
            decoration = BookDecoration(design: design, title: bookTitle(tv.string), chapters: chapters,
                                        font: body, ink: config.theme.bodyInk, lineSpacing: spacing,
                                        front: matter.front, back: matter.back, metadata: meta, face: config.font.title)
        }
        let changed = openers != container.openers || caps != container.dropCaps
        container.openers = openers
        container.dropCaps = caps
        tv.bookDecoration = decoration
        // Front and back matter change the pages, so the text is laid out
        // again by the new geometry.
        if var page = tv.bookLayout, page.front != decoration.front.count || page.back != decoration.back.count {
            page.front = decoration.front.count
            page.back = decoration.back.count
            if let location { DispatchQueue.main.async { [weak tv] in tv?.bookLayout = page } } else { tv.bookLayout = page }
            return
        }
        guard changed, !restyledAll else { return }
        guard let location else { tv.layoutManager?.textContainerChangedGeometry(container); return }
        // Inside an edit the layout manager has not yet seen the new text.
        DispatchQueue.main.async { [weak tv] in
            guard let tv, let lm = tv.layoutManager else { return }
            let length = (tv.string as NSString).length
            let from = min(location, length)
            lm.invalidateLayout(forCharacterRange: NSRange(location: from, length: length - from), actualCharacterRange: nil)
            tv.needsDisplay = true
        }
    }

    /// The running head's title: the metadata's `title`, or the file's name.
    func bookTitle(_ text: String) -> String? {
        if let fm = MarkdownSyntax.frontMatter(in: text) {
            let meta = (text as NSString).substring(with: fm)
            if let m = try? NSRegularExpression(pattern: #"^title[ \t]*[:=][ \t]*["']?(.+?)["']?[ \t]*$"#, options: .anchorsMatchLines)
                .firstMatch(in: meta, range: NSRange(location: 0, length: (meta as NSString).length)) {
                return (meta as NSString).substring(with: m.range(at: 1))
            }
        }
        return model.fileURL?.deletingPathExtension().lastPathComponent
    }

    func applyDimming() {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        let ns = tv.string as NSString
        let all = NSRange(location: 0, length: ns.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        applyFindingText()
        guard model.focusMode, config?.dimInactive == true, ns.length > 0 else { return }
        lm.addTemporaryAttribute(.foregroundColor, value: config?.theme.tertiary ?? .tertiaryLabelColor, forCharacterRange: all)
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
