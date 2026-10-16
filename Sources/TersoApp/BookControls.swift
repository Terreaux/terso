// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// The header's book buttons: the design, which opens the inspector's Book
/// tab, and the whole book.
struct BookControls: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 2) {
            HeaderToggle(isOn: model.showInspector && model.inspectorTab == .book, help: "Book design: type, page, chapters, front and back matter") {
                if model.showInspector && model.inspectorTab == .book { model.showInspector = false } else { model.showBookDesign() }
            } label: { Image(systemName: "textformat.size") }
                .accessibilityLabel("Book design")
            HeaderToggle(isOn: model.showBookOverview, help: "Whole book: every page as spreads (⇧⌘B)") {
                model.showBookOverview = true
            } label: { Image(systemName: "book") }
                .accessibilityLabel("Whole book")
        }
    }
}

/// Every page at once, as a printed book opens: the first page alone on
/// the right, then verso and recto side by side. A click turns to the page.
struct BookOverview: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var pages = 0
    private static let thumb: CGFloat = 132

    private var editor: EditorCoordinator? { model.editor as? EditorCoordinator }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whole Book").font(.headline)
                    Text("\(pages) \(pages == 1 ? "page" : "pages") · \(model.bookDesign.trim.title)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.thumb * 2), spacing: 28), count: 2), spacing: 22) {
                    // Spread 0 is the first recto alone; spread n holds pages 2n-1 and 2n.
                    ForEach(0..<(pages / 2 + 1), id: \.self) { spread in
                        VStack(spacing: 4) {
                            HStack(spacing: 0) {
                                cell(spread == 0 ? nil : spread * 2 - 1)
                                cell(spread * 2 < pages ? spread * 2 : nil)
                            }
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: model.prefs.theme.background).opacity(0.6))
        }
        .frame(width: Self.thumb * 4 + 28 + 40 + 20, height: 620)
        .onAppear { pages = editor?.bookPageCount() ?? 0 }
    }

    @ViewBuilder private func cell(_ index: Int?) -> some View {
        if let index {
            BookPageThumbnail(index: index, width: Self.thumb, editor: editor) {
                editor?.revealBookPage(index)
                dismiss()
            }
        } else {
            Color.clear.frame(width: Self.thumb, height: Self.thumb * model.bookDesign.trim.aspect)
        }
    }
}

private struct BookPageThumbnail: View {
    let index: Int
    let width: CGFloat
    let editor: EditorCoordinator?
    let open: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottom) {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Rectangle().fill(.background)
                }
            }
            .frame(width: width, height: image.map { width * $0.size.height / max(1, $0.size.width) } ?? width * 1.5)
            .overlay(alignment: .bottom) {
                Text(editor?.textView?.book?.folio(index) ?? "\(index + 1)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .offset(y: 16)
            }
        }
        .buttonStyle(.plain)
        .help("Turn to page \(editor?.textView?.book?.folio(index) ?? "\(index + 1)")")
        .accessibilityLabel("Page \(editor?.textView?.book?.folio(index) ?? "\(index + 1)")")
        // Pages are drawn as they scroll into view, then kept.
        .task { if image == nil { image = editor?.bookPageImage(index, width: width) } }
    }
}

extension EditorCoordinator {
    /// Pages the whole text fills, laid out to the end.
    func bookPageCount() -> Int {
        guard let tv = textView, let book = tv.book, let lm = tv.layoutManager, let container = tv.textContainer else { return 0 }
        lm.ensureLayout(for: container)
        tv.setFrameSize(tv.frame.size)
        return tv.bookPageTotal(book) ?? book.pages(through: lm.usedRect(for: container).maxY)
    }

    /// One page as drawn in the editor, scaled down to `width` points.
    func bookPageImage(_ index: Int, width: CGFloat) -> NSImage? {
        guard let tv = textView, let book = tv.book else { return nil }
        let rect = book.rect(index).offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
        guard rect.maxY <= tv.bounds.maxY, let full = tv.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        tv.cacheDisplay(in: rect, to: full)
        let size = NSSize(width: width, height: (rect.height * width / rect.width).rounded())
        guard let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        small.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
        NSGraphicsContext.current?.imageInterpolation = .high
        full.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(small)
        return image
    }

    /// Scrolls the page into view and puts the caret at its first line.
    func revealBookPage(_ index: Int) {
        guard let tv = textView, let book = tv.book else { return }
        let origin = tv.textContainerOrigin
        let page = book.rect(index).offsetBy(dx: origin.x, dy: origin.y)
        let block = book.textBlock(index).offsetBy(dx: origin.x, dy: origin.y)
        let point = NSPoint(x: block.minX + 1, y: block.minY + 2)
        tv.setSelectedRange(NSRange(location: tv.characterIndexForInsertion(at: point), length: 0))
        tv.scrollToVisible(page.insetBy(dx: 0, dy: -12))
        tv.window?.makeFirstResponder(tv)
    }
}
