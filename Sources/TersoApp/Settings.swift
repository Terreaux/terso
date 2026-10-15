// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Observation
import TersoAI
import TersoCore
import TersoStyle

enum SyntaxVisibility: String, CaseIterable, Identifiable {
    case visible, subdued, faint
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum EditorFont: String, CaseIterable, Identifiable {
    case newYork, iowan, charter, georgia, system, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newYork: "New York"
        case .iowan: "Iowan Old Style"
        case .charter: "Charter"
        case .georgia: "Georgia"
        case .system: "SF Pro"
        case .mono: "SF Mono"
        }
    }
    func font(size: CGFloat) -> NSFont {
        switch self {
        case .newYork: NSFont.systemFont(ofSize: size).withDesign(.serif)
        case .iowan: NSFont(name: "Iowan Old Style", size: size) ?? NSFont.systemFont(ofSize: size).withDesign(.serif)
        case .charter: NSFont(name: "Charter", size: size) ?? NSFont.systemFont(ofSize: size).withDesign(.serif)
        case .georgia: NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
        case .system: NSFont.systemFont(ofSize: size)
        case .mono: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

extension NSFont {
    func withDesign(_ design: NSFontDescriptor.SystemDesign) -> NSFont {
        fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? self
    }
    func adding(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}

/// App-wide preferences. Non-secret values only: keys live in the Keychain.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    var font: EditorFont { didSet { d.set(font.rawValue, forKey: "font") } }
    var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    var lineSpacing: Double { didSet { d.set(lineSpacing, forKey: "lineSpacing") } }
    var columnWidth: Double { didSet { d.set(columnWidth, forKey: "columnWidth") } }
    var syntax: SyntaxVisibility { didSet { d.set(syntax.rawValue, forKey: "syntax") } }
    var theme: EditorTheme { didSet { d.set(theme.rawValue, forKey: "theme"); NSApp.appearance = theme.nsAppearance } }
    var dimInactiveParagraphs: Bool { didSet { d.set(dimInactiveParagraphs, forKey: "dimInactive") } }
    var typewriterInFocusMode: Bool { didSet { d.set(typewriterInFocusMode, forKey: "typewriterInFocus") } }
    var showDocumentMap: Bool { didSet { d.set(showDocumentMap, forKey: "documentMap") } }
    var smartQuotes: Bool { didSet { d.set(smartQuotes, forKey: "smartQuotes") } }
    var domain: WritingDomain { didSet { d.set(domain.rawValue, forKey: "domain") } }
    var enabledLayers: Set<AnnotationCategory> { didSet { d.set(enabledLayers.map(\.rawValue), forKey: "layers") } }

    // AI — disabled until the writer turns it on.
    var aiEnabled: Bool { didSet { d.set(aiEnabled, forKey: "aiEnabled") } }
    var defaultScope: ContextScope { didSet { d.set(defaultScope.rawValue, forKey: "defaultScope") } }
    var dataAccess: AIDataAccess { didSet { d.set(dataAccess.rawValue, forKey: "dataAccess") } }
    var selectedProviderID: String { didSet { d.set(selectedProviderID, forKey: "provider") } }
    var cliProviders: [CLIProviderConfiguration] { didSet { save(cliProviders, "cliProviders") } }
    var httpProviders: [HTTPProviderConfiguration] { didSet { save(httpProviders, "httpProviders") } }

    private init() {
        font = EditorFont(rawValue: d.string(forKey: "font") ?? "") ?? .newYork
        fontSize = d.object(forKey: "fontSize") as? Double ?? 17
        lineSpacing = d.object(forKey: "lineSpacing") as? Double ?? 1.6
        columnWidth = d.object(forKey: "columnWidth") as? Double ?? 720
        syntax = SyntaxVisibility(rawValue: d.string(forKey: "syntax") ?? "") ?? .subdued
        // Earlier builds stored only system/light/dark under "appearance".
        theme = EditorTheme(rawValue: d.string(forKey: "theme") ?? d.string(forKey: "appearance") ?? "") ?? .system
        dimInactiveParagraphs = d.object(forKey: "dimInactive") as? Bool ?? true
        typewriterInFocusMode = d.object(forKey: "typewriterInFocus") as? Bool ?? true
        showDocumentMap = d.object(forKey: "documentMap") as? Bool ?? true
        smartQuotes = d.object(forKey: "smartQuotes") as? Bool ?? false
        domain = WritingDomain(rawValue: d.string(forKey: "domain") ?? "") ?? .general
        let layers = (d.array(forKey: "layers") as? [String])?.compactMap(AnnotationCategory.init(rawValue:))
        enabledLayers = Set(layers ?? [.readability, .complexity, .passiveVoice, .style, .repetition, .specificity, .spelling, .aiSuggestion, .notation, .quantities, .references, .claims, .evidence])
        aiEnabled = d.bool(forKey: "aiEnabled")
        defaultScope = ContextScope(rawValue: d.string(forKey: "defaultScope") ?? "") ?? .selection
        dataAccess = AIDataAccess(rawValue: d.string(forKey: "dataAccess") ?? "") ?? .upToSection
        // The on-device model needs no setup and keeps text on this Mac.
        selectedProviderID = d.string(forKey: "provider") ?? (AppleOnDeviceModel.isAvailable ? AppleOnDeviceModel.providerID.rawValue : CLIProviderConfiguration.codex.id)
        cliProviders = Self.load("cliProviders") ?? [.codex, .claude]
        httpProviders = Self.load("httpProviders") ?? [.anthropic, .openAI, .ollama, .lmStudio, .llamaCpp]
        if !d.bool(forKey: "scienceLayersInitialized") {
            enabledLayers.formUnion([.notation, .quantities, .references, .claims, .evidence])
            d.set(enabledLayers.map(\.rawValue), forKey: "layers")
            d.set(true, forKey: "scienceLayersInitialized")
        }
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        d.set(try? JSONEncoder().encode(v), forKey: key)
    }
    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    var baseFont: NSFont { font.font(size: fontSize) }

    struct ProviderEntry: Identifiable {
        let id: String
        let name: String
        let locality: ProviderLocality
        /// Model or command, shown in provenance ("AI · Anthropic · claude-sonnet-5").
        var detail: String? = nil
        let make: () -> any WritingAssistantProvider
    }

    var providers: [ProviderEntry] {
        let apple: [ProviderEntry] = AppleOnDeviceModel.makeProvider().map { p in
            [ProviderEntry(id: p.id.rawValue, name: p.displayName, locality: .local) { p }]
        } ?? []
        return apple + cliProviders.map { c in ProviderEntry(id: c.id, name: c.displayName, locality: .network) { CLIProvider(configuration: c) } }
            + httpProviders.map { h in ProviderEntry(id: h.id, name: h.displayName, locality: h.locality, detail: h.model) { HTTPProvider(configuration: h) } }
    }

    var selectedProvider: ProviderEntry? { providers.first { $0.id == selectedProviderID } ?? providers.first }
}
