// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import Observation
import TersoAnalysis
import TersoCore

/// A source quotation and its surrounding context remain reviewable after a file changes.
struct EvidencePassage: Codable, Hashable, Sendable {
    let file: URL
    let anchor: TextAnchor

    init?(file: URL, range: TextSpan, text: String) {
        guard range.length > 0,
              let anchor = TextAnchor(range: range, in: DocumentSnapshot(revision: .init(0), text: text)),
              !anchor.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.file = file.standardizedFileURL.resolvingSymlinksInPath()
        self.anchor = anchor
    }

    func locate(in sources: [URL: String]) -> TextSpan? {
        guard let text = sources[file] else { return nil }
        // Revision numbers are local to a session. Reopening must always compare text and context.
        let snapshot = DocumentSnapshot(revision: .init(1), text: text)
        return AnchorResolver.resolve(anchor, revision: .init(0), in: snapshot).range
    }
}

struct ClaimEvidenceLink: Identifiable, Codable, Hashable {
    enum Kind: String, CaseIterable, Codable {
        case passage = "Passage", figure = "Figure", table = "Table", derivation = "Derivation", citation = "Citation"
    }
    var id = UUID()
    let claim: EvidencePassage
    let evidence: EvidencePassage
    let kind: Kind
    var confirmedAt = Date()
    /// Links saved before figure fingerprinting retain their original text-only scope.
    var assets: [URL: String]?
}

struct ClaimEvidenceReview: Identifiable {
    let link: ClaimEvidenceLink
    let claimRange: TextSpan?
    let evidenceRange: TextSpan?
    let changedAssets: [URL]
    let checkingAssets: Bool
    var id: UUID { link.id }
    var isCurrent: Bool { claimRange != nil && evidenceRange != nil && changedAssets.isEmpty && !checkingAssets }
}

struct EvidenceRevision: Equatable {
    let file: URL?
    let revision: DocumentRevision
    let index: UUID?
    let saved: Int
    let assets: Int
}

enum EvidenceAssets {
    static func indexedTargets(_ index: ManuscriptIndex, file: URL, range: TextSpan) -> Set<URL> {
        Set(index.graphics.compactMap { location, target in
            location.url == file && range.intersects(location.range) ? target : nil
        })
    }

    static func baseline(for passage: EvidencePassage, root: URL, index: ManuscriptIndex? = nil) throws -> [URL: String] {
        guard passage.file.pathExtension.lowercased() != "bib" else { return [:] }
        if let index, let range = passage.locate(in: index.sources) {
            let targets = indexedTargets(index, file: passage.file, range: range)
            if let missing = index.findings.first(where: {
                $0.rule == "dependency" && $0.location.url == passage.file && range.intersects($0.location.range)
            }) {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: missing.title])
            }
            return try Dictionary(uniqueKeysWithValues: targets.map { ($0, try fingerprint($0)) })
        }
        let source = ManuscriptSource(source: passage.anchor.originalText, url: passage.file)
        let folder = (source.markdown ? passage.file : root).deletingLastPathComponent()
        var result: [URL: String] = [:]
        for dependency in source.dependencies where dependency.kind == .asset {
            guard let url = dependency.resolve(relativeTo: folder, buffers: [:]) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: dependency.name])
            }
            result[url] = try fingerprint(url)
        }
        return result
    }

    static func fingerprint(_ url: URL) throws -> String {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: url.path])
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha = SHA256()
        while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            sha.update(data: block)
        }
        return Data(sha.finalize()).base64EncodedString()
    }
}

struct EvidenceAssetKey: Equatable {
    let root: URL
    let files: Set<URL>
    let refresh: Int
}

@MainActor @Observable
final class ClaimEvidenceStore {
    static let shared = ClaimEvidenceStore()
    private let url: URL
    private var papers: [String: [ClaimEvidenceLink]] = [:]
    private var readFailed = false
    private(set) var error: String?
    private(set) var generation = 0
    var hasLinks: Bool { !papers.isEmpty }

    init(url: URL = AppDataPaths.file("ClaimEvidence.json")) {
        self.url = url
        do {
            papers = try JSONDecoder().decode([String: [ClaimEvidenceLink]].self, from: Data(contentsOf: url))
        } catch let readError as CocoaError where readError.code == .fileReadNoSuchFile {
            // First use.
        } catch {
            readFailed = true
            self.error = "Could not read the saved evidence links. " + error.localizedDescription
        }
    }

    func links(for root: URL) -> [ClaimEvidenceLink] {
        papers[root.standardizedFileURL.resolvingSymlinksInPath().path] ?? []
    }

    @discardableResult
    func confirm(_ link: ClaimEvidenceLink, for root: URL, replacing id: UUID? = nil) -> Bool {
        var links = links(for: root)
        if let id {
            guard let index = links.firstIndex(where: { $0.id == id }) else { return false }
            var updated = link
            updated.id = id
            links[index] = updated
        } else {
            guard !links.contains(where: { $0.claim == link.claim && $0.evidence == link.evidence && $0.kind == link.kind }) else { return true }
            links.append(link)
        }
        return save(links, for: root)
    }

