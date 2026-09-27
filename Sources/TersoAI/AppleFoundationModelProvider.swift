// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model (Apple Intelligence). Runs entirely on this
/// Mac: no key, no network, no account.
public enum AppleOnDeviceModel {
    public static let providerID = ProviderID("local.apple")
    public static let displayName = "Apple Intelligence (on-device)"

    /// nil when the model can be used; otherwise a reason to show the writer.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return "Requires macOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off in System Settings."
        case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence."
        case .unavailable(.modelNotReady): return "The on-device model is still downloading."
        case .unavailable: return "The on-device model is unavailable."
        }
        #else
        return "This build was made without the FoundationModels framework."
        #endif
    }

    public static var isAvailable: Bool { unavailableReason == nil }

    public static func makeProvider() -> (any WritingAssistantProvider)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable { return AppleFoundationModelProvider() }
        #endif
        return nil
    }

    /// Split long passages at paragraph breaks so each request fits the
    /// on-device model's context window.
    public static func chunks(_ text: String, maxWords: Int = 700) -> [String] {
        let paras = text.components(separatedBy: "\n\n")
        var out: [String] = [], cur: [String] = [], n = 0
        for p in paras {
            let w = p.split(whereSeparator: \.isWhitespace).count
            if n + w > maxWords, !cur.isEmpty { out.append(cur.joined(separator: "\n\n")); cur = []; n = 0 }
            cur.append(p); n += w
        }
        if !cur.isEmpty { out.append(cur.joined(separator: "\n\n")) }
        return out
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedSuggestion {
    @Guide(description: "Exact text copied verbatim from the passage; a phrase or one sentence")
    var original: String
    @Guide(description: "The replacement text")
    var proposed: String
    @Guide(description: "Why, in one or two sentences")
    var explanation: String
    @Guide(description: "One of: clarity, concision, repetition, argument, ambiguity, grammar, wordiness, alternative")
    var kind: String
}

@available(macOS 26.0, *)
@Generable
struct GeneratedReply {
    @Guide(description: "Your explanation or answer to the writer, in plain prose")
    var message: String
    @Guide(description: "Proposed revisions; empty when none are needed", .maximumCount(8))
    var suggestions: [GeneratedSuggestion]
}

/// Structured output comes back as typed values (guided generation), so there
/// is no JSON to parse.
@available(macOS 26.0, *)
public struct AppleFoundationModelProvider: WritingAssistantProvider {
    public let id = AppleOnDeviceModel.providerID
    public let displayName = AppleOnDeviceModel.displayName
    public let locality = ProviderLocality.local
    public let capabilities: Set<ProviderCapability> = Set(ProviderCapability.allCases)

    public init() {}

    public func analyze(_ request: AnalysisRequest) async throws -> AnalysisResponse {
        guard AppleOnDeviceModel.isAvailable else { throw ProviderError.notConfigured(AppleOnDeviceModel.unavailableReason ?? "") }
        var messages: [String] = []
        var proposals: [ProposedRevision] = []
        let parts = AppleOnDeviceModel.chunks(request.context.text)
        for part in parts {
            try Task.checkCancellation()
            let sub = AnalysisRequest(task: request.task, question: request.question,
                                      context: ContextPayload(scope: request.context.scope, text: part, range: request.context.range,
                                                              revision: request.context.revision, fileName: request.context.fileName))
            let session = LanguageModelSession(instructions: PromptBuilder.editorRules)
            // Xcode 27 renamed this initializer; keep older SDKs buildable.
            #if compiler(>=6.4)
            let options = GenerationOptions(samplingMode: .greedy)
            #else
            let options = GenerationOptions(sampling: .greedy)
            #endif
            do {
                let reply = try await session.respond(to: PromptBuilder.user(sub), generating: GeneratedReply.self,
                                                     options: options).content
                if !reply.message.isEmpty { messages.append(reply.message) }
                proposals += reply.suggestions.map {
                    ProposedRevision(original: $0.original, proposed: $0.proposed, explanation: $0.explanation, kind: $0.kind)
                }
            } catch let e as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = e { throw ProviderError.invalidResponse("The passage is too long for the on-device model. Try a smaller selection.") }
                if case .guardrailViolation = e { throw ProviderError.invalidResponse("The on-device model declined this passage.") }
                throw e
            }
        }
        return AnalysisResponse(message: messages.joined(separator: "\n\n"),
                                proposals: proposals.filter { !$0.original.isEmpty && $0.original != $0.proposed })
    }
}
#endif
