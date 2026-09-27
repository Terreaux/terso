// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoDocument

@Suite struct CodecTests {
    @Test(arguments: [
        "# Title\r\n\r\n*a*  __b__ \t\r\n",                       // CRLF, trailing spaces, tabs
        "Setext\n======\n\n1) item\n   * nested\n\n    indented code\n", // uncommon Markdown
        "no trailing newline",
        "émoji 🧪 and “quotes” — dashes\n",
        "",
    ])
    func roundTripIsByteIdentical(_ text: String) throws {
        let data = Data(text.utf8)
        let (decoded, codec) = try PlainTextCodec.decode(data)
        #expect(try codec.encode(decoded) == data)
    }

    @Test func bomPreserved() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("hi\n".utf8)
        let (s, codec) = try PlainTextCodec.decode(data)
        #expect(s == "hi\n")
        #expect(try codec.encode(s) == data)
    }

    @Test func latinFallback() throws {
        let data = "caf\u{E9}".data(using: .macOSRoman)!
        let (s, codec) = try PlainTextCodec.decode(data)
        #expect(s == "café")
        #expect(try codec.encode(s) == data)
    }
}
