// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

struct ExerciseSheet: View {
    @Bindable var controller: ExerciseSheetController
    @State private var deleting: UUID?
    @FocusState private var editingTitle: Bool
    private var store: ExerciseStore { controller.store }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Writing Exercises", systemImage: ExercisePresentation.symbol).font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { controller.closeSaving() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            if let session = controller.session {
                sessionHeader(session)
                if controller.reuse { reuse(session) }
                else if controller.review { review(session) }
                else { active(session) }
            } else { chooser }
            if let message = controller.message ?? store.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle")
                    Text(message).textSelection(.enabled)
                    Spacer()
                    Button("Retry save") { _ = controller.flush(explicit: true) }
                        .disabled(controller.session == nil)
                }.font(.caption).padding(12).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Text(controller.saveState).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(controller.saveState.isEmpty ? "New exercise" : controller.saveState)
                Spacer()
                if controller.session != nil {
                    Button("Save for later") {
                        if controller.flush(explicit: true) { controller.closeSaving() }
                    }
                }
            }.padding(.horizontal, 24).padding(.vertical, 12)
        }
        .frame(minWidth: 440, idealWidth: 700, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .background(Color(nsColor: Preferences.shared.theme.background))
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            Picker("Exercises", selection: $controller.page) {
                Text("New").tag("New")
                Text("Saved").tag("Saved")
            }.pickerStyle(.segmented).frame(maxWidth: 280).padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if controller.page == "Saved" {
                        if store.sessions.isEmpty {
                            ContentUnavailableView {
                                Label("No saved exercises", systemImage: ExercisePresentation.symbol)
                            } description: { Text("Save an exercise to return to its prompts and your writing.") }
                            actions: { Button("Start an exercise") { controller.page = "New" } }
                        }
                        ForEach(store.sessions) { session in
                            savedRow(session)
                        }
                    } else {
                        Text("Choose an exercise").font(.headline)
                        Text("A small place to begin. Skip any step or stop whenever you like.")
                            .foregroundStyle(.secondary).padding(.bottom, 8)
                        ForEach(orderedTemplates) { template in
                            Button { controller.begin(template) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: ExercisePresentation.symbol).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(template.title).font(.headline)
                                        Text(template.purpose).foregroundStyle(.secondary)
                                        Text(template.duration).font(.caption).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }.padding(12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 20)
            }
        }.frame(maxHeight: .infinity)
    }

    private var orderedTemplates: [ExerciseTemplate] {
        let recommended = ExerciseCatalog.recommended(register: Preferences.shared.domain.rawValue)
        return [recommended] + ExerciseCatalog.templates.filter { $0.id != recommended.id }
    }

    private func savedRow(_ session: ExerciseSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { controller.resume(session) } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: ExercisePresentation.symbol).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).font(.headline)
                        Text(session.completed ? "Completed" : "In progress").font(.caption).foregroundStyle(.secondary)
                        if let source = session.source { Text(source.name).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(session.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack {
                Button("Rename") { controller.resume(session); editingTitle = true }
                Spacer()
                if deleting == session.id {
                    Text("Delete this exercise?").font(.caption)
                    Button("Cancel") { deleting = nil }
                    Button("Delete", role: .destructive) {
                        if ExercisePresentation.shared.delete(session.id) { deleting = nil }
                    }
                } else {
                    Button("Delete…", role: .destructive) { deleting = session.id }
                }
            }.controlSize(.small)
        }.padding(12).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sessionHeader(_ session: ExerciseSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { controller.choose() } label: { Label("Exercises", systemImage: "chevron.left") }
                Spacer()
                Text(session.template.duration).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Exercise title", text: Binding(get: { controller.session?.title ?? "" }, set: controller.rename))
                .font(.title3.weight(.semibold)).textFieldStyle(.plain).focused($editingTitle)
                .accessibilityLabel("Exercise title, editable")
            if let source = session.source {
                HStack {
                    Text("From \(ExerciseDraftReuse.resolve(source)?.displayName ?? source.name)").lineLimit(1)
                    if ExerciseDraftReuse.resolve(source) != nil {
                        Button("Return to draft") {
                            guard controller.flush() else { return }
                            controller.closeSaving()
                            if let doc = ExerciseDraftReuse.resolve(source) { doc.workspace?.select(doc) }
                        }.buttonStyle(.link)
                    }
                }.font(.caption).foregroundStyle(.secondary)
                if let excerpt = source.excerpt, !excerpt.isEmpty {
                    DisclosureGroup("Source excerpt") {
                        ScrollView { Text(excerpt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 90)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func active(_ session: ExerciseSession) -> some View {
        let step = session.template.steps[session.currentStep]
        return VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Step \(session.currentStep + 1) of \(session.template.steps.count)").font(.caption).foregroundStyle(.secondary)
                    Text(step.title).font(.headline)
                    Text(step.prompt).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 125)
            ExerciseResponseEditor(text: Binding(
                get: { controller.session?.responses[step.id] ?? "" }, set: controller.edit),
                selectedText: $controller.selectedText)
                .id(step.id)
                .frame(minHeight: 90, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Response to \(step.title)")
            ViewThatFits(in: .horizontal) {
                HStack { navigation(session) }
                VStack(alignment: .leading, spacing: 8) { navigation(session) }
            }
        }.padding(.horizontal, 24).padding(.bottom, 16).frame(maxHeight: .infinity)
    }

    @ViewBuilder private func navigation(_ session: ExerciseSession) -> some View {
        Button("Back") { controller.changeStep(session.currentStep - 1) }.disabled(session.currentStep == 0)
        Button("View all responses") { controller.showReview() }
        if !controller.selectedText.isEmpty {
            Button("Copy selection") { controller.copy(controller.selectedText) }
        }
        Spacer(minLength: 0)
        if session.currentStep == session.template.steps.count - 1 {
            Button("Review writing") { controller.showReview() }.keyboardShortcut(.defaultAction)
        } else {
            Button("Next") { controller.changeStep(session.currentStep + 1) }.keyboardShortcut(.defaultAction)
        }
    }

    private func review(_ session: ExerciseSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review writing").font(.headline)
            Text("Select responses to copy or use in a draft.").font(.caption).foregroundStyle(.secondary)
            responseList(session, editable: true)
            HStack {
                Button("Keep writing") { controller.review = false }
                Button(session.completed ? "Completed" : "Mark complete") { controller.markComplete() }.disabled(session.completed)
                Spacer()
                Button("Try again") { controller.tryAgain() }
            }
            ViewThatFits(in: .horizontal) {
                HStack { copyActions(session) }
                VStack(alignment: .leading, spacing: 8) { copyActions(session) }
            }
        }.padding(.horizontal, 24).padding(.bottom, 16).frame(maxHeight: .infinity)
    }

    @ViewBuilder private func copyActions(_ session: ExerciseSession) -> some View {
        Button("Copy selected writing") { controller.copy(controller.chosenWriting) }.disabled(controller.chosenWriting.isEmpty)
        Button("Copy all responses") { controller.copy(session.allResponses) }.disabled(session.allResponses.isEmpty)
        Spacer(minLength: 0)
        Button("Use in draft…") { controller.prepareReuse() }.disabled(controller.chosenWriting.isEmpty)
    }

    private func responseList(_ session: ExerciseSession, editable: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(session.template.steps.enumerated()), id: \.element.id) { index, step in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle(step.title, isOn: Binding(get: { controller.selectedSteps.contains(step.id) }, set: {
                                if $0 { controller.selectedSteps.insert(step.id) } else { controller.selectedSteps.remove(step.id) }
                            })).font(.headline)
                            Spacer()
                            if editable { Button("Edit") { controller.changeStep(index) } }
                        }
                        Text(session.responses[step.id].flatMap { $0.isEmpty ? nil : $0 } ?? "No response yet")
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        DisclosureGroup("Prompt") { Text(step.prompt).foregroundStyle(.secondary) }.font(.caption)
                    }
                }
            }.padding(.vertical, 8)
        }.frame(maxHeight: .infinity)
    }

    private func reuse(_ session: ExerciseSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use in draft").font(.headline)
            Text("Append the selected responses at the end of an open draft. Its current selection will be kept.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Destination", selection: $controller.destinationID) {
                Text("Choose a draft…").tag(nil as UUID?)
                ForEach(ExerciseDraftReuse.openDocuments.filter { $0.model.renderMode != .preview }) { document in
                    Text(ExerciseDraftReuse.destinationLabel(document)).tag(Optional(document.id))
                }
            }
            responseList(session, editable: false)
            HStack {
                Button("Back to review") { controller.reuse = false }
                Spacer()
                Button("Append to draft") { controller.insert() }
                    .disabled(controller.destinationID == nil || controller.chosenWriting.isEmpty)
            }
        }.padding(.horizontal, 24).padding(.bottom, 16).frame(maxHeight: .infinity)
    }
}

/// Plain native text editing, with its own undo history and no manuscript analysis.
struct ExerciseResponseEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedText: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = ExerciseTextView(frame: .zero)
        view.isRichText = false; view.allowsUndo = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.font = Preferences.shared.baseFont
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.string = text; view.delegate = context.coordinator
        view.setAccessibilityLabel("Exercise response")
        scroll.documentView = view
        DispatchQueue.main.async { [weak view] in
            if let view { view.window?.makeFirstResponder(view) }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text && !view.hasMarkedText() { view.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ExerciseResponseEditor
        init(_ parent: ExerciseResponseEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            guard range.location != NSNotFound, NSMaxRange(range) <= (view.string as NSString).length else { return }
            parent.selectedText = (view.string as NSString).substring(with: range)
        }
    }
}

/// Separate history prevents a response undo from reaching the manuscript.
final class ExerciseTextView: NSTextView {
    private let history = UndoManager()
    override var undoManager: UndoManager? { history }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = EditorHistoryAction(keyEvent: event), action.perform(in: window) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
