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
        private weak var configuredWindow: NSWindow?
        private var didAttemptInitialGrouping = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== configuredWindow else { return }
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            observations.removeAll(); selectionObservation = nil
            configuredWindow = window
            didAttemptInitialGrouping = false
            window.tabbingIdentifier = "org.terso.document"
            window.tabbingMode = .preferred
            observations.append(window.observe(\.tabGroup) { [weak self] _, _ in self?.scheduleAppearanceUpdate() })
            observations.append(window.observe(\.title) { [weak self] _, _ in self?.scheduleAppearanceUpdate() })
            updateAppearance()

            // SwiftUI may attach this view after AppKit has decided whether to
            // tab the window. Retry explicitly after its first presentation.
            NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                name: NSWindow.didBecomeKeyNotification, object: window)
            Task { @MainActor [weak self, weak window] in
                guard let self, let window, self.window === window, window.isVisible else { return }
                self.joinExistingDocumentWindow()
            }
        }

        @objc private func windowBecameKey(_ notification: Notification) {
            joinExistingDocumentWindow()
        }

        private func joinExistingDocumentWindow() {
            guard let window, !didAttemptInitialGrouping else { return }
            didAttemptInitialGrouping = true
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
            // Only group on initial presentation, so a user-detached tab stays
            // detached when it becomes key again. Preserve groups AppKit made.
            guard (window.tabbedWindows?.count ?? 0) <= 1,
                  let destination = NSApp.orderedWindows.first(where: {
                      $0 !== window && $0.isVisible && !$0.isMiniaturized &&
                      $0.tabbingIdentifier == window.tabbingIdentifier &&
                      $0.tabbingMode != .disallowed && $0.attachedSheet == nil
                  }) else { return }
            destination.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
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
