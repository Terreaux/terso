// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

@MainActor enum ProjectDocumentCreation {
    /// Projects link files from anywhere; prefer an existing member's folder.
    static func suggestedDirectory(for project: TersoProject) -> URL? {
        project.documents.first(where: \.exists)?.url.deletingLastPathComponent()
    }

    /// Link only after AppKit confirms the source has been saved successfully.
    static func save(_ document: TabDocument, to url: URL, in project: TersoProject.ID, store: ProjectStore) async throws {
        guard store.projects.contains(where: { $0.id == project }) else { throw CocoaError(.fileNoSuchFile) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: document.fileType ?? "public.plain-text", for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        store.add([url], to: project)
    }
}
