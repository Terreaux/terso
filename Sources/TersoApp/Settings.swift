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

enum EditorFont: String, Codable, CaseIterable, Identifiable {
    case newYork, iowan, charter, georgia, baskerville, palatino, hoefler, system, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newYork: "New York"
        case .iowan: "Iowan Old Style"
        case .charter: "Charter"
        case .georgia: "Georgia"
        case .baskerville: "Baskerville"
        case .palatino: "Palatino"
        case .hoefler: "Hoefler Text"
        case .system: "SF Pro"
        case .mono: "SF Mono"
        }
    }
    /// A word on how the face reads, for choosing a book's type.
    var character: String {
        switch self {
        case .newYork: "Crisp, contemporary"
        case .iowan: "Warm, readable"
        case .charter: "Sturdy, plain"
        case .georgia: "Generous, open"
        case .baskerville: "Classic, literary"
        case .palatino: "Calligraphic, elegant"
        case .hoefler: "Old-style, bookish"
        case .system: "Clean, modern"
        case .mono: "Typewritten"
        }
    }
    func font(size: CGFloat) -> NSFont {
        switch self {
        case .newYork: NSFont.systemFont(ofSize: size).withDesign(.serif)
        case .iowan: NSFont(name: "Iowan Old Style", size: size) ?? NSFont.systemFont(ofSize: size).withDesign(.serif)
        case .charter: NSFont(name: "Charter", size: size) ?? NSFont.systemFont(ofSize: size).withDesign(.serif)
        case .georgia: NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
        case .baskerville: NSFont(name: "Baskerville", size: size) ?? NSFont.systemFont(ofSize: size).withDesign(.serif)
        case .palatino: NSFont(name: "Palatino-Roman", size: size) ?? NSFont.systemFont(ofSize: size).withDesign(.serif)
        case .hoefler: NSFont(name: "HoeflerText-Regular", size: size) ?? NSFont.systemFont(ofSize: size).withDesign(.serif)
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
    /// What Mixed draws in place of its source, away from the editing line.
    var mixedRendered: Set<MixedElement> { didSet { d.set(mixedRendered.map(\.rawValue), forKey: "mixedRendered") } }
    var theme: EditorTheme { didSet { d.set(theme.rawValue, forKey: "theme"); NSApp.appearance = theme.nsAppearance } }
    var dimInactiveParagraphs: Bool { didSet { d.set(dimInactiveParagraphs, forKey: "dimInactive") } }
    var typewriterInFocusMode: Bool { didSet { d.set(typewriterInFocusMode, forKey: "typewriterInFocus") } }
    var showDocumentMap: Bool { didSet { d.set(showDocumentMap, forKey: "documentMap") } }
    var smartQuotes: Bool { didSet { d.set(smartQuotes, forKey: "smartQuotes") } }
    /// Opt-in: a quote about writing greets the writer when Terso launches.
    var greetWithQuote: Bool { didSet { d.set(greetWithQuote, forKey: "greetWithQuote") } }
    var domain: WritingDomain { didSet { d.set(domain.rawValue, forKey: "domain") } }
    var enabledLayers: Set<AnnotationCategory> { didSet { d.set(enabledLayers.map(\.rawValue), forKey: "layers") } }

    // AI — disabled until the writer turns it on.
    var aiEnabled: Bool { didSet { d.set(aiEnabled, forKey: "aiEnabled") } }
    var defaultScope: ContextScope { didSet { d.set(defaultScope.rawValue, forKey: "defaultScope") } }
    var dataAccess: AIDataAccess { didSet { d.set(dataAccess.rawValue, forKey: "dataAccess") } }
    var selectedProviderID: String { didSet { d.set(selectedProviderID, forKey: "provider") } }
    var cliProviders: [CLIProviderConfiguration] { didSet { save(cliProviders, "cliProviders") } }
    var httpProviders: [HTTPProviderConfiguration] { didSet { save(httpProviders, "httpProviders") } }

    /// Today's typed words in the header, and a quiet note when an award is earned.
    var showWritingProgress: Bool { didSet { d.set(showWritingProgress, forKey: "showWritingProgress") } }
    var celebrateAwards: Bool { didSet { d.set(celebrateAwards, forKey: "celebrateAwards") } }
    /// Opt-in: a macOS notification when an award is earned, even with Terso in the background.
    var notifyAwards: Bool { didSet { d.set(notifyAwards, forKey: "notifyAwards") } }
    /// Opt-in: the stats window shows made-up numbers, to see how it looks with awards.
    /// Nothing is saved; turning it off brings back the real record.
    var sampleWritingStats: Bool { didSet { d.set(sampleWritingStats, forKey: "sampleWritingStats") } }
    /// How Manutius sets the book: trim, chapters, openings, ornaments.
    var bookDesign: BookDesign { didSet { save(bookDesign, "bookDesign") } }

    private init() {
        font = EditorFont(rawValue: d.string(forKey: "font") ?? "") ?? .newYork
        fontSize = d.object(forKey: "fontSize") as? Double ?? 17
        lineSpacing = d.object(forKey: "lineSpacing") as? Double ?? 1.6
        columnWidth = d.object(forKey: "columnWidth") as? Double ?? 720
        syntax = SyntaxVisibility(rawValue: d.string(forKey: "syntax") ?? "") ?? .subdued
        // Groups added after the first release of these choices are turned on
        // once for people who had already saved a selection. Builds before
        // "mixedGroupsOffered" recorded only that the first six had been.
        var mixed = Set((d.array(forKey: "mixedRendered") as? [String])?.compactMap(MixedElement.init(rawValue:))
                        ?? MixedElement.defaults)
        let offered = Set(d.stringArray(forKey: "mixedGroupsOffered")
                          ?? (d.bool(forKey: "mixedGroupsAdded") ? ["code", "blocks", "tables", "footnotes", "citations", "comments"] : []))
        let unoffered = MixedElement.addedLater.filter { !offered.contains($0.rawValue) }
        if !unoffered.isEmpty {
            mixed.formUnion(unoffered)
            d.set(mixed.map(\.rawValue), forKey: "mixedRendered")
            d.set(MixedElement.addedLater.map(\.rawValue), forKey: "mixedGroupsOffered")
        }
        mixedRendered = mixed
        // Earlier builds stored only system/light/dark under "appearance".
        theme = EditorTheme(rawValue: d.string(forKey: "theme") ?? d.string(forKey: "appearance") ?? "") ?? .system
        dimInactiveParagraphs = d.object(forKey: "dimInactive") as? Bool ?? true
        typewriterInFocusMode = d.object(forKey: "typewriterInFocus") as? Bool ?? true
        showDocumentMap = d.object(forKey: "documentMap") as? Bool ?? true
        smartQuotes = d.object(forKey: "smartQuotes") as? Bool ?? false
        domain = WritingDomain(rawValue: d.string(forKey: "domain") ?? "") ?? .general
        let layers = (d.array(forKey: "layers") as? [String])?.compactMap(AnnotationCategory.init(rawValue:))
        enabledLayers = layers.map(Set.init) ?? Self.defaultLayers
        greetWithQuote = d.bool(forKey: "greetWithQuote")
        aiEnabled = d.bool(forKey: "aiEnabled")
        defaultScope = ContextScope(rawValue: d.string(forKey: "defaultScope") ?? "") ?? .selection
        dataAccess = AIDataAccess(rawValue: d.string(forKey: "dataAccess") ?? "") ?? .upToSection
        // The on-device model needs no setup and keeps text on this Mac.
        selectedProviderID = d.string(forKey: "provider") ?? (AppleOnDeviceModel.isAvailable ? AppleOnDeviceModel.providerID.rawValue : CLIProviderConfiguration.codex.id)
        cliProviders = Self.load("cliProviders") ?? [.codex, .claude]
        httpProviders = Self.load("httpProviders") ?? [.anthropic, .openAI, .ollama, .lmStudio, .llamaCpp]
        showWritingProgress = d.object(forKey: "showWritingProgress") as? Bool ?? true
        celebrateAwards = d.object(forKey: "celebrateAwards") as? Bool ?? true
        notifyAwards = d.bool(forKey: "notifyAwards")
        sampleWritingStats = d.bool(forKey: "sampleWritingStats")
        bookDesign = Self.load("bookDesign") ?? BookDesign()
        // The migrations below carry an earlier saved selection forward; a
        // first launch already has the current defaults.
        if layers == nil {
            d.set(true, forKey: "scienceLayersInitialized")
            d.set(true, forKey: "writingLayersSplit")
            d.set(true, forKey: "storyShapeOffered")
        }
        if !d.bool(forKey: "scienceLayersInitialized") {
            enabledLayers.formUnion([.notation, .quantities, .references, .claims, .evidence])
            d.set(enabledLayers.map(\.rawValue), forKey: "layers")
            d.set(true, forKey: "scienceLayersInitialized")
        }
        // Style, Repetition and Readability were split into finer layers;
        // carry each old choice over to the layers it became.
        if !d.bool(forKey: "writingLayersSplit") {
            if enabledLayers.contains(.style) { enabledLayers.formUnion([.filler, .adverbs]) }
            if enabledLayers.contains(.repetition) { enabledLayers.insert(.lexicalIllusions) }
            if enabledLayers.contains(.readability) { enabledLayers.insert(.rhythm) }
            enabledLayers.formUnion([.loosePronouns, .misused])
            d.set(enabledLayers.map(\.rawValue), forKey: "layers")
            d.set(true, forKey: "writingLayersSplit")
        }
        // Story shape arrived later; it only speaks in the Fiction register.
        if !d.bool(forKey: "storyShapeOffered") {
            enabledLayers.insert(.storyShape)
            d.set(enabledLayers.map(\.rawValue), forKey: "layers")
            d.set(true, forKey: "storyShapeOffered")
        }
    }

    /// A calm first page: mistakes and the clearest style advice. Science,
    /// repetition, rhythm, adverbs and the rest are a click away in the header.
    static let defaultLayers: Set<AnnotationCategory> = [
        .spelling, .misused, .lexicalIllusions, .filler, .passiveVoice, .complexity, .aiSuggestion, .storyShape,
    ]

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
