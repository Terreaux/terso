// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Formats a document can be written to. The manuscript itself is never
/// changed; every export is a new file chosen by the writer.
enum ExportFormat: String, CaseIterable, Identifiable {
    case source, html, pdf, word, richText
    var id: String { rawValue }

    func title(latex: Bool) -> String {
        switch self {
        case .source: latex ? "LaTeX Source" : "Markdown"
        case .html: "Web Page (HTML)"
        case .pdf: "PDF"
        case .word: "Word Document"
        case .richText: "Rich Text (RTF)"
        }
    }

    func fileExtension(latex: Bool) -> String {
        switch self {
        case .source: latex ? "tex" : "md"
        case .html: "html"
        case .pdf: "pdf"
        case .word: "docx"
        case .richText: "rtf"
        }
    }

    /// LaTeX is typeset by Tectonic, so only its source and PDF are faithful.
    static func available(latex: Bool) -> [ExportFormat] { latex ? [.source, .pdf] : allCases }
}

@MainActor
enum DocumentExport {
    private static var inFlight: [UUID: RenderedExport] = [:]

    static func isLaTeX(_ document: TabDocument) -> Bool {
        RenderMode.isLaTeX(source: document.contents.text, fileURL: document.fileURL)
    }

    static func export(_ document: TabDocument, as format: ExportFormat) {
        let latex = isLaTeX(document)
        let panel = NSSavePanel()
        let ext = format.fileExtension(latex: latex)
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName) + "." + ext
        panel.directoryURL = document.fileURL?.deletingLastPathComponent()
        let window = document.workspace?.window
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await write(document, as: format, latex: latex, to: url, window: window) }
                catch { presentError(error, window: window) }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(panel.runModal()) }
    }

    private static func write(_ document: TabDocument, as format: ExportFormat, latex: Bool, to url: URL, window: NSWindow?) async throws {
        let text = document.contents.text
        let directory = document.fileURL?.deletingLastPathComponent()
        switch format {
        case .source:
            try document.contents.codec.encode(text).write(to: url, options: .atomic)
        case .pdf where latex:
            let compiler = TectonicPreviewModel()
            await compiler.compile(source: text, fileURL: document.fileURL)
            guard let pdf = compiler.pdf else {
                throw ExportError(message: "LaTeX could not be typeset for export.",
                                  detail: [compiler.error, String(compiler.log.suffix(1_500))].compactMap { $0 }.joined(separator: "\n\n"))
            }
            try pdf.write(to: url, options: .atomic)
        default:
            let id = UUID()
            let rendered = RenderedExport(source: text, directory: directory)
            inFlight[id] = rendered
            defer { inFlight[id] = nil }
            try await rendered.load()
            switch format {
            case .html:
                let html = try await rendered.standaloneHTML(title: document.displayName)
                try Data(html.utf8).write(to: url, options: .atomic)
            case .pdf:
                try await rendered.printPDF(to: url, window: window)
            case .word, .richText:
                let body = try await rendered.bodyWithTeXMath()
                let attributed = try RenderedExport.attributed(fromBody: body, directory: directory)
                let type: NSAttributedString.DocumentType = format == .word ? .officeOpenXML : .rtf
                let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                               documentAttributes: [.documentType: type])
                try data.write(to: url, options: .atomic)
            case .source: break
            }
        }
    }

    private static func presentError(_ error: Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let error = error as? ExportError {
            alert.messageText = error.message
            alert.informativeText = error.detail
        } else {
            alert.messageText = "The document couldn’t be exported."
            alert.informativeText = error.localizedDescription
        }
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

struct ExportError: Error {
    let message: String
    var detail = ""
}

/// Renders through the same HTML as Preview mode, so exported math, tables and
/// images match what the writer sees. Always light: exports are for paper and
/// other readers, not this window's appearance.
@MainActor
private final class RenderedExport: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let source: String
    /// WebKit only paints (and therefore prints) views that belong to a window.
    private let host: NSWindow
    private var loaded: CheckedContinuation<Void, Error>?
    private var printed: CheckedContinuation<Bool, Never>?

    init(source: String, directory: URL?) {
        self.source = source
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(PreviewImages(directory: directory), forURLScheme: "terso-image")
        let frame = NSRect(x: 0, y: 0, width: 816, height: 1056)
        webView = WKWebView(frame: frame, configuration: config)
        host = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    func load() async throws {
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(MarkdownPreviewHTML.document(source: source, dark: false, fontSize: 15), baseURL: nil)
        }
        // Mermaid diagrams, math fonts and local images finish after navigation.
        _ = try await webView.callAsyncJavaScript("""
            await window.tersoMermaidReady;
            await document.fonts.ready;
            await Promise.all([...document.images].map(img => img.complete ? null : new Promise(done => { img.onload = img.onerror = done; })));
            return true;
            """, contentWorld: .page)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume(); loaded = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error); loaded = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error); loaded = nil
    }

    /// Self-contained: KaTeX CSS and fonts are already inlined; scripts and the
    /// preview's image scheme are removed so the page opens in any browser.
    func standaloneHTML(title: String) async throws -> String {
        let html = try await webView.callAsyncJavaScript("""
            const clone = document.documentElement.cloneNode(true);
            clone.querySelectorAll('script, meta[http-equiv]').forEach(e => e.remove());
            clone.querySelectorAll('[data-source]').forEach(e => e.removeAttribute('data-source'));
            clone.querySelectorAll('img').forEach(img => {
                const src = img.getAttribute('src') || '';
                if (src.startsWith(prefix)) img.setAttribute('src', src.slice(prefix.length));
            });
            const heading = document.createElement('title'); heading.textContent = title;
            clone.querySelector('head').prepend(heading);
            clone.querySelector('body').style.background = '#fff';
            return '<!doctype html>\\n' + clone.outerHTML;
            """, arguments: ["prefix": "terso-image://document/", "title": title], contentWorld: .page)
        guard let html = html as? String else { throw ExportError(message: "The rendered page couldn’t be read.") }
        return html
    }

    /// Word processors can't typeset KaTeX's HTML, so math returns to its TeX
    /// source (`$…$`), which Word and Pages users can convert or retype.
    func bodyWithTeXMath() async throws -> String {
        let html = try await webView.callAsyncJavaScript("""
            const root = document.getElementById('document').cloneNode(true);
            root.querySelectorAll('.katex').forEach(k => {
                const tex = k.querySelector('annotation[encoding="application/x-tex"]');
                const display = !!k.closest('.katex-display');
                const text = tex ? (display ? '$$' + tex.textContent + '$$' : '$' + tex.textContent + '$') : k.textContent;
                k.replaceWith(document.createTextNode(text));
            });
            root.querySelectorAll('img').forEach(img => {
                const src = img.getAttribute('src') || '';
                if (src.startsWith(prefix)) img.setAttribute('src', src.slice(prefix.length));
            });
            return root.innerHTML;
            """, arguments: ["prefix": "terso-image://document/"], contentWorld: .page)
        guard let html = html as? String else { throw ExportError(message: "The rendered page couldn’t be read.") }
        return html
    }

    static func attributed(fromBody body: String, directory: URL?) throws -> NSAttributedString {
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><style>
            body { font-family: 'Helvetica Neue', Helvetica, sans-serif; font-size: 12pt; line-height: 1.4; }
            pre, code { font-family: Menlo, monospace; font-size: 10.5pt; }
            blockquote { color: #555; } table { border-collapse: collapse; } th, td { border: 1px solid #999; padding: 4px 8px; }
            </style></head><body>\(body)</body></html>
            """
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let directory { options[.baseURL] = directory }
        return try NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil)
    }

    /// Paginated through AppKit printing (a web view's own PDF is one tall page).
    func printPDF(to url: URL, window: NSWindow?) async throws {
        _ = try await webView.callAsyncJavaScript("""
            const style = document.createElement('style');
            style.textContent = 'main { max-width: none; padding: 0; } section, pre, table, img, .katex-display { break-inside: avoid; } h1, h2, h3 { break-after: avoid; }';
            document.head.append(style);
            return true;
            """, contentWorld: .page)
        let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
        info.jobDisposition = .save
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        for margin in [\NSPrintInfo.topMargin, \.bottomMargin] { info[keyPath: margin] = 54 }
        for margin in [\NSPrintInfo.leftMargin, \.rightMargin] { info[keyPath: margin] = 60 }
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        let success = await withCheckedContinuation { continuation in
            printed = continuation
            operation.runModal(for: window ?? host, delegate: self,
                               didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard success else { throw ExportError(message: "The PDF couldn’t be written.") }
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printed?.resume(returning: success); printed = nil
    }
}

/// The toolbar's share button: every item writes a new file.
struct ExportMenu: View {
    @ObservedObject var document: TabDocument

    var body: some View {
        let latex = DocumentExport.isLaTeX(document)
        Menu {
            Section("Export As") {
                ForEach(ExportFormat.available(latex: latex)) { format in
                    Button(format.title(latex: latex) + "…") { DocumentExport.export(document, as: format) }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Export as Markdown, HTML, PDF, Word or Rich Text")
        .accessibilityLabel("Export")
    }
}
