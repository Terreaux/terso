// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import TersoCore

extension EditorCoordinator {
    /// Hover: stronger underline plus a small tooltip. Never opens UI.
    func handleHover(at index: Int?) {
        let cluster = index.flatMap { i in clusters.first { $0.contains(i) } }
        guard cluster?.id != model.hoveredClusterID else {
            if cluster == nil { setToolTip(unrenderedTip(at: index)) }
            return
        }
        model.hoveredClusterID = cluster?.id
        setToolTip(cluster.map { c in
            let names = c.annotationIDs.compactMap { model.annotation(id: $0)?.message }
            let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return unique.joined(separator: " · ") + " — click to review"
        } ?? unrenderedTip(at: index))
        applyHighlights()
    }

    /// Setting the same tip again would restart its delay on every mouse move.
    private func setToolTip(_ tip: String?) {
        if textView?.toolTip != tip { textView?.toolTip = tip }
    }

    /// "GitHub doesn't render highlights" over syntax Mixed marks.
    private func unrenderedTip(at index: Int?) -> String? {
        guard let index, let marks = (textView?.layoutManager as? MathLayoutManager)?.flavourMarks,
              let mark = marks.first(where: { NSLocationInRange(index, $0.range) }) else { return nil }
        let flavour = model.markdownFlavour
        let title = mark.feature == .alerts && flavour.features.contains(.alerts) ? "this kind of callout" : mark.feature.title
        return "\(flavour.title) doesn't render \(title); it's published as typed"
    }

    /// Click on a finding: select it everywhere. With the inspector open the
    /// Review list follows; otherwise a compact card appears at the text.
    func handleClick(at index: Int) {
        let inCluster = clusters.contains { $0.contains(index) }
        let candidates = model.drawnAnnotations.filter { !AnnotationLayout.isBlockLevel($0) }
        let scienceCandidates = model.inspectorTab == .science ? candidates.filter { $0.metadata["scienceDiagnosticID"] != nil } : []
        guard inCluster, let hit = AnnotationLayout.primary(at: index, in: scienceCandidates)
                ?? AnnotationLayout.primary(at: index, in: candidates) else {
            popover?.close()
            // Placing the caret elsewhere clears the selection, except while
            // stepping through Focused Review.
            if model.activeAnnotationID != nil, !model.focusedReview { model.select(nil, reveal: false) }
            return
        }
        if model.showInspector, model.inspectorTab == .science,
           model.selectScienceAnnotation(hit, reveal: false) {
            popover?.close()
            return
        }
        model.select(hit, reveal: false)
        // Local findings open at the text, so one click on the word and one
        // on the fix is all it takes; Review still follows.
        if hit.source != .aiSuggestion {
            if model.showInspector { model.inspectorTab = .review }
            showPopover(for: hit, at: index)
        } else if model.showInspector {
            model.inspectorTab = hit.category == .aiSuggestion && model.review.isReviewMode ? .ai : .review
            popover?.close()
        } else {
            showPopover(for: hit, at: index)
        }
    }

    /// Keyboard route to the finding at the caret (⌘').
    func explainAtCaret() {
        guard let tv = textView else { return }
        let loc = tv.selectedRange().location
        let candidates = model.visibleAnnotations.filter { !AnnotationLayout.isBlockLevel($0) }
        let atCaret = AnnotationLayout.primary(at: loc, in: candidates)
        let hit = atCaret ?? (loc > 0 ? AnnotationLayout.primary(at: loc - 1, in: candidates) : nil)
        guard let hit else { NSSound.beep(); return }
        let anchor = atCaret == nil ? loc - 1 : loc
        if model.showInspector, model.inspectorTab == .science,
           model.selectScienceAnnotation(hit, reveal: false) { return }
        model.select(hit, reveal: false)
        if model.showInspector { model.inspectorTab = .review }
        if !model.showInspector || hit.source != .aiSuggestion { showPopover(for: hit, at: anchor) }
    }

    func showPopover(for annotation: TextAnnotation, at index: Int) {
        guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer else { return }
        popover?.close()
        let g = lm.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: g, in: container)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y
        let p = NSPopover()
        p.behavior = .transient
        p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let close: () -> Void = { [weak p] in p?.close() }
        p.contentViewController = NSHostingController(rootView: AnnotationCard(annotation: annotation, model: model,
                                                                         occurrence: annotation.ranges.firstIndex { $0.nsRange.contains(index) } ?? 0,
                                                                         close: close))
        p.show(relativeTo: rect, of: tv, preferredEdge: .maxY)
        popover = p
    }

    /// Fixes, plus Learn and Ignore, for the finding under the pointer:
    /// spelling first, else a writing finding that has one-click fixes.
    func spellingMenuItems(at index: Int) -> [NSMenuItem] {
        let here = model.visibleAnnotations.filter { a in a.ranges.contains { $0.nsRange.contains(index) } }
        let model = model
        func occurrence(_ a: TextAnnotation) -> Int { a.ranges.firstIndex { $0.nsRange.contains(index) } ?? 0 }
        guard let hit = here.first(where: { $0.source == .spelling })
                ?? here.first(where: { $0.source == .rule && !model.quickFixes(for: $0, occurrence: occurrence($0)).isEmpty })
        else { return [] }
        var items = model.quickFixes(for: hit, occurrence: occurrence(hit)).map { fix in
            ClosureMenuItem(fix.isRemoval ? "Remove “\(fix.original)”" : fix.proposed) { model.applyQuickFix(fix, to: hit) } as NSMenuItem
        }
        if items.isEmpty {
            let none = NSMenuItem(title: "No Guesses Found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        items.append(.separator())
        if hit.source == .spelling, let word = hit.metadata["word"] {
            items.append(ClosureMenuItem("Learn Spelling") {
                NSSpellChecker.shared.learnWord(word)
                model.ignore(hit)
                model.scheduleAnalysis()
            })
        }
        let ignore = hit.source != .spelling ? "Ignore \(hit.message)" : hit.metadata["word"] == nil ? "Ignore Grammar" : "Ignore Spelling"
        items.append(ClosureMenuItem(ignore) { model.ignore(hit) })
        return items
    }
}

/// A menu item that runs a closure, for menus built on the fly.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
