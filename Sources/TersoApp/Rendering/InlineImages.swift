// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore

struct ImageEmbed: Equatable {
    let range: NSRange
    let source: String
}

/// Markdown image embeds (`![alt](url "title")`) shown inline in Mixed mode.
enum ImagePresentation {
    static let embed = try! NSRegularExpression(pattern: #"(?<!\\)!\[[^\]\n]*\]\(\s*<?([^\s()<>]+)>?(?:\s+(?:"[^"\n]*"|'[^'\n]*'))?\s*\)"#)

    static func embeds(in text: String) -> [ImageEmbed] {
        let ns = text as NSString
        let syntax = ScientificSyntax(DocumentSnapshot(revision: DocumentRevision(0), text: text))
        let protected = syntax.regions.filter { $0.kind == .code }.map(\.range.nsRange)
            + [MarkdownSyntax.frontMatter(in: text)].compactMap { $0 }
        return embed.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
            return ImageEmbed(range: match.range, source: ns.substring(with: match.range(at: 1)))
        }
    }

    /// Remote images over HTTP(S), or files beneath the document's directory,
    /// matching what the full preview allows locally.
    static func url(for source: String, directory: URL?) -> URL? {
        if let url = URL(string: source), let scheme = url.scheme?.lowercased() {
            return ["http", "https"].contains(scheme) ? url : nil
        }
        guard let directory = directory?.resolvingSymlinksInPath(), !source.hasPrefix("/"),
              let path = source.removingPercentEncoding else { return nil }
        let file = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        return file.path.hasPrefix(directory.path + "/") ? file : nil
    }
}

@MainActor final class InlineImageLoader {
    nonisolated static let maximumBytes = 20_000_000
    private var originals: [URL: NSImage] = [:]
    /// Stable instances per width, so unchanged images never force relayout.
    private var fittedImages: [String: NSImage] = [:]
    private var failed: Set<URL> = []
    /// Downloads outlive the presentation pass that started them, so typing
    /// (which cancels and restarts that pass) never restarts a fetch.
    private var loading: [URL: Task<NSImage?, Never>] = [:]

    /// The cached image scaled to the column, without waiting for a download.
    func cachedImage(for url: URL, width: Double) -> NSImage? {
        guard let original = originals[url] else { return nil }
        let key = "\(width)|\(url.absoluteString)"
        if let fitted = fittedImages[key] { return fitted }
        if fittedImages.count >= 128 { fittedImages.removeAll(keepingCapacity: true) }
        let fitted = Self.fitted(original, width: width)
        fittedImages[key] = fitted
        return fitted
    }

    func image(for url: URL, width: Double) async -> NSImage? {
        if let cached = cachedImage(for: url, width: width) { return cached }
        guard !failed.contains(url) else { return nil }
        let task = loading[url] ?? Task { await Self.load(url) }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        guard let image else { failed.insert(url); return nil }
        if originals.count >= 64 { originals.removeAll(keepingCapacity: true); fittedImages.removeAll() }
        originals[url] = image
        return cachedImage(for: url, width: width)
    }

    nonisolated private static func load(_ url: URL) async -> NSImage? {
        let data: Data
        if url.isFileURL {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < maximumBytes,
                  let contents = try? Data(contentsOf: url) else { return nil }
            data = contents
        } else {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (body, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                  body.count < maximumBytes else { return nil }
            data = body
        }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// Scale down (never up) so the image fits the text column and a screenful.
    static func fitted(_ image: NSImage, width: Double) -> NSImage {
        let scale = min(1, (width - 8) / image.size.width, 600 / image.size.height)
        guard scale < 1, let copy = image.copy() as? NSImage else { return image }
        copy.size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return copy
    }
}
