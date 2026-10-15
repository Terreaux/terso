// SPDX-License-Identifier: AGPL-3.0-only
import Testing
@testable import TersoApp

@Suite @MainActor struct WritingModeTests {
    @Test func oneWritingModeAtATimeWithHemingwayAsDefault() {
        let model = WorkspaceModel()
        #expect(model.writingMode == .hemingway)
        model.setWritingMode(.typewriter)
        #expect(model.typewriter && !model.focusMode)
        model.setWritingMode(.letterbox)
        #expect(model.writingMode == .letterbox && model.focusMode)
        model.setWritingMode(.typewriter)
        #expect(model.writingMode == .typewriter && !model.focusMode)
        // A mode's shortcut pressed again returns to Hemingway.
        model.toggleWritingMode(.typewriter)
        #expect(model.writingMode == .hemingway && !model.typewriter)
        #expect(WritingMode.allCases.filter(\.followsCaret) == [.typewriter, .letterbox])
    }
}
