// SPDX-License-Identifier: AGPL-3.0-only
// terso-fm — send stdin to Apple's on-device model and print the reply.
// Used to generate evaluation samples locally at no cost:
//   TERSO_AI_CMD=.build/release/terso-fm scripts/generate-ai-corpus.sh heldout
import Foundation
import TersoAI
#if canImport(FoundationModels)
import FoundationModels
#endif

@main struct TersoFM {
    static func main() async {
        let prompt = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        if let reason = AppleOnDeviceModel.unavailableReason {
            FileHandle.standardError.write(Data("terso-fm: \(reason)\n".utf8)); exit(1)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let reply = try await LanguageModelSession().respond(to: prompt).content
                print(reply)
                return
            } catch {
                FileHandle.standardError.write(Data("terso-fm: \(error)\n".utf8)); exit(1)
            }
        }
        #endif
        exit(1)
    }
}
