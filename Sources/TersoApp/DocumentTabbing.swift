// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// Each tab is still its original DocumentGroup window. AppKit owns grouping,
/// dragging, close/edited state and keyboard navigation.
struct DocumentTabbing: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TabConfigurationView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TabConfigurationView: NSView {
        private var observations: [NSKeyValueObservation] = []
        private var selectionObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.removeAll(); selectionObservation = nil
            guard let window else { return }
            window.tabbingIdentifier = "org.terso.document"
            window.tabbingMode = .preferred
            observations.append(window.observe(\.tabGroup) { [weak self] _, _ in self?.scheduleAppearanceUpdate() })
            observations.append(window.observe(\.title) { [weak self] _, _ in self?.scheduleAppearanceUpdate() })
            updateAppearance()
        }

        nonisolated private func scheduleAppearanceUpdate() {
            Task { @MainActor [weak self] in self?.updateAppearance() }
        }

        private func updateAppearance() {
            guard let window else { return }
            selectionObservation = window.tabGroup?.observe(\.selectedWindow) { [weak self] _, _ in
                self?.scheduleAppearanceUpdate()
            }
            let selected = window.tabGroup?.selectedWindow == nil || window.tabGroup?.selectedWindow === window
            window.tab.attributedTitle = NSAttributedString(string: window.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
            ])
            window.tab.toolTip = window.representedURL?.path ?? window.title
        }
    }
}
