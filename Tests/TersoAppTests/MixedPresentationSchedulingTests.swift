// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import TersoApp

@Suite @MainActor struct MixedPresentationSchedulingTests {
    @Test func latexTitleMetadataFollowsEditorSelectionAndSourceMode() {
        let source = "\\documentclass{book}\n\\usepackage{geometry}\n\\title{Title}\n\\author{Writer}\n\\begin{document}\n\\maketitle\nBody."
        let fixture = Fixture(source, elements: [.blocks], latex: true)
        defer { fixture.coordinator.mathTask?.cancel() }
        let ns = source as NSString
        func hidden(_ needle: String) -> Bool {
            fixture.layout.hiddenSyntax.contains { NSIntersectionRange($0, ns.range(of: needle)).length > 0 }
        }
        fixture.select(ns.range(of: "Body."))
        #expect(hidden("\\documentclass") && hidden("\\title") && hidden("\\author"))
        fixture.select(ns.range(of: "\\maketitle"))
        #expect(hidden("\\documentclass") && hidden("\\usepackage"))
        #expect(!hidden("\\title") && !hidden("\\author"))
        fixture.select(ns.range(of: "Writer"))
        #expect(!hidden("\\title") && !hidden("\\author"))
        fixture.select(ns.range(of: "Body."))
        #expect(hidden("\\title") && hidden("\\author"))
        var config = fixture.coordinator.config!
        config.renderMode = .source
        fixture.coordinator.applyConfig(config, force: false)
        #expect(fixture.layout.hiddenSyntax.isEmpty)
        #expect(fixture.storage.string == source)
    }

    @Test func externallyCancelledRenderingRestartsOnTheSameLine() {
        let fixture = Fixture("**bold**\nAfter", elements: [.emphasis])
        let pending = Task<Void, Never> {}
        fixture.coordinator.mathTask = pending
        pending.cancel()
        fixture.select(NSRange(location: 2, length: 0))
        #expect(fixture.coordinator.mathTask?.isCancelled == false)
        fixture.coordinator.mathTask?.cancel()
    }

    @Test func movingWithinRevealedLinesKeepsPendingRendering() {
        let fixture = Fixture("Before\nA **bold** result\nAfter", elements: [.emphasis])
        let ns = fixture.view.string as NSString
        let bold = ns.range(of: "bold")
        fixture.select(NSRange(location: bold.location, length: 0))
        #expect(fixture.layout.hiddenSyntax.isEmpty)

        let pending = Task<Void, Never> {}
        fixture.coordinator.mathTask = pending
        defer { fixture.coordinator.mathTask?.cancel() }
        fixture.select(NSRange(location: bold.location + 2, length: 0))
        #expect(!pending.isCancelled)
        fixture.select(bold)
        #expect(!pending.isCancelled)

        fixture.select(NSRange(location: ns.range(of: "After").location, length: 0))
        #expect(pending.isCancelled)
        #expect(fixture.layout.hiddenSyntax.count == 2)
        #expect(fixture.view.string == ns as String)
    }

    @Test func multilineWrappersAndSelectionsStillRevealTheirSource() {
        let source = "Before\n<!-- first\nsecond -->\nAfter"
        let fixture = Fixture(source, elements: [.comments])
        let ns = source as NSString
        let first = ns.range(of: "first")
        let second = ns.range(of: "second")
        let after = ns.range(of: "After")
        fixture.select(NSRange(location: after.location, length: 0))
        #expect(fixture.layout.hiddenSyntax.count == 2)
        fixture.select(NSRange(location: first.location, length: 0))
        #expect(fixture.layout.hiddenSyntax.isEmpty)
        fixture.select(NSRange(location: second.location, length: 0))
        #expect(fixture.layout.hiddenSyntax.isEmpty)

        let pending = Task<Void, Never> {}
        fixture.coordinator.mathTask = pending
        defer { fixture.coordinator.mathTask?.cancel() }
        fixture.select(NSRange(location: first.location, length: after.location - first.location))
        #expect(pending.isCancelled)
        #expect(fixture.layout.hiddenSyntax.isEmpty)
        fixture.select(NSRange(location: after.location, length: 0))
        #expect(fixture.layout.hiddenSyntax.count == 2)
    }

