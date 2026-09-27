// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Reads and writes plain files without normalising anything: line endings,
/// trailing whitespace, BOM and Markdown syntax survive a round trip byte for byte.
public struct PlainTextCodec: Sendable, Equatable {
    public var encoding: String.Encoding
    public var hasBOM: Bool

    public init(encoding: String.Encoding = .utf8, hasBOM: Bool = false) {
        self.encoding = encoding
        self.hasBOM = hasBOM
    }

    static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    public static func decode(_ data: Data) throws -> (String, PlainTextCodec) {
        if data.starts(with: utf8BOM), let s = String(data: data.dropFirst(3), encoding: .utf8) {
            return (s, PlainTextCodec(encoding: .utf8, hasBOM: true))
        }
        if let s = String(data: data, encoding: .utf8) { return (s, PlainTextCodec()) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) {
            return (s, PlainTextCodec(encoding: .utf16))
        }
        if let s = String(data: data, encoding: .macOSRoman) { return (s, PlainTextCodec(encoding: .macOSRoman)) }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    public func encode(_ text: String) throws -> Data {
        guard let data = text.data(using: encoding) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        return hasBOM && encoding == .utf8 ? Data(Self.utf8BOM) + data : data
    }
}
