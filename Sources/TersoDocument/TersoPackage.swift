// SPDX-License-Identifier: AGPL-3.0-only
import Compression
import Foundation
import TersoCore

/// A `.terso` file: a ZIP archive holding the Markdown body and, beside it,
/// the document's YAML metadata. The editor still works on one text — the
/// metadata as `---` front matter followed by the body — so every feature
/// that reads front matter works unchanged; the split only happens on disk.
///
/// The archive is written uncompressed with a fixed timestamp, so saving the
/// same text always produces the same bytes. Reading also accepts deflated
/// entries and a folder prefix, as Finder's "Compress" produces.
public struct TersoPackage: Sendable, Equatable {
    public static let markdownEntry = "document.md"
    public static let metadataEntry = "metadata.yaml"

    /// YAML without its `---` delimiters; empty when the document has none.
    public var metadata: String
    public var body: String

    public init(metadata: String = "", body: String = "") {
        self.metadata = metadata
        self.body = body
    }

    /// Splits leading `---` YAML front matter from the body. Anything else
    /// (TOML `+++`, a `...` terminator, an empty block) stays in the body, so
    /// joining always gives back the exact text.
    public init(text: String) {
        let ns = text as NSString
        if let range = MarkdownSyntax.frontMatter(in: text) {
            let block = ns.substring(with: range)
            if block.hasPrefix("---\n"), block.hasSuffix("\n---\n"), block.utf16.count > 8 {
                let inner = (block as NSString).substring(with: NSRange(location: 4, length: (block as NSString).length - 8))
                self.init(metadata: inner, body: ns.substring(from: NSMaxRange(range)))
                return
            }
        }
        self.init(body: text)
    }

    /// The text the editor shows: metadata as front matter, then the body.
    public var text: String {
        guard !metadata.isEmpty else { return body }
        return "---\n" + metadata + (metadata.hasSuffix("\n") ? "" : "\n") + "---\n" + body
    }

    public func encode() throws -> Data {
        var zip = ZipWriter()
        zip.add(Self.markdownEntry, Data(body.utf8))
        zip.add(Self.metadataEntry, Data(metadata.utf8))
        return zip.finish()
    }

    public static func decode(_ data: Data) throws -> TersoPackage {
        let entries = try ZipReader.entries(in: data)
        func entry(_ exact: String, extensions: Set<String>) -> Data? {
            let candidates = entries.filter { !$0.name.hasPrefix("__MACOSX/") && !$0.name.hasSuffix("/") }
            let match = candidates.first { $0.name == exact }
                ?? candidates.first { extensions.contains(($0.name as NSString).pathExtension.lowercased()) }
            return match?.data
        }
        guard let body = entry(markdownEntry, extensions: ["md", "markdown"]) else { throw CocoaError(.fileReadCorruptFile) }
        let metadata = entry(metadataEntry, extensions: ["yaml", "yml"]) ?? Data()
        guard let bodyText = String(data: body, encoding: .utf8), let metadataText = String(data: metadata, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return TersoPackage(metadata: metadataText, body: bodyText)
    }
}

// MARK: - ZIP

private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}

private extension Data {
    mutating func append16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }

    func read16(_ at: Int) throws -> UInt16 {
        guard at >= 0, at + 2 <= count else { throw CocoaError(.fileReadCorruptFile) }
        let i = startIndex + at
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func read32(_ at: Int) throws -> UInt32 {
        UInt32(try read16(at)) | UInt32(try read16(at + 2)) << 16
    }

    func slice(_ at: Int, _ length: Int) throws -> Data {
        guard at >= 0, length >= 0, at + length <= count else { throw CocoaError(.fileReadCorruptFile) }
        return Data(self[(startIndex + at)..<(startIndex + at + length)])
    }
}

/// Stored (uncompressed) entries with UTF-8 names, dated 1980-01-01.
private struct ZipWriter {
    private var archive = Data()
    private var directory = Data()
    private var count: UInt16 = 0

    mutating func add(_ name: String, _ contents: Data) {
        let name = Data(name.utf8), crc = CRC32.checksum(contents), offset = UInt32(archive.count)
        func header(_ into: inout Data, central: Bool) {
            into.append32(central ? 0x0201_4B50 : 0x0403_4B50)
            if central { into.append16(20) }       // made by
            into.append16(20)                      // version needed
            into.append16(1 << 11)                 // UTF-8 names
            into.append16(0)                       // stored
            into.append16(0); into.append16(0x21)  // time, date
            into.append32(crc)
            into.append32(UInt32(contents.count)); into.append32(UInt32(contents.count))
            into.append16(UInt16(name.count)); into.append16(0)
            if central {
                into.append16(0); into.append16(0); into.append16(0) // comment, disk, internal attributes
                into.append32(0o100644 << 16)                        // -rw-r--r--
                into.append32(offset)
            }
            into.append(name)
        }
        header(&archive, central: false)
        archive.append(contents)
        header(&directory, central: true)
        count += 1
    }

    func finish() -> Data {
        var out = archive + directory
        out.append32(0x0605_4B50)
        out.append16(0); out.append16(0)
        out.append16(count); out.append16(count)
        out.append32(UInt32(directory.count)); out.append32(UInt32(archive.count))
        out.append16(0)
        return out
    }
}

/// Reads through the central directory, so data descriptors and local
/// extra fields need no special handling. ZIP64 and encryption are rejected.
private enum ZipReader {
    struct Entry { let name: String; let data: Data }

    static func entries(in data: Data) throws -> [Entry] {
        // The end record is 22 bytes plus a comment of at most 65 535.
        let floor = Swift.max(0, data.count - 22 - 0xFFFF)
        guard let end = stride(from: data.count - 22, through: floor, by: -1).first(where: { (try? data.read32($0)) == 0x0605_4B50 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let total = Int(try data.read16(end + 10))
        var cursor = Int(try data.read32(end + 16))
        var entries: [Entry] = []
        for _ in 0..<total {
            guard try data.read32(cursor) == 0x0201_4B50 else { throw CocoaError(.fileReadCorruptFile) }
            let flags = try data.read16(cursor + 8), method = try data.read16(cursor + 10)
            let crc = try data.read32(cursor + 16)
            let packed = Int(try data.read32(cursor + 20)), size = Int(try data.read32(cursor + 24))
            let nameLength = Int(try data.read16(cursor + 28))
            let skip = Int(try data.read16(cursor + 30)) + Int(try data.read16(cursor + 32))
            let local = Int(try data.read32(cursor + 42))
            guard flags & 1 == 0, packed != 0xFFFF_FFFF, size != 0xFFFF_FFFF,
                  let name = String(data: try data.slice(cursor + 46, nameLength), encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            cursor += 46 + nameLength + skip

            guard try data.read32(local) == 0x0403_4B50 else { throw CocoaError(.fileReadCorruptFile) }
            let start = local + 30 + Int(try data.read16(local + 26)) + Int(try data.read16(local + 28))
            let raw = try data.slice(start, packed)
            let contents: Data
            switch method {
            case 0: contents = raw
            case 8: contents = try inflate(raw, size: size)
            default: throw CocoaError(.fileReadCorruptFile)
            }
            guard contents.count == size, CRC32.checksum(contents) == crc else { throw CocoaError(.fileReadCorruptFile) }
            entries.append(Entry(name: name, data: contents))
        }
        return entries
    }

    /// `COMPRESSION_ZLIB` is raw DEFLATE, exactly ZIP's method 8.
    private static func inflate(_ raw: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard !raw.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw CocoaError(.fileReadCorruptFile) }
        return out
    }
}