    @Test func configGeometryAndLeavingMixedReplacePendingWork() throws {
        let fixture = Fixture("**bold**\nAfter", elements: [.emphasis])
        defer { fixture.coordinator.mathTask?.cancel() }
        let geometryTask = Task<Void, Never> {}
        fixture.coordinator.mathTask = geometryTask
        let container = try #require(fixture.view.textContainer)
        container.size.width = 400
        fixture.coordinator.updateMathPresentation()
        #expect(geometryTask.isCancelled)

        let configTask = Task<Void, Never> {}
        fixture.coordinator.mathTask = configTask
        var config = try #require(fixture.coordinator.config)
        config.fontSize += 1
        fixture.coordinator.applyConfig(config, force: false)
        #expect(configTask.isCancelled)

        let sourceTask = Task<Void, Never> {}
        fixture.coordinator.mathTask = sourceTask
        config.renderMode = .source
        fixture.coordinator.applyConfig(config, force: false)
        #expect(sourceTask.isCancelled)
        #expect(fixture.coordinator.mathPresentationRequest == nil)
        #expect(fixture.layout.hiddenSyntax.isEmpty)
    }

    @Test func renderingInputsInvalidateTheSameLineRequest() {
        let source = "😀 **bold**\r\nNext"
        let model = WorkspaceModel()
        var config = EditorConfig(prefs: model.prefs, model: model)
        config.mixedRendered = [.emphasis]
        let directory = URL(fileURLWithPath: "/tmp/terso-one", isDirectory: true)
        func request(_ text: String? = nil, selection: NSRange = NSRange(location: 3, length: 0),
                     config overrideConfig: EditorConfig? = nil, width: Double = 600, dark: Bool = false,
                     directory overrideDirectory: URL? = nil) -> MixedPresentationRequest {
            MixedPresentationRequest(source: text ?? source, selection: selection, config: overrideConfig ?? config,
                                     width: width, dark: dark, directory: overrideDirectory ?? directory)
        }
        let original = request()
        #expect(original == request(selection: NSRange(location: 7, length: 2)))
        #expect(original != request(selection: NSRange(location: (source as NSString).length, length: 0)))
        #expect(original != request(source + "!"))
        #expect(original != request(width: 500))
        #expect(original != request(dark: true))
        #expect(original != request(directory: URL(fileURLWithPath: "/tmp/terso-two", isDirectory: true)))
        var changed = config
        changed.fontSize += 1
        #expect(original != request(config: changed))
        changed = config
        changed.mixedRendered = []
        #expect(original != request(config: changed))
    }

    @MainActor private struct Fixture {
        let coordinator: EditorCoordinator
        let view: TersoTextView
        let storage: NSTextStorage
        let layout: MathLayoutManager

        init(_ source: String, elements: Set<MixedElement>, latex: Bool = false) {
            let model = WorkspaceModel()
            model.renderMode = .mixed
            coordinator = EditorCoordinator(model: model, text: .constant(source))
            storage = NSTextStorage(string: source)
            layout = MathLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(width: 700, height: 2000))
            layout.addTextContainer(container)
            view = TersoTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
            coordinator.textView = view
            model.editor = coordinator
            view.delegate = coordinator
            storage.delegate = coordinator
            var config = EditorConfig(prefs: model.prefs, model: model, latex: latex)
            config.columnWidth = 700
            config.mixedRendered = elements
            coordinator.applyConfig(config, force: true)
        }

        func select(_ range: NSRange) {
            view.setSelectedRange(range)
            coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
        }
    }
}
