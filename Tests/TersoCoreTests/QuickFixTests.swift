// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoCore

@Suite struct QuickFixTests {
    func apply(_ fix: QuickFix, to text: String) -> String {
        (text as NSString).replacingCharacters(in: fix.range.nsRange, with: fix.replacement)
    }

    func fixes(_ text: String, _ phrase: String, suggestions: [String] = [], removable: Bool = false) -> [QuickFix] {
        QuickFixes.fixes(suggestions: suggestions, removable: removable,
                         range: TextSpan((text as NSString).range(of: phrase)), in: text)
    }

    @Test func replacementsMatchCaseAndSkipNoOps() {
        let text = "In order to win, we ran."
        let out = fixes(text, "In order to", suggestions: ["to", "to", "In order to"])
        #expect(out.map(\.proposed) == ["To"])
        #expect(apply(out[0], to: text) == "To win, we ran.")
    }

    @Test func removalLeavesNoDoubleSpace() {
        let text = "It was very good."
        let fix = fixes(text, "very", removable: true)[0]
        #expect(fix.isRemoval)
        #expect(apply(fix, to: text) == "It was good.")
    }

    @Test func removalBeforePunctuationTakesTheSpaceBefore() {
        let text = "We liked it really."
        #expect(apply(fixes(text, "really", removable: true)[0], to: text) == "We liked it.")
    }

    @Test func removingASentenceOpenerRecapitalisesAndDropsItsComma() {
        let text = "Done. Needless to say, the fit failed."
        #expect(apply(fixes(text, "Needless to say", removable: true)[0], to: text) == "Done. The fit failed.")
        let start = "Basically the fit failed."
        #expect(apply(fixes(start, "Basically", removable: true)[0], to: start) == "The fit failed.")
    }

    @Test func metadataSplitsAlternatives() {
        let m = QuickFixes.metadata(replacements: "composed of / comprises", removable: false)
        #expect(m[QuickFixes.suggestionsKey] == "composed of\ncomprises")
        #expect(m[QuickFixes.removableKey] == nil)
        #expect(QuickFixes.metadata(replacements: nil, removable: true) == [QuickFixes.removableKey: "true"])
    }
}
