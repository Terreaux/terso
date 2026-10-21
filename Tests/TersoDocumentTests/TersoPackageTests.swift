// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoDocument

@Suite struct TersoPackageTests {
    @Test(arguments: [
        "---\ntitle: \"Essay\"\nauthor: \"\"\n---\n\n# Introduction\n\nText.\n",
        "---\ntitle: x\n---\n",
        "No metadata at all.\n",
        "+++\ntitle = \"toml\"\n+++\nBody\n",   // only YAML is split out
        "---\ntitle: x\n...\nBody\n",          // so is a `...` terminator kept
        "---\n---\nEmpty block\n",
        "",
    ])
    func textRoundTripsExactly(_ text: String) throws {
        let data = try TersoPackage(text: text).encode()
        #expect(try TersoPackage.decode(data).text == text)
    }

    @Test func metadataAndBodyAreSeparateEntries() throws {
        let package = TersoPackage(text: "---\ntitle: \"Essay\"\n---\n\n# One\n")
        #expect(package.metadata == "title: \"Essay\"\n")
        #expect(package.body == "\n# One\n")
        let decoded = try TersoPackage.decode(try package.encode())
        #expect(decoded == package)
    }

    @Test func savingIsDeterministic() throws {
        let package = TersoPackage(metadata: "a: 1\n", body: "Body 🧪\n")
        #expect(try package.encode() == package.encode())
    }

    @Test func metadataWithoutFinalNewlineStillJoins() {
        #expect(TersoPackage(metadata: "a: 1", body: "Body\n").text == "---\na: 1\n---\nBody\n")
    }

    @Test func rejectsNonArchives() {
        #expect(throws: (any Error).self) { try TersoPackage.decode(Data("# Just Markdown\n".utf8)) }
    }

    /// The archive interoperates with the system's own zip tools both ways.
    @Test func interoperatesWithSystemZip() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let ours = dir.appendingPathComponent("ours.terso")
        try TersoPackage(metadata: "title: x\n", body: "Body\n").encode().write(to: ours)
        let test = try run("/usr/bin/unzip", ["-tq", ours.path])
        #expect(test == 0)

        // A folder compressed with deflate, the way Finder or `zip -r` makes one.
        let folder = dir.appendingPathComponent("Essay")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let body = String(repeating: "A paragraph that compresses well. ", count: 50) + "\n"
        try Data(body.utf8).write(to: folder.appendingPathComponent("document.md"))
        try Data("title: Essay\n".utf8).write(to: folder.appendingPathComponent("metadata.yaml"))
        let theirs = dir.appendingPathComponent("theirs.terso")
        #expect(try run("/usr/bin/zip", ["-qr9", theirs.path, "Essay"], in: dir) == 0)
        let decoded = try TersoPackage.decode(Data(contentsOf: theirs))
        #expect(decoded.text == "---\ntitle: Essay\n---\n" + body)
    }

    private func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
