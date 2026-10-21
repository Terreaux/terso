// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Creation stays in the start tab until the writer chooses a real format.
struct NewDocumentChoices: View {
    let create: (DocumentCreationRequest) -> Void
    @State private var selectedTemplate: WritingTemplate?
    @FocusState private var focus: ChoiceFocus?

    private enum ChoiceFocus: Hashable {
        case template(WritingTemplate), format(TemplateSourceFormat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let template = selectedTemplate {
                formatChoices(for: template)
            } else {
                blankChoices
                templateButton(.book)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Templates").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(WritingTemplate.starters) { template in
                            templateButton(template, compact: true)
                        }
                    }
                }
            }
        }
        .themedTint(Preferences.shared.theme)
    }

    private var blankChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Blank document").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(NewDocumentKind.allCases) { kind in
                    Button { create(.blank(kind)) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: kind.symbol).font(.title3).foregroundStyle(Color.accentColor)
                            Text(kind.title).font(.callout.weight(.medium))
                            Text(".\(kind.fileExtension)").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .help(kind.detail)
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    private func templateButton(_ template: WritingTemplate, compact: Bool = false) -> some View {
        Button {
            selectedTemplate = template
            focus = .format(.markdown)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: template.symbol).font(.title3).frame(width: 24)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.title).font(.callout.weight(.medium))
                    if !compact { Text(template.detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: compact ? 32 : 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .focused($focus, equals: .template(template))
        .help(template.detail)
    }

    private func formatChoices(for template: WritingTemplate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                selectedTemplate = nil
                focus = .template(template)
            } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            Text("Choose a format for your \(template.title.lowercased())")
                .font(.headline)
            ForEach(TemplateSourceFormat.allCases) { format in
                Button {
                    selectedTemplate = nil
                    create(.template(template, format))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: format.symbol)
                            .font(.title2).frame(width: 30).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(template.title) · \(format.title) (.\(format.fileExtension))")
                                .font(.callout.weight(.semibold))
                            Text(format.detail(book: template.isBook))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .focused($focus, equals: .format(format))
            }
        }
    }
}
