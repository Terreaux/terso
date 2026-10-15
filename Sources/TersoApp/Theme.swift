// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// Editor colour themes. System, Light and Dark follow the platform's
/// dynamic colours; the named themes pin an appearance (so window chrome,
/// math images and the preview match) and supply their own paper and ink.
enum EditorTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    case sepia, githubLight, solarizedLight, catppuccinLatte
    case solarizedDark, nord, dracula, oneDark, catppuccinMocha
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .sepia: "Sepia"
        case .githubLight: "GitHub Light"
        case .solarizedLight: "Solarized Light"
        case .solarizedDark: "Solarized Dark"
        case .nord: "Nord"
        case .dracula: "Dracula"
        case .oneDark: "One Dark"
        case .catppuccinLatte: "Catppuccin Latte"
        case .catppuccinMocha: "Catppuccin Mocha"
        }
    }

    static let lightThemes: [Self] = [.sepia, .githubLight, .solarizedLight, .catppuccinLatte]
    static let darkThemes: [Self] = [.solarizedDark, .nord, .dracula, .oneDark, .catppuccinMocha]

    var isDark: Bool? {
        switch self {
        case .system: nil
        case .light, .sepia, .githubLight, .solarizedLight, .catppuccinLatte: false
        case .dark, .solarizedDark, .nord, .dracula, .oneDark, .catppuccinMocha: true
        }
    }

    var nsAppearance: NSAppearance? {
        isDark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
    }

    /// Fixed colours for named themes; nil means use system dynamic colours.
    var palette: ThemePalette? {
        switch self {
        case .system, .light, .dark: nil
        // Chrome is each theme's own panel shade (Catppuccin's "mantle",
        // GitHub's canvas-subtle, Solarized's base2/base02, …).
        case .sepia: ThemePalette(background: 0xF4ECD8, chrome: 0xEADFC6, ink: 0x433422, accent: 0xA0522D)
        case .githubLight: ThemePalette(background: 0xFFFFFF, chrome: 0xF6F8FA, ink: 0x1F2328, accent: 0x0969DA)
        case .solarizedLight: ThemePalette(background: 0xFDF6E3, chrome: 0xEEE8D5, ink: 0x586E75, accent: 0x268BD2)
        case .catppuccinLatte: ThemePalette(background: 0xEFF1F5, chrome: 0xE6E9EF, ink: 0x4C4F69, accent: 0x8839EF)
        case .solarizedDark: ThemePalette(background: 0x002B36, chrome: 0x073642, ink: 0x93A1A1, accent: 0x2AA198)
        case .nord: ThemePalette(background: 0x2E3440, chrome: 0x292E39, ink: 0xD8DEE9, accent: 0x88C0D0)
        case .dracula: ThemePalette(background: 0x282A36, chrome: 0x21222C, ink: 0xF8F8F2, accent: 0xBD93F9)
        case .oneDark: ThemePalette(background: 0x282C34, chrome: 0x21252B, ink: 0xABB2BF, accent: 0x61AFEF)
        case .catppuccinMocha: ThemePalette(background: 0x1E1E2E, chrome: 0x181825, ink: 0xCDD6F4, accent: 0xCBA6F7)
        }
    }

    // MARK: Roles used by the editor

    var background: NSColor { palette?.background ?? .textBackgroundColor }
    /// Full-strength ink: headings and emphasis.
    var label: NSColor { palette?.ink ?? .labelColor }
    var secondary: NSColor { palette?.ink.withAlphaComponent(0.72) ?? .secondaryLabelColor }
    var tertiary: NSColor { palette?.ink.withAlphaComponent(0.48) ?? .tertiaryLabelColor }
    var quaternary: NSColor { palette?.ink.withAlphaComponent(0.30) ?? .quaternaryLabelColor }
    var separator: NSColor { palette?.ink.withAlphaComponent(0.25) ?? .separatorColor }
    var accent: NSColor { palette?.accent ?? .controlAccentColor }

    /// Body text a touch softer than full-strength label colour: long-form
    /// reading, not UI. Increased contrast restores full strength.
    var bodyInk: NSColor {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? label : label.withAlphaComponent(0.86)
    }

    /// CSS colour for the preview's body text, when the theme pins one.
    var cssInk: String? { palette.map { String(format: "#%06X", $0.inkHex) } }
}

struct ThemePalette {
    let background: NSColor
    /// Header, tab bar, sidebar and inspector.
    let chrome: NSColor
    let ink: NSColor
    let accent: NSColor
    let inkHex: Int

    init(background: Int, chrome: Int, ink: Int, accent: Int) {
        self.background = Self.color(background)
        self.chrome = Self.color(chrome)
        self.ink = Self.color(ink)
        self.accent = Self.color(accent)
        inkHex = ink
    }

    private static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// Window chrome in the theme's panel shade; system themes keep the bar material.
    @ViewBuilder func themedChrome(_ theme: EditorTheme) -> some View {
        if let p = theme.palette { background(Color(nsColor: p.chrome)) } else { background(.bar) }
    }

    /// Sidebar and inspector: named themes paint their panel shade over the
    /// list background; system themes keep the native sidebar material.
    @ViewBuilder func themedPanel(_ theme: EditorTheme) -> some View {
        if let p = theme.palette { scrollContentBackground(.hidden).background(Color(nsColor: p.chrome)) } else { self }
    }

    /// Paper, panels and accent for the whole window when a named theme is on.
    @ViewBuilder func themedTint(_ theme: EditorTheme) -> some View {
        if let p = theme.palette { tint(Color(nsColor: p.accent)) } else { self }
    }
}

/// The header's theme switcher: a palette menu grouped by light and dark.
struct ThemeMenu: View {
    @Bindable var prefs = Preferences.shared

    var body: some View {
        Menu {
            Picker("Theme", selection: $prefs.theme) {
                ForEach([EditorTheme.system, .light, .dark]) { Text($0.title).tag($0) }
            }.pickerStyle(.inline)
            Picker("Light", selection: $prefs.theme) {
                ForEach(EditorTheme.lightThemes) { Text($0.title).tag($0) }
            }.pickerStyle(.inline)
            Picker("Dark", selection: $prefs.theme) {
                ForEach(EditorTheme.darkThemes) { Text($0.title).tag($0) }
            }.pickerStyle(.inline)
        } label: {
            Image(systemName: "paintpalette")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Theme: \(prefs.theme.title)")
        .accessibilityLabel("Theme")
        .accessibilityValue(prefs.theme.title)
    }
}
