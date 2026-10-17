// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Keeps validation sessions away from the writer's normal local records.
/// TERSO_DATA_DIR is intended for explicitly isolated app launches only.
enum AppDataPaths {
    static func file(_ name: String, dataDirectory: String? = ProcessInfo.processInfo.environment["TERSO_DATA_DIR"]) -> URL {
        if let dataDirectory, !dataDirectory.isEmpty {
            precondition(dataDirectory.hasPrefix("/"), "TERSO_DATA_DIR must be an absolute path")
            return URL(fileURLWithPath: dataDirectory, isDirectory: true)
                .standardizedFileURL.appendingPathComponent(name)
        }
        return URL.applicationSupportDirectory.appendingPathComponent("Terso/\(name)")
    }
}
