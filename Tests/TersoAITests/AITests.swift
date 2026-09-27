// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
@testable import TersoAI

@Suite struct AITests {
    let doc = "# Intro\n\nFirst paragraph here.\nStill first.\n\nSecond paragraph is here. It has two sentences.\n\n# Next\n\nOther section."

    @Test func contextScopes() {
        let snap = DocumentSnapshot(revision: DocumentRevision(3), text: doc)
        let loc = (doc as NSString).range(of: "two sentences").location
        let sel = TextSpan(location: loc, length: 3)
        #expect(ContextPayload.make(scope: .selection, snapshot: snap, selection: sel).text == "two")
        #expect(ContextPayload.make(scope: .paragraph, snapshot: snap, selection: sel).text == "Second paragraph is here. It has two sentences.")
        let section = ContextPayload.make(scope: .section, snapshot: snap, selection: sel).text
        #expect(section.hasPrefix("# Intro"))
        #expect(!section.contains("Other section"))
        #expect(ContextPayload.make(scope: .document, snapshot: snap, selection: sel).text == doc)
    }

    @Test func parserHandlesFencesAndProse() {
        let raw = "Sure!\n```json\n{\"message\":\"ok\",\"suggestions\":[{\"original\":\"a\",\"proposed\":\"b\",\"explanation\":\"x\",\"kind\":\"clarity\"}]}\n```"
        let r = ResponseParser.parse(raw)
        #expect(r.message == "ok")
        #expect(r.proposals.count == 1)
        #expect(ResponseParser.parse("just text").message == "just text")
    }

    @Test func builderDropsAmbiguousOrMissingOriginals() {
        let snap = DocumentSnapshot(revision: DocumentRevision(1), text: "alpha beta alpha gamma")
        let ctx = ContextPayload.make(scope: .document, snapshot: snap, selection: TextSpan(location: 0, length: 0))
        let (s, dropped) = SuggestionBuilder.build([
            ProposedRevision(original: "alpha", proposed: "A", explanation: nil, kind: nil),   // ambiguous
            ProposedRevision(original: "delta", proposed: "D", explanation: nil, kind: nil),   // absent
            ProposedRevision(original: "gamma", proposed: "G", explanation: nil, kind: nil),
        ], context: ctx, snapshot: snap, provider: ProviderID("t"))
        #expect(s.count == 1)
        #expect(dropped == 2)
        #expect(s[0].anchor.range == TextSpan(location: 17, length: 5))
    }

    @Test func promptNeverContainsMoreThanContext() {
        let snap = DocumentSnapshot(revision: DocumentRevision(1), text: "SECRET-OTHER-PART\n\nVisible paragraph.")
        let ctx = ContextPayload.make(scope: .paragraph, snapshot: snap, selection: TextSpan(location: 22, length: 0))
        let prompt = PromptBuilder.combined(AnalysisRequest(task: .proofread, context: ctx))
        #expect(prompt.contains("Visible paragraph."))
        #expect(!prompt.contains("SECRET"))
    }

    @Test func localityDetection() {
        #expect(HTTPProviderConfiguration.ollama.locality == .local)
        #expect(HTTPProviderConfiguration.openAI.locality == .network)
    }

    @Test func missingKeyIsReported() {
        let p = HTTPProvider(configuration: .openAI, keyLookup: { _ in nil })
        let ctx = ContextPayload(scope: .selection, text: "x", range: TextSpan(location: 0, length: 1), revision: DocumentRevision(0), fileName: nil)
        #expect(throws: ProviderError.self) { try p.makeURLRequest(AnalysisRequest(task: .proofread, context: ctx)) }
    }

