// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Observation
import TersoDocument
import UniformTypeIdentifiers

/// A writer's own starting point: the text of a document, kept with the
/// format it was written in so a new document opens the same way.
struct UserTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: NewDocumentKind
    var text: String

    /// The format a document can be saved as a template in, or nil when Terso
    /// can't create that kind of document from scratch.
    static func kind(forFileType fileType: String?) -> NewDocumentKind? {
        guard let type = fileType.flatMap(UTType.init) else { return nil }
        // Markdown and LaTeX also conform to plain text, so check them first.
        return [NewDocumentKind.terso, .latex, .markdown, .text].first { type.conforms(to: $0.contentType) }
    }

    @MainActor func makeDocument() -> TabDocument {
        let document = TabDocument()
        document.fileType = kind.contentType.identifier
        document.contents.codec = PlainTextCodec()
        document.contents.text = text
        if kind == .text { document.model.renderMode = .source }
        let design = document.model.prefs.bookDesign
        let book = kind == .latex ? BookDesign.read(latex: text, defaults: design) : BookDesign.read(from: text, defaults: design)
        if book != nil {
            document.model.setWritingMode(.manutius)
            document.model.showSidebar = true
        }
        if !text.isEmpty { document.updateChangeCount(.changeDone) }
        return document
    }
}

extension NewDocumentKind: Codable {}

@MainActor
@Observable
final class UserTemplateStore {
    static let shared = UserTemplateStore()
    private(set) var templates: [UserTemplate] = []
    private let fileURL: URL

    init(fileURL: URL = AppDataPaths.file("Templates.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([UserTemplate].self, from: data) {
            templates = saved
        }
    }

    /// Saving under a name already in use replaces that template.
    @discardableResult
    func save(named name: String, kind: NewDocumentKind, text: String) -> UserTemplate {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Untitled Template" : trimmed
        if let i = templates.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            templates[i].kind = kind
            templates[i].text = text
            persist()
            return templates[i]
        }
        let template = UserTemplate(name: name, kind: kind, text: text)
        templates.append(template)
        persist()
        return template
    }

    func delete(_ id: UserTemplate.ID) {
        templates.removeAll { $0.id == id }
        persist()
    }

    /// Asks for a name, then saves the document's current text.
    func saveTemplate(from document: TabDocument) {
        guard let kind = UserTemplate.kind(forFileType: document.fileType) else { return }
        let alert = NSAlert()
        alert.messageText = "Save as Template"
        alert.informativeText = "New documents can start from this text. A template with the same name is replaced."
        let field = NSTextField(string: document.fileURL?.deletingPathExtension().lastPathComponent ?? "")
        field.placeholderString = "Template name"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        save(named: field.stringValue, kind: kind, text: document.contents.text)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(templates).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Terso: could not save templates: \(error.localizedDescription)")
        }
    }
}