    func remove(_ id: UUID, from root: URL) {
        _ = save(links(for: root).filter { $0.id != id }, for: root)
    }

    private func save(_ links: [ClaimEvidenceLink], for root: URL) -> Bool {
        guard !readFailed else { return false }
        var updated = papers
        updated[root.standardizedFileURL.resolvingSymlinksInPath().path] = links.isEmpty ? nil : links
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            papers = updated
            generation += 1
            error = nil
            return true
        } catch {
            self.error = "Could not save the evidence link. " + error.localizedDescription
            return false
        }
    }
}

extension WorkspaceModel {
    private var evidenceIndex: ManuscriptIndex? {
        guard let file = fileURL?.manuscriptURL, let index = manuscriptIndex, index.sources[file] != nil else { return nil }
        return index
    }
    var evidenceRoot: URL? { evidenceIndex?.root ?? fileURL?.manuscriptURL }

    var evidenceSources: [URL: String] {
        let index = evidenceIndex
        var sources = index?.sources ?? [:]
        if let index { sources.merge(index.bibliographySources) { source, _ in source } }
        if let fileURL, let snapshot = editor?.currentSnapshot {
            sources[fileURL.standardizedFileURL.resolvingSymlinksInPath()] = snapshot.text
        }
        return sources
    }

    var reviewedEvidence: [ClaimEvidenceReview] {
        let store = claimEvidence
        guard store.hasLinks else { return [] }
        let key = EvidenceRevision(file: fileURL, revision: revision, index: manuscriptIndex?.id, saved: store.generation,
                                   assets: scienceReview.assetVersion)
        if let cached = scienceReview.cachedEvidence, cached.0 == key { return cached.1 }
        guard let root = evidenceRoot else { return [] }
        let links = store.links(for: root)
        let sources = links.isEmpty ? [:] : evidenceSources
        let reviews = links.map { link in
            let expected = link.assets ?? [:]
            let range = link.evidence.locate(in: sources)
            let pending = !expected.isEmpty && (scienceReview.assetDigests == nil ||
                !Set(expected.keys).isSubset(of: scienceReview.assetKey?.files ?? []))
            var changed = pending ? Set() : Set(expected.keys.filter { expected[$0] != scienceReview.assetDigests?[$0] })
            if !expected.isEmpty, let range, let index = evidenceIndex, index.sources[link.evidence.file] != nil {
                let current = EvidenceAssets.indexedTargets(index, file: link.evidence.file, range: range)
                changed.formUnion(current.symmetricDifference(expected.keys))
            }
            return ClaimEvidenceReview(link: link, claimRange: link.claim.locate(in: sources),
                                       evidenceRange: range,
                                       changedAssets: changed.sorted { $0.path < $1.path }, checkingAssets: pending)
        }
        scienceReview.cachedEvidence = (key, reviews)
        return reviews
    }

    var confirmedSupportDiagnosticIDs: Set<String> {
        guard let science = currentScience, let fileURL else { return [] }
        let reviews = reviewedEvidence
        guard !reviews.isEmpty else { return [] }
        let file = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let ranges = Set(reviews.filter { $0.isCurrent && $0.link.claim.file == file }.compactMap(\.claimRange))
        return Set(science.diagnostics.filter { [.claims, .evidence].contains($0.category) && ranges.contains($0.sourceRange) }.map(\.id))
    }

    func reviewedEvidence(for claim: ScientificClaim) -> [ClaimEvidenceReview] {
        let file = fileURL?.standardizedFileURL.resolvingSymlinksInPath()
        return reviewedEvidence.filter { $0.link.claim.file == file && $0.claimRange == claim.sourceRange }
    }

    func checkEvidenceAssets() {
        guard claimEvidence.hasLinks, let root = evidenceRoot else { return }
        let files = Set(claimEvidence.links(for: root).flatMap { ($0.assets ?? [:]).keys })
        let key = EvidenceAssetKey(root: root, files: files, refresh: manuscriptPreviewRevision)
        guard key != scienceReview.assetKey else { return }
        scienceReview.assetTask?.cancel()
        scienceReview.assetKey = key
        scienceReview.assetDigests = nil
        scienceReview.assetVersion += 1
        guard !files.isEmpty else { return }
        scienceReview.assetTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                var digests: [URL: String] = [:]
                for file in files {
                    try Task.checkCancellation()
                    digests[file] = try? EvidenceAssets.fingerprint(file)
                }
                return digests
            }
            let result = await withTaskCancellationHandler { try? await worker.value } onCancel: { worker.cancel() }
            guard let self, let result, !Task.isCancelled, self.scienceReview.assetKey == key else { return }
            self.scienceReview.assetDigests = result
            self.scienceReview.assetVersion += 1
            self.editor?.refreshDecorations()
        }
    }
}
