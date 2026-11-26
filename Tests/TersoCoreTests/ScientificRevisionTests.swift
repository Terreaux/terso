// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import TersoCore

@Suite struct ScientificRevisionTests {
    @Test func detectsMagnitudeUnitsUncertaintyPolarityAndSource() {
        let original = #"The current was not stable at 12 ± 0.4 mA \citep{Lee2020a}."#
        let rewritten = #"The current was stable at 13 A \citep{Lee2020b}."#
        let edits = ScientificRevisionChange.compare(original, rewritten)
        #expect(Set(edits.map(\.kind)) == [.number, .unit, .uncertainty, .negation, .citation])
        #expect(edits.first { $0.kind == .unit }?.before == ["mA"])
        #expect(edits.first { $0.kind == .citation }?.after == ["Lee2020b"])
    }

    @Test func preservesTechnicalContentDuringConcision() {
        let before = #"In order to compare $v/c$, we used 1.25e-3 kg and [@a; @b]."#
        let after = #"To compare $v/c$, we used 1.25e-3 kg and [@b; @a]."#
        #expect(ScientificRevisionChange.compare(before, after).isEmpty)
    }

    @Test func identifiesChangesToEquationsUnitsAndPandocCites() {
        let before = #"With $x+y$ we obtained \qty{2}{\milli\meter} [@first-2020]."#
        let after = #"With $x-y$ we obtained \qty{2}{\meter} [@second-2021]."#
        #expect(Set(ScientificRevisionChange.compare(before, after).map(\.kind)) == [.math, .unit, .citation])
        let droppedExponent = ScientificRevisionChange.compare("We observed 2 m/s².", "We observed 2 m/s.")
        #expect(droppedExponent.map(\.kind) == [.unit])
    }
}