    @Test func anthropicRequestShape() throws {
        let p = HTTPProvider(configuration: .anthropic, keyLookup: { _ in "k" })
        let ctx = ContextPayload(scope: .selection, text: "Hello", range: TextSpan(location: 0, length: 5), revision: DocumentRevision(0), fileName: nil)
        let req = try p.makeURLRequest(AnalysisRequest(task: .proofread, context: ctx))
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "k")
    }

    /// The CLI provider feeds the prompt on stdin, runs in a throwaway
    /// workspace and never receives the document path.
    @Test func cliProviderUsesStdinAndIsolatedWorkspace() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("terso-fake-\(UUID()).sh")
        try """
        #!/bin/sh
        input=$(cat)
        case "$input" in *"Visible text"*) ok=yes;; *) ok=no;; esac
        pwd > "$1"
        echo "{\\"message\\": \\"stdin=$ok\\", \\"suggestions\\": []}"
        # Try to vandalise: delete everything in cwd.
        rm -f ./*
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cwdFile = FileManager.default.temporaryDirectory.appendingPathComponent("terso-cwd-\(UUID()).txt")
        let cfg = CLIProviderConfiguration(id: "fake", displayName: "Fake", command: script.path, arguments: [cwdFile.path], timeout: 10)
        let ctx = ContextPayload(scope: .selection, text: "Visible text; $(rm -rf ~) `echo pwned`", range: TextSpan(location: 0, length: 5), revision: DocumentRevision(0), fileName: "essay.md")
        let r = try await CLIProvider(configuration: cfg).analyze(AnalysisRequest(task: .proofread, context: ctx))
        #expect(r.message == "stdin=yes")
        let cwd = try String(contentsOf: cwdFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.contains("terso-ws-"))
        #expect(!FileManager.default.fileExists(atPath: cwd)) // workspace destroyed
    }

    @Test func cliTimeout() async throws {
        let cfg = CLIProviderConfiguration(id: "sleep", displayName: "Sleep", command: "/bin/sleep", arguments: ["5"], timeout: 0.5)
        let ctx = ContextPayload(scope: .selection, text: "x", range: TextSpan(location: 0, length: 1), revision: DocumentRevision(0), fileName: nil)
        await #expect(throws: ProviderError.timedOut(0.5)) {
            try await CLIProvider(configuration: cfg).analyze(AnalysisRequest(task: .proofread, context: ctx))
        }
    }
}

/// Live round-trip through the real Codex CLI. Opt-in: TERSO_LIVE_CODEX=1.
@Suite struct LiveCLITests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERSO_LIVE_CODEX"] == "1"))
    func codexRoundTrip() async throws {
        let text = "The experiment was very clearly able to demonstrate the effect that we had expected to see."
        let snap = DocumentSnapshot(revision: DocumentRevision(1), text: text)
        let ctx = ContextPayload.make(scope: .document, snapshot: snap, selection: TextSpan(location: 0, length: 0))
        var cfg = CLIProviderConfiguration.codex
        cfg.timeout = 240
        let provider = CLIProvider(configuration: cfg)
        let r = try await provider.analyze(AnalysisRequest(task: .makeConcise, context: ctx))
        let built = SuggestionBuilder.build(r.proposals, context: ctx, snapshot: snap, provider: provider.id)
        print("MESSAGE:", r.message)
        for s in built.suggestions { print("SUGGESTION:", s.originalText, "→", s.proposedText) }
        #expect(!r.proposals.isEmpty)
        #expect(!built.suggestions.isEmpty)
    }
}

@Suite struct DataAccessTests {
    @Test func policyLimitsScopes() {
        #expect(AIDataAccess.selectionOnly.permits(.selection))
        #expect(!AIDataAccess.selectionOnly.permits(.paragraph))
        #expect(AIDataAccess.upToSection.permits(.section))
        #expect(!AIDataAccess.upToSection.permits(.document))
        #expect(AIDataAccess.wholeDocument.permits(.document))
    }
}

/// Live round-trip through Apple's on-device model. Opt-in: TERSO_LIVE_APPLE=1 (free, local).
@Suite struct LiveAppleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERSO_LIVE_APPLE"] == "1"))
    func onDeviceRoundTrip() async throws {
        let text = "The experiment was very clearly able to demonstrate the effect that we had expected to see."
        let snap = DocumentSnapshot(revision: DocumentRevision(1), text: text)
        let ctx = ContextPayload.make(scope: .document, snapshot: snap, selection: TextSpan(location: 0, length: 0))
        let provider = try #require(AppleOnDeviceModel.makeProvider(), "\(AppleOnDeviceModel.unavailableReason ?? "")")
        #expect(provider.locality == .local)
        let r = try await provider.analyze(AnalysisRequest(task: .makeConcise, context: ctx))
        let built = SuggestionBuilder.build(r.proposals, context: ctx, snapshot: snap, provider: provider.id)
        print("MESSAGE:", r.message)
        for s in built.suggestions { print("SUGGESTION:", s.originalText, "→", s.proposedText) }
        print("DROPPED:", built.discarded)
        #expect(!built.suggestions.isEmpty)
    }

    @Test func chunkingKeepsParagraphs() {
        let para = String(repeating: "word ", count: 400).trimmingCharacters(in: .whitespaces)
        let chunks = AppleOnDeviceModel.chunks([para, para, para].joined(separator: "\n\n"), maxWords: 700)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { !$0.contains("\n\n") })
    }
}
