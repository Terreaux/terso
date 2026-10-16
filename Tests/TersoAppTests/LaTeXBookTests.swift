// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Foundation
import PDFKit
import Testing
@testable import TersoApp

@Suite @MainActor struct LaTeXBookTests {
    static let book = #"""
    \documentclass{book}
    \newcommand{\mychapter}[1]{\chapter{#1}}
    \begin{document}
    \tableofcontents
    \part{Beginnings}
    \chapter{The \emph{First} Morning}
    Text. % \chapter{Commented out}
    \section{Not a chapter}
    \chapter*[Short]{Second {Light}}
    \begin{verbatim}
    \chapter{In verbatim}
    \end{verbatim}
    100\% \chapter{After an escaped percent}
    \end{document}
    \chapter{After the end}
    """#

    @Test func scansChaptersAndPartsOfTheBody() {
        let headings = LaTeXHeading.scan(Self.book)
        #expect(headings.map(\.title) == ["Beginnings", "The First Morning", "Second Light", "After an escaped percent"])
        #expect(headings.map(\.part) == [true, false, false, false])
        let ns = Self.book as NSString
        #expect(ns.substring(with: headings[1].range) == #"\chapter{The \emph{First} Morning}"#)
    }

    @Test func anArticleIsChapteredBySections() {
        let article = "\\documentclass{article}\n\\begin{document}\n\\section{One}\n\\subsection{Inner}\n\\section{Two}\n\\end{document}\n"
        #expect(LaTeXHeading.scan(article).map(\.title) == ["One", "Two"])
    }

    @Test func spreadsOpenAsABook() {
        #expect(BookSpreads.count(pages: 0) == 0)
        #expect(BookSpreads.count(pages: 1) == 1)
        #expect(BookSpreads.count(pages: 2) == 2)
        #expect(BookSpreads.count(pages: 5) == 3)
        // The first page alone on the right, then verso beside recto.
        #expect(BookSpreads.pages(inSpread: 0, of: 5) == (nil, 0))
        #expect(BookSpreads.pages(inSpread: 1, of: 5) == (1, 2))
        #expect(BookSpreads.pages(inSpread: 2, of: 5) == (3, 4))
        // An even count ends on a verso alone.
        #expect(BookSpreads.pages(inSpread: 2, of: 4) == (3, nil))
        #expect((0..<7).map(BookSpreads.spread) == [0, 1, 1, 2, 2, 3, 3])
        for pages in 1...9 {
            let all = (0..<BookSpreads.count(pages: pages)).flatMap { s in
                let pair = BookSpreads.pages(inSpread: s, of: pages)
                return [pair.verso, pair.recto].compactMap { $0 }
            }
            #expect(all == Array(0..<pages))
            #expect(all.allSatisfy { BookSpreads.pages(inSpread: BookSpreads.spread(of: $0), of: pages).recto == $0 || $0 % 2 == 1 })
        }
    }

    @Test func facingPagesNeedRoom() {
        let trade = CGSize(width: 432, height: 648)
        #expect(BookSpreads.facing(width: 900, page: trade))
        #expect(!BookSpreads.facing(width: 500, page: trade))
        #expect(!BookSpreads.facing(width: 2000, page: CGSize(width: 792, height: 612)))
    }

    @Test func chaptersFoundInPageText() {
        let pages = [
            "A Book\nBy Someone",
            "Contents\n1 The First Morning . . . 3\n2 Second Light . . . 5",
            "Part I\nBeginnings",
            "Chapter 1\nThe First Morning\nIt began with the ﬁrst light.",
            "THE FIRST MORNING 4\nMore text about second light, mentioned in passing, far down the page "
                + String(repeating: "and more words ", count: 20) + "Second Light",
            "Chapter 2\nSecond Light\nText.",
        ]
        let found = PDFChapterPages.locate(["Beginnings", "The First Morning", "Second Light", "Missing"], outline: [], pages: pages.count) { pages[$0] }
        #expect(found == [2, 3, 5, nil])
    }

    @Test func chaptersFoundInTheOutlineFirst() {
        let outline = [(label: "Contents", page: 1), (label: "I Beginnings", page: 2), (label: "1 The First Morning", page: 3), (label: "2 Second Light", page: 6)]
        let found = PDFChapterPages.locate(["Beginnings", "The First Morning", "Second Light"], outline: outline, pages: 8) { _ in "" }
        #expect(found == [2, 3, 6])
        #expect(PDFChapterPages.labels(PDFChapterPages.key("12 Ends"), PDFChapterPages.key("Ends")))
        #expect(!PDFChapterPages.labels(PDFChapterPages.key("The Ends"), PDFChapterPages.key("Ends")))
    }

    @Test func titlesMatchThroughLigaturesAndQuotes() {
        #expect(PDFChapterPages.key("The ﬁnal “Word”") == PDFChapterPages.key("The final ``Word''"))
    }

    @Test func pageSizesAreNamed() {
        #expect(LaTeXBook.trim(CGSize(width: 612, height: 792)) == "US Letter")
        #expect(LaTeXBook.trim(CGSize(width: 595, height: 842)) == "A4")
        #expect(LaTeXBook.trim(CGSize(width: 432, height: 648)) == "6 × 9 in")
        #expect(LaTeXBook.trim(CGSize(width: 360, height: 540)) == "5 × 7.5 in")
    }

    /// A real PDF, drawn here so PDFKit's text extraction is what's searched.
    @Test func chaptersFoundInADrawnPDF() throws {
        let texts = ["Contents\nOne Road\nTwo Rivers", "Chapter 1\nOne Road\nWords.", "Words.", "Chapter 2\nTwo Rivers\nWords."]
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 450)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in texts {
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            (text as NSString).draw(in: CGRect(x: 30, y: 30, width: 240, height: 380), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        #expect(document.pageCount == 4)
        let found = PDFChapterPages.locate(["One Road", "Two Rivers"], outline: PDFChapterPages.outline(of: document), pages: document.pageCount) {
            document.page(at: $0)?.string ?? ""
        }
        #expect(found == [1, 3])
    }
}
