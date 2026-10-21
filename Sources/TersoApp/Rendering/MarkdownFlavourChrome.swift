// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore
import WebKit

/// What the preview page reports back: the syntax its platform leaves as
/// typed, counted once the page has drawn. Brings each one into view.
@MainActor
@Observable
final class PreviewBridge {
    @ObservationIgnored weak var webView: WKWebView?
    /// nil until the page has drawn.
    var unrendered: [MarkdownFeature: Int]?
    /// "2 of 5" after a pill brings one into view.
    var position: (feature: MarkdownFeature, index: Int, count: Int)?

    func reveal(_ feature: MarkdownFeature) {
        webView?.evaluateJavaScript("tersoReveal(\(MathPresentation.json(feature.rawValue)))") { [weak self] result, _ in
            guard let pair = result as? [Int], pair.count == 2, pair[1] > 0 else { return }
            MainActor.assumeIsolated { self?.position = (feature, pair[0], pair[1]) }
        }
    }
}

/// Markdown's Preview: the page as the chosen platform draws it, which
/// platform that is, and what it would leave as typed.
struct MarkdownPreviewPane: View {
    let source: String
    let model: WorkspaceModel
    @State private var bridge = PreviewBridge()

    var body: some View {
        MarkdownPreview(source: source, model: model, bridge: bridge)
            // The platform and what it won't render read as one line, clear
            // of the floating toolbar at the bottom.
            .overlay(alignment: .topLeading) {
                HStack(alignment: .center, spacing: 8) {
                    FlavourChip(model: model)
                    CompatibilityBar(model: model, source: source, bridge: bridge)
                }
                .padding(12)
            }
    }
}

/// "Rendering as GitHub", at the top left of a Markdown document in Mixed
/// and Preview: the platform both modes draw it as, and the choice of it.
/// Where the choice came from is in its help.
struct FlavourChip: View {
    let model: WorkspaceModel

    private var origin: String {
        if model.chosenFlavour != nil { return "Chosen for this file" }
        return model.flavourDetection?.reason ?? "Default"
    }

    var body: some View {
        Menu {
            Picker("Render As", selection: Binding(get: { model.chosenFlavour }, set: { model.chosenFlavour = $0 })) {
                Text("Automatic (\(model.automaticFlavour.title), \(model.flavourDetection?.reason ?? "Settings"))")
                    .tag(MarkdownFlavour?.none)
                Divider()
                ForEach(MarkdownFlavour.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
        } label: {
            // A menu's label is drawn as one title, so it is one string.
            Text("Rendering as \(model.markdownFlavour.title)")
        }
        .menuStyle(.button)
        .menuIndicator(.visible)
        .buttonStyle(.accessoryBar)
        .controlSize(.small)
        .fixedSize()
        .padding(.horizontal, 4)
        // The bar beside it in Preview is as tall, so the chip stays put between modes.
        .frame(height: CompatibilityBar.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .help("\(model.markdownFlavour.help). \(origin).")
        .accessibilityLabel("Rendering as \(model.markdownFlavour.title)")
        .accessibilityHint(origin)
    }
}

/// What the platform won't render, a pill per kind that finds each one,
/// and a conversion where the platform has its own form.
struct CompatibilityBar: View {
    static let height: CGFloat = 30
    let model: WorkspaceModel
    let source: String
    let bridge: PreviewBridge

    var body: some View {
        let flavour = model.markdownFlavour
        if flavour != .terso, let counts = bridge.unrendered {
            let missing = MarkdownFeature.allCases.compactMap { f in counts[f].map { (feature: f, count: $0) } }
            let edits = MarkdownConversion.edits(in: source, to: flavour)
            Group {
                if missing.isEmpty {
                    Label("Renders as written on \(flavour.title)", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                } else {
                    // Narrower previews drop the words, then fold the pills into a menu.
                    ViewThatFits(in: .horizontal) {
                        full(flavour, missing, edits, worded: true)
                        full(flavour, missing, edits, worded: false)
                        compact(flavour, missing, edits)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
            .font(.system(size: 12))
            .frame(height: Self.height)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .animation(.snappy(duration: 0.2), value: missing.map(\.count))
        }
    }

    private func full(_ flavour: MarkdownFlavour, _ missing: [(feature: MarkdownFeature, count: Int)],
                      _ edits: [MarkdownConversion.Edit], worded: Bool) -> some View {
        HStack(spacing: 6) {
            warning(flavour, worded: worded)
            ForEach(missing, id: \.feature) { item in pill(item.feature, item.count) }
            convert(flavour, edits)
        }
        .fixedSize()
    }

    private func compact(_ flavour: MarkdownFlavour, _ missing: [(feature: MarkdownFeature, count: Int)],
                         _ edits: [MarkdownConversion.Edit]) -> some View {
        HStack(spacing: 6) {
            warning(flavour)
            let total = missing.reduce(0) { $0 + $1.count }
            Menu("\(total) \(total == 1 ? "place" : "places")") {
                ForEach(missing, id: \.feature) { item in
                    Button("\(item.feature.title.capitalizedFirst) (\(item.count))") { bridge.reveal(item.feature) }
                }
            }
            .menuStyle(.button).menuIndicator(.visible).buttonStyle(.accessoryBar).fixedSize()
            convert(flavour, edits)
        }
        .fixedSize()
    }

    private func warning(_ flavour: MarkdownFlavour, worded: Bool = true) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            if worded { Text("\(flavour.title) won't render").foregroundStyle(.secondary) }
        }
        .help("\(flavour.title) won't render these; they show as typed")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(flavour.title) won't render")
    }

    private func pill(_ feature: MarkdownFeature, _ count: Int) -> some View {
        let shown = bridge.position.flatMap { $0.feature == feature ? $0 : nil }
        return Button { bridge.reveal(feature) } label: {
            HStack(spacing: 4) {
                Text(feature.title)
                Text(shown.map { "\($0.index)/\($0.count)" } ?? "\(count)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show the next \(count == 1 ? "one" : "of \(count)")")
        .accessibilityLabel("\(feature.title), \(count)")
        .accessibilityHint("Shows the next one in the preview")
    }

    @ViewBuilder
    private func convert(_ flavour: MarkdownFlavour, _ edits: [MarkdownConversion.Edit]) -> some View {
        if !edits.isEmpty {
            Divider().frame(height: 14)
            Button("Convert for \(flavour.title)") { model.convertMarkdown(to: flavour) }
                .buttonStyle(.accessoryBar)
                .help("Rewrites \(MarkdownConversion.summary(of: edits, for: flavour)). ⌘Z undoes it.")
                .disabled(model.editor == nil)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
