// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import PDFKit
import Observation

struct TectonicPreview: View {
    let source: String
    let fileURL: URL?
    @State private var compiler = TectonicPreviewModel()
    var body: some View {
        VStack(spacing: 0) {
            if compiler.running {
                HStack { ProgressView().controlSize(.small); Text("Typesetting LaTeX…").foregroundStyle(.secondary) }.padding()
            }
            if let data = compiler.pdf { CompiledPDF(data: data) }
            if let error = compiler.error {
                ContentUnavailableView {
                    Label("LaTeX preview unavailable", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(error)
                } actions: {
                    Button("Compile again") { Task { await compiler.compile(source: source, fileURL: fileURL) } }
                    if TectonicPreviewModel.executable != nil {
                        Button("Compile and fetch missing packages") {
                            Task { await compiler.compile(source: source, fileURL: fileURL, onlyCached: false) }
                        }
                    }
                }
                if !compiler.log.isEmpty {
                    DisclosureGroup("Compiler output") {
                        ScrollView { Text(compiler.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                    }.padding()
                }
            }
        }
        .task(id: "\(fileURL?.path ?? ""):\(source)") { await compiler.compile(source: source, fileURL: fileURL) }
        .onDisappear { compiler.cancel() }
    }
}

private struct CompiledPDF: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.data != data {
            context.coordinator.data = data
            view.document = PDFDocument(data: data)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var data: Data? }
}

@MainActor @Observable final class TectonicPreviewModel {
    var pdf: Data?
    var running = false
    var error: String?
    var log = ""
    /// Keep the last good PDF through a compile and past a failed one, as
    /// Manutius does so its pages don't blank while the source is mid-edit.
    var keepsLastPages = false
    private var process: Process?
    private var generation = UUID()

    static var executable: URL? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent("tectonic") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func cancel() {
        generation = UUID()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        running = false
    }

    func compile(source: String, fileURL: URL?, onlyCached: Bool = true) async {
        cancel()
        let request = generation
        if !keepsLastPages { pdf = nil }
        error = nil; log = ""
        guard let executable = Self.executable else {
            error = "Full LaTeX preview requires Tectonic. Install it, then choose Compile again. Source and Mixed modes remain available."
            return
        }
        running = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terso-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let input = directory.appendingPathComponent("source.tex")
            try source.write(to: input, atomically: true, encoding: .utf8)
            // An unsaved book compiles where it is written, beside Terso's
            // own terso-book.sty; a saved one uses the copy beside its file.
            if fileURL == nil, LaTeXBookDesign.line(in: source) != nil { try? LaTeXBookDesign.install(in: directory) }
            let output = directory.appendingPathComponent("compiler.txt")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let writer = try FileHandle(forWritingTo: output)
            let reader = try FileHandle(forReadingFrom: input)
            defer { try? writer.close(); try? reader.close() }
            let task = Process()
            process = task
            task.executableURL = executable
            task.currentDirectoryURL = fileURL?.deletingLastPathComponent() ?? directory
            task.arguments = ["--untrusted", "--outdir", directory.path, "--keep-logs"] + (onlyCached ? ["--only-cached"] : []) + ["-"]
            task.standardInput = reader; task.standardOutput = writer; task.standardError = writer
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(45))
                if !Task.isCancelled, task.isRunning { task.terminate() }
            }
            defer { timeout.cancel() }
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                task.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
                do { try task.run() } catch { task.terminationHandler = nil; continuation.resume(throwing: error) }
            }
            guard generation == request, !Task.isCancelled else { return }
            log = String((try? String(contentsOf: output, encoding: .utf8))?.suffix(12_000) ?? "")
            guard status == 0 else {
                error = onlyCached ? "Compilation failed. Check the compiler output; missing cached packages can be fetched with the button below." : "Compilation failed. Check the compiler output and edit the LaTeX source."
                running = false; return
            }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard let result = files.first(where: { $0.pathExtension == "pdf" }) else { throw CocoaError(.fileReadUnknown) }
            pdf = try Data(contentsOf: result)
            running = false; process = nil
        } catch {
            guard generation == request else { return }
            self.error = error.localizedDescription; running = false; process = nil
        }
    }
}
