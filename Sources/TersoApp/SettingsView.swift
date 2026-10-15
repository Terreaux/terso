// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoAI
import TersoCore
import TersoStyle

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            EditorSettings().tabItem { Label("Editor", systemImage: "textformat") }
            AnalysisSettings().tabItem { Label("Analysis", systemImage: "text.magnifyingglass") }
            AssistantSettings().tabItem { Label("Assistant", systemImage: "sparkles") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock") }
        }
        .frame(width: 560)
        .padding(20)
    }
}

struct GeneralSettings: View {
    @Bindable var prefs = Preferences.shared
    var body: some View {
        Form {
            Section("At launch") {
                Toggle("Greet me with a quote about writing", isOn: $prefs.greetWithQuote)
                Text("Click or press any key to begin; the quote also fades on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct EditorSettings: View {
    @Bindable var prefs = Preferences.shared
    var body: some View {
        Form {
            Picker("Font", selection: $prefs.font) { ForEach(EditorFont.allCases) { Text($0.title).tag($0) } }
            LabeledContent("Size") {
                HStack { Slider(value: $prefs.fontSize, in: 12...28, step: 1); Text("\(Int(prefs.fontSize)) pt").monospacedDigit().frame(width: 44) }
            }
            LabeledContent("Line spacing") {
                HStack { Slider(value: $prefs.lineSpacing, in: 1.0...2.2, step: 0.05); Text(String(format: "%.2f", prefs.lineSpacing)).monospacedDigit().frame(width: 44) }
            }
            LabeledContent("Writing width") {
                HStack { Slider(value: $prefs.columnWidth, in: 600...860, step: 10); Text("\(Int(prefs.columnWidth)) pt").monospacedDigit().frame(width: 54) }
            }
            Picker("Markdown syntax", selection: $prefs.syntax) { ForEach(SyntaxVisibility.allCases) { Text($0.title).tag($0) } }
            Picker("Theme", selection: $prefs.theme) { ForEach(EditorTheme.allCases) { Text($0.title).tag($0) } }
            Toggle("Smart quotes", isOn: $prefs.smartQuotes)
            Section("Focus and Zen modes") {
                Toggle("Dim inactive paragraphs", isOn: $prefs.dimInactiveParagraphs)
                Toggle("Typewriter scrolling", isOn: $prefs.typewriterInFocusMode)
            }
        }
        .formStyle(.grouped)
    }
}

struct AnalysisSettings: View {
    @Bindable var prefs = Preferences.shared
    var body: some View {
        Form {
            Section("Layers shown by default") {
                ForEach(AnnotationCategory.allCases) { c in
                    Toggle(c.title, isOn: Binding(
                        get: { prefs.enabledLayers.contains(c) },
                        set: { on in if on { prefs.enabledLayers.insert(c) } else { prefs.enabledLayers.remove(c) } }))
                }
            }
            Toggle("Show document map", isOn: $prefs.showDocumentMap)
            Section("Style reference") {
                Picker("Register", selection: $prefs.domain) {
                    ForEach(WritingDomain.allCases) { d in Text(d.title + (BaselineLibrary.profile(for: d) == nil ? " — no reference data yet" : "")).tag(d) }
                }
                Text("Human reference ranges come from measured corpora. Registers without measured data show raw values only; Terso does not invent baselines.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Writing stats") {
                Toggle("Show today’s typed words in the header", isOn: $prefs.showWritingProgress)
                Toggle("Show a note when I earn an award", isOn: $prefs.celebrateAwards)
                Text("Terso counts the words you type, not the ones you paste. Only counts are kept, on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AssistantSettings: View {
    @Bindable var prefs = Preferences.shared
    @State private var keyDrafts: [String: String] = [:]
    @State private var status: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                Toggle("Enable assistant", isOn: $prefs.aiEnabled)
                Picker("AI data access", selection: $prefs.dataAccess) {
                    ForEach(AIDataAccess.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Picker("Default context", selection: $prefs.defaultScope) {
                    ForEach(ContextScope.allCases) { Text($0.title).tag($0) }
                }
                Text("The assistant only ever proposes changes. Nothing in your document changes until you press Accept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("On-device") {
                HStack {
                    Text(AppleOnDeviceModel.displayName).fontWeight(.medium)
                    LocalityBadge(locality: .local)
                    Spacer()
                    Text(AppleOnDeviceModel.unavailableReason ?? "Ready").font(.caption).foregroundStyle(.secondary)
                }
                Text("Runs on this Mac with no key or network. Best for selections and sections; long documents are reviewed in parts.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Section("Command-line assistants") {
                ForEach($prefs.cliProviders) { $c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(c.displayName).fontWeight(.medium)
                            LocalityBadge(locality: .network)
                            Spacer()
                            Text(ProcessRunner.locate(c.command)?.path ?? "not found").font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("Command", text: $c.command)
                        TextField("Arguments", text: Binding(
                            get: { c.arguments.joined(separator: " ") },
                            set: { c.arguments = $0.split(separator: " ").map(String.init) }))
                            .font(.system(.caption, design: .monospaced))
                        Text("Runs in a temporary folder containing only the chosen passage, with the prompt on stdin. It never receives your file.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Section("API and local models") {
                ForEach($prefs.httpProviders) { $h in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(h.displayName).fontWeight(.medium)
                            LocalityBadge(locality: h.locality)
                            Spacer()
                            if let s = status[h.id] { Text(s).font(.caption).foregroundStyle(.secondary) }
                        }
                        TextField("Base URL", text: $h.baseURL)
                        TextField("Model", text: $h.model)
                        if h.requiresKey {
                            HStack {
                                SecureField("API key (stored in Keychain)", text: Binding(get: { keyDrafts[h.id] ?? "" }, set: { keyDrafts[h.id] = $0 }))
                                Button("Save") {
                                    do {
                                        try KeychainStore.save(keyDrafts[h.id] ?? "", account: h.keychainAccount)
                                        keyDrafts[h.id] = ""
                                        status[h.id] = "Key saved"
                                    } catch { status[h.id] = "Keychain error" }
                                }
                                Button("Remove") { KeychainStore.delete(account: h.keychainAccount); status[h.id] = "Key removed" }
                            }
                        }
                    }
                }
                Button("Add OpenAI-compatible endpoint") {
                    prefs.httpProviders.append(HTTPProviderConfiguration(id: "custom.\(UUID().uuidString.prefix(8))", displayName: "Custom endpoint",
                                                                         flavor: .openAICompatible, baseURL: "http://localhost:8000/v1", model: "model", requiresKey: false))
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
    }
}

struct PrivacySettings: View {
    var body: some View {
        Form {
            LabeledContent("Documents") { Text("Stay on this Mac as plain files.") }
            LabeledContent("Telemetry") { Text("None. Terso collects nothing.") }
            LabeledContent("Local analysis") { Text("Runs entirely on this Mac.") }
            LabeledContent("Assistant") { Text("Off until enabled. Sends only the context you choose, when you ask.") }
            LabeledContent("Credentials") { Text("Stored in the macOS Keychain.") }
            Section("Acknowledgements") {
                Text(BaselineLibrary.attribution)
                    .font(.caption).foregroundStyle(.secondary)
                Text("Terso is free software under the GNU Affero General Public License v3.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
