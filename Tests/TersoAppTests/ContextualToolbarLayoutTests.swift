// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import TersoApp

@Suite @MainActor struct ContextualToolbarLayoutTests {
    @Test func defaultPlacementAndLegacyChoicesArePreserved() {
        #expect(ContextualToolbarPlacement(savedValue: nil) == .floating)
        #expect(ContextualToolbarPlacement(savedValue: "floating") == .floating)
        #expect(ContextualToolbarPlacement(savedValue: "secondRow") == .secondRow)
        #expect(ContextualToolbarPlacement(savedValue: "hidden") == .hidden)
        #expect(ContextualToolbarEdge(savedValue: nil) == .bottom)
        #expect(ContextualToolbarEdge(savedValue: "left").isVertical)
        #expect(ContextualToolbarEdge(savedValue: "right").isVertical)
        #expect(!ContextualToolbarEdge(savedValue: "top").isVertical)
        for edge in ContextualToolbarEdge.allCases {
            #expect(ContextualToolbarEdge(savedValue: edge.rawValue) == edge)
        }
    }

    @Test func verticalToolbarFitsShortEditorsInEveryRenderingMode() throws {
        let document = TabDocument()
        defer { document.close() }
        for mode in RenderMode.allCases {
            document.model.renderMode = mode
            for height in [200.0, 280, 600] {
                let controller = NSHostingController(rootView: ContextualToolbar(document: document, floating: true, vertical: true))
                let size = controller.sizeThatFits(in: CGSize(width: 60, height: height))
                #expect(size.width <= 60, "\(mode) at height \(height): \(size)")
                #expect(size.height <= height, "\(mode) at height \(height): \(size)")
                #expect(size.height > size.width)
                try saveSnapshot(controller.view, size: CGSize(width: 60, height: height),
                                 name: "\(mode.rawValue)-vertical-\(Int(height))")
            }
        }
    }

    @Test func toolbarFitsNarrowEditorsInEveryRenderingMode() throws {
        let document = TabDocument()
        defer { document.close() }
        for mode in RenderMode.allCases {
            document.model.renderMode = mode
            for floating in [false, true] {
                for width in [256.0, 400, 1000] {
                    let controller = NSHostingController(rootView: ContextualToolbar(document: document, floating: floating))
                    let size = controller.sizeThatFits(in: CGSize(width: width, height: 80))
                    #expect(size.width <= width, "\(mode) floating=\(floating) at \(width): \(size)")
                    #expect(size.height <= 60)
                    try saveSnapshot(controller.view, size: CGSize(width: width, height: 64),
                                     name: "\(mode.rawValue)-\(floating)-\(Int(width))")
                }
            }
        }
    }

    private func saveSnapshot(_ view: NSView, size: CGSize, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TERSO_TOOLBAR_SNAPSHOTS"] else { return }
        view.frame = CGRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
