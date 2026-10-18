// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
import TersoCore
@testable import TersoApp

@Suite(.serialized) @MainActor struct AIStyleHighlightTests {
    @Test func latexCommaSignalsAreVisibleAndLayerToggleRemovesThem() async throws {
        _ = NSApplication.shared
        let source = """
        \\documentclass{article}
        \\begin{document}
        We paused, looked, listened, waited, and then crossed the room.
        Along the road, through the trees, past the gate, we walked home.
        The sun fell, the wind rose, the leaves moved, and the birds returned.
        \\end{document}
        """
        let model = WorkspaceModel()
        let oldLayers = model.prefs.enabledLayers, oldDomain = model.prefs.domain
        model.prefs.enabledLayers.insert(.aiStyle)
        model.prefs.domain = .general
        defer {
            model.prefs.enabledLayers = oldLayers
            model.prefs.domain = oldDomain
        }
        model.fileURL = URL(fileURLWithPath: "/tmp/ai-style-highlight.tex")
        let storage = NSTextStorage(string: source)
        let layout = MathLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 720, height: 2000))
        layout.addTextContainer(container)
        let view = TersoTextView(frame: NSRect(x: 0, y: 0, width: 850, height: 460), textContainer: container)
        view.documentUndoManager = UndoManager()
        view.allowsUndo = true
        view.setSelectedRange(NSRange(location: storage.length, length: 0))
        let coordinator = EditorCoordinator(model: model, text: .constant(source))
        coordinator.textView = view
        model.editor = coordinator
        defer { coordinator.mathTask?.cancel() }
        var config = EditorConfig(prefs: model.prefs, model: model, latex: true)
        config.fontSize = 22
        config.columnWidth = 720
        coordinator.applyConfig(config, force: true)
        model.scheduleAnalysis()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.style == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let signal = try #require(model.drawnAnnotations.first { $0.metadata["feature"] == "commas_1k" })
        #expect(signal.ranges.count > 1)
        let comma = try #require(signal.ranges.first)
        #expect((source as NSString).substring(with: comma.nsRange) == ",")
        coordinator.refreshDecorations()
        #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: comma.location, effectiveRange: nil) != nil)
        #expect(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: comma.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: comma.upperBound, effectiveRange: nil) == nil)
        #expect(view.string == source)
        #expect(view.undoManager?.canUndo == false)

        if let directory = ProcessInfo.processInfo.environment["TERSO_AI_HIGHLIGHT_SNAPSHOTS"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for theme in [EditorTheme.light, .dark] {
                view.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
                config.theme = theme
                coordinator.applyConfig(config, force: true)
                coordinator.refreshDecorations()
                layout.ensureLayout(for: container)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("latex-ai-\(theme.rawValue).png"))
            }
        }
        model.setLayers([.aiStyle], visible: false)
        #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: comma.location, effectiveRange: nil) == nil)
        #expect(view.string == source)
        #expect(view.undoManager?.canUndo == false)
    }

    @Test func sentenceUnderlinesStayQuietAndSelectionRemainsStronger() throws {
        let sentence = HighlightStyle.passive(.complexity, quiet: true, contrast: false)
        #expect(sentence[.backgroundColor] == nil)
        let signal = HighlightStyle.passive(.aiStyle, quiet: true, contrast: false)
        let selected = HighlightStyle.selected(.aiStyle, blockLevel: false, contrast: false)
        let tint = try #require(signal[.backgroundColor] as? NSColor)
        let selectedTint = try #require(selected[.backgroundColor] as? NSColor)
        #expect(tint.alphaComponent > 0 && tint.alphaComponent < selectedTint.alphaComponent)
    }
}
