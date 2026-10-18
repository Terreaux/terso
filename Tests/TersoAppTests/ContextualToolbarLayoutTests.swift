// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import TersoApp

@Suite @MainActor struct ContextualToolbarLayoutTests {
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
                    if let directory = ProcessInfo.processInfo.environment["TERSO_TOOLBAR_SNAPSHOTS"] {
                        let view = controller.view
                        view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: 64))
                        view.appearance = NSAppearance(named: .darkAqua)
                        view.layoutSubtreeIfNeeded()
                        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        let folder = URL(fileURLWithPath: directory, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try data.write(to: folder.appendingPathComponent("\(mode.rawValue)-\(floating)-\(Int(width)).png"))
                    }
                }
            }
        }
    }
}
