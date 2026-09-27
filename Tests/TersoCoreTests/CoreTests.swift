// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoCore

@Suite struct ProseTextTests {
    @Test func maskPreservesLength() {
        let md = "# Title\n\nSome *emphasis* and a [link](https://x.y/z).\n\n```swift\nlet x = 1\n```\n\n- item one\n- item two\n"
        let p = ProseText(markdown: md)
        #expect(p.masked.utf16.count == md.utf16.count)
        #expect(p.headings.map(\.title) == ["Title"])
        #expect(!p.masked.contains("let x"))
        #expect(!p.masked.contains("https"))
        #expect(p.blocks.count == 3)
        #expect(p.blocks.filter { $0.kind == .listItem }.count == 2)
    }

    @Test func sentencesRespectAbbreviations() {
        let p = ProseText(markdown: "Dr. Smith arrived at 3.5 p.m. today. He left, e.g. early! Did he?")
        #expect(p.sentences.count == 3)
        #expect(p.string(p.sentences[0].range) == "Dr. Smith arrived at 3.5 p.m. today.")
    }

    @Test func rangesMapToOriginal() {
        let md = "**Bold** start. Émile wrote “quotes” — fine."
        let p = ProseText(markdown: md)
        let words = p.words.map { p.string($0) }
        #expect(words.contains("Bold"))
        #expect(words.contains("Émile"))
    }

    @Test func codeBlocksDoNotCreateHeadings() {
        let p = ProseText(markdown: "```\n# not a heading\n```\n\n## Real\n")
        #expect(p.headings.map(\.title) == ["Real"])
    }

    @Test func frontMatterIsNotProse() {
        let yaml = ProseText(markdown: "---\ntitle: Hidden words\n# comment\n---\n\nVisible prose.\n")
        #expect(yaml.words.map { yaml.string($0) } == ["Visible", "prose"])
        #expect(yaml.headings.isEmpty)
        let toml = ProseText(markdown: "+++\ntitle = \"Hidden\"\n+++\nVisible.\n")
        #expect(toml.words.map { toml.string($0) } == ["Visible"])
        // A rule later in the document is not front matter.
        #expect(MarkdownSyntax.frontMatter(in: "Intro\n---\nmore\n---\n") == nil)
    }

    @Test func mathIsNotProse() {
        let md = "Energy is $E = mc^2$ here.\n\n$$\n\\int_0^1 x\\,dx\n$$\n\nAlso \\(a_b\\) and \\begin{align}x &= y\\end{align} done."
        let p = ProseText(markdown: md)
        let words = p.words.map { p.string($0) }
        #expect(words == ["Energy", "is", "here", "Also", "and", "done"])
        #expect(p.masked.utf16.count == md.utf16.count)
    }

    @Test func dollarAmountsStayProse() {
        let p = ProseText(markdown: "It cost $5 and $10, or $5-$10 total.")
        #expect(p.words.map { p.string($0) }.contains("and"))
        #expect(MarkdownSyntax.mathRanges(in: p.original).isEmpty)
    }
}

@Suite struct AnchorTests {
    let text = "The cat sat. The dog ran. The cat sat again."

    @Test func exactAtSameRevision() {
        let snap = DocumentSnapshot(revision: DocumentRevision(1), text: text)
        let a = TextAnchor(range: TextSpan(location: 13, length: 12), in: snap)!
        #expect(a.originalText == "The dog ran.")
        #expect(AnchorResolver.resolve(a, revision: snap.revision, in: snap) == .exact(TextSpan(location: 13, length: 12)))
    }

    @Test func relocatesAfterInsertionBefore() {
        let snap = DocumentSnapshot(revision: DocumentRevision(1), text: text)
        let a = TextAnchor(range: TextSpan(location: 13, length: 12), in: snap)!
        let newer = DocumentSnapshot(revision: DocumentRevision(2), text: "Intro. " + text)
        #expect(AnchorResolver.resolve(a, revision: snap.revision, in: newer) == .relocated(TextSpan(location: 20, length: 12)))
    }

    @Test func staleWhenPassageEdited() {
        let snap = DocumentSnapshot(revision: DocumentRevision(1), text: text)
        let a = TextAnchor(range: TextSpan(location: 13, length: 12), in: snap)!
        let newer = DocumentSnapshot(revision: DocumentRevision(2), text: "The cat sat. The dog walked. The cat sat again.")
        guard case .stale = AnchorResolver.resolve(a, revision: snap.revision, in: newer) else { Issue.record("expected stale"); return }
    }

    @Test func duplicateUsesContext() {
        let snap = DocumentSnapshot(revision: DocumentRevision(1), text: text)
        // Second "The cat sat" (in "The cat sat again.")
        let a = TextAnchor(range: TextSpan(location: 26, length: 11), in: snap)!
        let newer = DocumentSnapshot(revision: DocumentRevision(2), text: "Hi. " + text)
        #expect(AnchorResolver.resolve(a, revision: snap.revision, in: newer) == .relocated(TextSpan(location: 30, length: 11)))
    }

    @Test func sameRevisionMismatchIsStale() {
        let snap = DocumentSnapshot(revision: DocumentRevision(1), text: text)
        let bogus = TextAnchor(range: TextSpan(location: 0, length: 3), originalText: "Dog", prefix: "", suffix: "")
        guard case .stale = AnchorResolver.resolve(bogus, revision: snap.revision, in: snap) else { Issue.record("expected stale"); return }
    }
}

@Suite struct ReadabilityTests {
    @Test func syllables() {
        #expect(Readability.syllables("cat") == 1)
        #expect(Readability.syllables("table") == 2)
        #expect(Readability.syllables("reading") == 2)
        #expect(Readability.syllables("information") == 4)
    }

    @Test func statistics() {
        let p = ProseText(markdown: "One two three. Four five six seven.\n\nEight nine.")
        let s = DocumentStatistics(prose: p)
        #expect(s.words == 9)
        #expect(s.sentences == 3)
        #expect(s.paragraphs == 2)
    }
}

@Suite struct DismissalKeyTests {
    @Test func stableAcrossReanalysis() {
        let issue = { WritingIssue(ruleID: "r", severity: .info, category: .style, message: "Adverb", explanation: "",
                                   ranges: [TextSpan(location: 4, length: 6)], originalText: "really") }
        let a = TextAnnotation(issue: issue(), revision: DocumentRevision(1))
        let b = TextAnnotation(issue: issue(), revision: DocumentRevision(2))
        #expect(a.id != b.id)
        #expect(a.dismissalKey == b.dismissalKey)
    }
}
