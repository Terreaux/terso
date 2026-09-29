// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Resolves links other apps drag or copy instead of file URLs.
enum ExternalFileLinks {
    /// A `file:` URL, or an `obsidian://open` link. Obsidian drags notes as
    /// `obsidian://open?vault=<name>&file=<vault path without .md>`, or with
    /// `path=<absolute path>`; vault names resolve through Obsidian's registry.
    static func fileURL(for url: URL, obsidianVaults: () -> [URL] = obsidianVaults) -> URL? {
        if url.isFileURL { return url }
        guard url.scheme?.lowercased() == "obsidian", url.host?.lowercased() == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let path = value("path"), path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let name = value("vault"), let file = value("file"),
              let vault = obsidianVaults().first(where: { $0.lastPathComponent == name }) else { return nil }
        let exact = vault.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        return exact.appendingPathExtension("md")
    }

    static func obsidianVaults() -> [URL] {
        struct Registry: Decodable { struct Vault: Decodable { var path: String }; var vaults: [String: Vault] }
        let url = URL.applicationSupportDirectory.appendingPathComponent("obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder().decode(Registry.self, from: data) else { return [] }
        return registry.vaults.values.map { URL(fileURLWithPath: $0.path) }
    }
}
