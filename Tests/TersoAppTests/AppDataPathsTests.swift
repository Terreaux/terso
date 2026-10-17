// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoApp

@Suite struct AppDataPathsTests {
    @Test func defaultAndExplicitDataDirectory() {
        let name = "DocumentTabs.json"
        #expect(AppDataPaths.file(name, dataDirectory: nil) ==
                URL.applicationSupportDirectory.appendingPathComponent("Terso/\(name)"))
        #expect(AppDataPaths.file(name, dataDirectory: "") ==
                URL.applicationSupportDirectory.appendingPathComponent("Terso/\(name)"))
        #expect(AppDataPaths.file(name, dataDirectory: "/tmp/terso-validation/../isolated") ==
                URL(fileURLWithPath: "/tmp/isolated/\(name)"))
    }
}
