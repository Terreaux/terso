// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore
import TersoAnalysis

/// Problems, then a document model, then exploration. The narrow inspector
/// presents one level at a time; selection belongs to the document session.
struct ScienceInspector: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let science = model.currentScience {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            content(science)
                        }
                        .padding(14)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear {
                        if let id = model.selectedScienceObjectID { proxy.scrollTo(id, anchor: .top) }
                    }
                    .onChange(of: model.selectedScienceObjectID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .top) }
                    }
                }.id(model.scienceDetailSection ?? "overview")
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing current revision…").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(14)
            }
        }
        .font(.system(size: 12))
        .environment(\.mathMacros, MathPresentation.macros(in: model.editor?.currentSnapshot.text ?? ""))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let section = model.scienceDetailSection {
                HStack {
                    Button { model.scienceDetailSection = nil } label: { Label("Science", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Spacer(minLength: 8)
                    Text(section).fontWeight(.semibold)
                }
            } else {
                HStack {
                    Text("Scientific review").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Menu {
                        Button("Analyze again") { model.scheduleAnalysis() }
                        Button("Restore ignored Science warnings") { model.restoreScienceWarnings() }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("Scientific review actions")
                }
                Picker("Profile", selection: $model.scienceProfile) {
                    Text(ScientificProfile.general.displayName).tag(ScientificProfile.general)
                    Text(ScientificProfile.hep.displayName).tag(ScientificProfile.hep)
                }.labelsHidden()
                if model.currentScience != nil {
                    Text(status).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var status: String {
        let diagnostics = model.scienceDiagnostics
        let errors = diagnostics.filter { $0.severity == .error }.count
        let warnings = diagnostics.filter { $0.severity == .warning }.count
        let notes = diagnostics.filter { $0.severity == .info }.count
        return [errors > 0 ? "\(errors) issues" : nil,
                warnings > 0 ? "\(warnings) warnings" : nil,
                notes > 0 ? "\(notes) notes" : nil].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "No structural warnings detected"
    }

    @ViewBuilder private func content(_ science: ScientificDocumentModel) -> some View {
        switch model.scienceDetailSection {
        case nil: overview(science)
        case "Needs attention":
            if model.scienceDiagnostics.isEmpty { empty("No outstanding diagnostics.") }
            ForEach(model.scienceDiagnostics) { diagnostic in diagnosticRow(diagnostic, science: science, expanded: true) }
        case "Scientific Map": relationshipExplorer(science)
        default: overview(science)
        }
    }

    @ViewBuilder private func overview(_ science: ScientificDocumentModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Needs attention")
                Spacer()
                Text("\(model.scienceDiagnostics.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            if model.scienceDiagnostics.isEmpty {
                Text("No structural warnings detected. Scientific validity still needs your review.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.scienceDiagnostics.prefix(model.scienceReview.attentionExpanded ? model.scienceDiagnostics.count : 3)) { diagnostic in diagnosticRow(diagnostic, science: science, expanded: false) }
            if model.scienceDiagnostics.count > 3 {
                Button(model.scienceReview.attentionExpanded ? "Show fewer" : "Show \(model.scienceDiagnostics.count - 3) more") {
                    model.scienceReview.attentionExpanded.toggle()
                }
                    .buttonStyle(.borderless)
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel("Document model").padding(.bottom, 4)
            modelSection("Notation", count: science.symbols.count, science: science)
            modelSection("Definitions", count: science.definitions.count, science: science)
            modelSection("Quantities", count: science.quantities.count, science: science)
            modelSection("Equations", count: science.equations.count, science: science)
            modelSection("References", count: science.references.count, science: science)
            modelSection("Claims", count: science.claims.count, science: science)
            modelSection("Evidence", count: science.evidence.count, science: science)
        }
        Divider()
        Button { model.scienceDetailSection = "Scientific Map" } label: {
            HStack { Text("Scientific Map"); Spacer(); Image(systemName: "arrow.right").font(.caption) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        Text("Local structural checks. Nearby links suggest places to inspect; they do not establish scientific support.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// Document model sections expand in place so several can be compared
    /// without leaving the overview.
    @ViewBuilder private func modelSection(_ title: String, count: Int, science: ScientificDocumentModel) -> some View {
        let expanded = model.scienceReview.expandedSections.contains(title)
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if expanded { model.scienceReview.expandedSections.remove(title) }
                else { model.scienceReview.expandedSections.insert(title) }
            }
        } label: {
            HStack {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(title).foregroundStyle(count == 0 ? .secondary : .primary)
                Spacer()
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }.padding(.vertical, 5).padding(.horizontal, 6).contentShape(Rectangle())
        }.buttonStyle(ScienceModelRowStyle())
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        if expanded {
            VStack(alignment: .leading, spacing: 6) {
                objectList(science, section: title)
            }.padding(.leading, 14).padding(.bottom, 6)
        }
    }

    private func diagnosticRow(_ diagnostic: ScientificDiagnostic, science: ScientificDocumentModel, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { model.selectScienceDiagnostic(diagnostic) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(diagnostic.severity == .info ? Color.secondary : Color(nsColor: HighlightStyle.color(.writing)).opacity(0.85))
                            .frame(width: 5, height: 5).accessibilityHidden(true)
                        ScienceText(diagnosticTitle(diagnostic)).font(.system(size: 12, weight: .medium))
                    }
                    ScienceText(model.editor?.currentSnapshot.substring(diagnostic.sourceRange) ?? "",
                                math: science.symbols.contains { $0.occurrences.contains(diagnostic.sourceRange) }
                                    || science.quantities.contains { $0.sourceRange == diagnostic.sourceRange })
                        .foregroundStyle(.secondary)
                    ScienceText(diagnosticExplanation(diagnostic, science: science))
                        .font(.caption).foregroundStyle(.secondary)
                }.multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                Text("\(diagnostic.severity.rawValue.capitalized) · \(diagnostic.confidence.rawValue.capitalized) confidence")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(diagnostic.relatedObjectIDs, id: \.self) { id in
                    if let node = science.nodes.first(where: { $0.id == id }) {
                        Button { open(node) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                ScienceText(node.title, math: isMath(node, science: science))
                                Text("\(node.kind) · \(sourceLocation(node.sourceRange))").foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if expanded {
                Button("Ignore warning") { model.ignoreScienceDiagnostic(diagnostic) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(model.previewScienceDiagnosticID == diagnostic.id ? Color.primary.opacity(0.08) : model.selectedScienceObjectID == diagnostic.id ? Color.primary.opacity(0.045) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .animation(.easeOut(duration: 0.12), value: model.previewScienceDiagnosticID == diagnostic.id)
        .onHover { over in
            if over { model.previewAnnotation(model.scienceAnnotation(for: diagnostic)?.id) }
            else if model.previewScienceDiagnosticID == diagnostic.id { model.previewAnnotation(nil) }
        }
        .onDisappear { if model.previewScienceDiagnosticID == diagnostic.id { model.previewAnnotation(nil) } }
        .id(diagnostic.id)
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension ScienceInspector {
    func nodes(_ science: ScientificDocumentModel, in section: String) -> [ScientificNode] {
        let kinds: [String: Set<String>] = [
            "Notation": ["Notation"], "Definitions": ["Definition"], "Quantities": ["Quantity"],
            "Equations": ["Equation"], "References": ["Citation", "Cross-reference", "figure", "table", "section", "equation", "unknown"],
            "Claims": ["Claim"], "Evidence": ["Evidence"]
        ]
        return science.nodes.filter { kinds[section, default: []].contains($0.kind) }
            .sorted { $0.sourceRange < $1.sourceRange }
    }

    @ViewBuilder func objectList(_ science: ScientificDocumentModel, section: String) -> some View {
        if section == "Definitions" {
            Text("\(science.symbols.filter { science.definitionStatus(for: $0) == .defined }.count) defined · \(science.symbols.filter { science.definitionStatus(for: $0) == .undefined }.count) without a detected definition · \(science.symbols.filter { science.definitionStatus(for: $0) == .assumedKnowledge }.count) possibly assumed")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Inspect notation without definitions") { model.scienceReview.expandedSections.insert("Notation") }.buttonStyle(.borderless)
        }
        if section == "References" {
            Text("\(science.citations.count) citations · \(science.crossReferences.count) cross-references")
                .font(.caption).foregroundStyle(.secondary)
            Text("Targets in this document: \(science.objects.filter { $0.kind == .equation }.count) equations, \(science.objects.filter { $0.kind == .figure }.count) figures, \(science.objects.filter { $0.kind == .table }.count) tables, \(science.objects.filter { $0.kind == .section }.count) sections")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        let items = nodes(science, in: section)
        if items.isEmpty { empty("No \(section.lowercased()) detected.") }
        ForEach(items) { node in
            VStack(alignment: .leading, spacing: 8) {
                Button { model.navigateScience(objectID: node.id, range: node.sourceRange) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        let quantity = science.quantities.first { node.id == "quantity:\($0.id)" }
                        HStack(alignment: .firstTextBaseline) {
                            ScienceText(quantity.map { quantityTitle($0, science: science) } ?? node.title, math: isMath(node, science: science)).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            if model.selectedScienceObjectID != node.id { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        }
                        if let symbol = science.symbols.first(where: { node.id == "symbol:\($0.id)" }) {
                            Text("\(symbol.usageCount) occurrences · \(definitionLabel(science.definitionStatus(for: symbol)))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let quantity {
                            Text(quantitySubtitle(quantity, science: science)).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(node.kind).font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if model.selectedScienceObjectID == node.id {
                    objectDetail(node, science: science)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedScienceObjectID == node.id ? Color.primary.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .id(node.id)
        }
    }

    @ViewBuilder func objectDetail(_ node: ScientificNode, science: ScientificDocumentModel) -> some View {
        if let symbol = science.symbols.first(where: { node.id == "symbol:\($0.id)" }) {
            Text("\(symbol.symbolType.rawValue.capitalized) · \(symbol.confidence.rawValue.capitalized) confidence")
                .font(.caption).foregroundStyle(.secondary)
            Text(definitionLabel(science.definitionStatus(for: symbol))).font(.caption)
            if let meaning = symbol.meaning { ScienceText(meaning).fixedSize(horizontal: false, vertical: true) }
            occurrenceActions(node, ranges: symbol.occurrences)
            if let definition = symbol.definitions.first {
                Button("Go to definition") { model.navigateScience(objectID: node.id, range: definition) }.buttonStyle(.borderless)
            }
        } else if let definition = science.definitions.first(where: { $0.id == node.id }) {
            ScienceText(definition.text).fixedSize(horizontal: false, vertical: true)
            Text(definition.usedBeforeDefinition ? "Used before this definition" : "Explicit definition detected")
                .font(.caption).foregroundStyle(.secondary)
            occurrenceActions(node, ranges: definition.usages)
        } else if let quantity = science.quantities.first(where: { node.id == "quantity:\($0.id)" }) {
            property("Symbol", quantity.symbol ?? "Not linked")
            property("Value", "\(quantity.numericValue)")
            property("Uncertainty", quantity.uncertainty.map { "± \($0)" } ?? "Not given")
            property("Unit", quantity.normalizedUnit ?? "Not detected")
            let metadata = science.quantityMetadata(for: quantity)
            property("Unit family", metadata.unitDimension ?? "Unknown")
            property("Nearby citations", "\(metadata.nearbyCitationIDs.count)")
            if let meaning = metadata.semanticMeaning { ScienceText(meaning).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            occurrenceActions(node, ranges: metadata.occurrences)
            ScienceText(quantity.context).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if let equation = science.equations.first(where: { $0.id == node.id }) {
            ScienceText(equation.contents, math: true)
                .fixedSize(horizontal: false, vertical: true)
            property("Label", equation.label ?? "Unlabeled")
            property("References", "\(equation.references.count)")
            ForEach(equation.symbolIDs, id: \.self) { symbolID in
                if let symbol = science.symbols.first(where: { "symbol:\($0.id)" == symbolID }),
                   let symbolNode = science.node(id: symbolID) {
                    Button { open(symbolNode) } label: {
                        ScienceText("$\(symbol.displayForm)$ · \(definitionLabel(science.definitionStatus(for: symbol)))")
                            .multilineTextAlignment(.leading)
                    }.buttonStyle(.borderless).font(.caption)
                }
            }
            Text("Dimensions are not checked. Declared dimensions are needed before this can be assessed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if let claim = science.claims.first(where: { $0.objectID == node.id }) {
            claimDetail(claim)
        } else if let evidence = science.evidence.first(where: { $0.id == node.id }) {
            property("Kind", evidence.kind.rawValue.capitalized)
            Text("Detected nearby in a claim’s paragraph. Whether it supports that claim needs review.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if let reference = science.references.first(where: { "reference:\($0.id)" == node.id }) {
            property("Kind", reference.isCitation ? "Citation" : "Cross-reference")
            property("Key", reference.key)
            if reference.isCitation {
                Text("Bibliography checks use definitions available in this document; external files are not loaded.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        let equation = science.equations.first(where: { $0.id == node.id })
        let equationLabels = equation.map { equation in
            science.objects.filter { equation.sourceRange.intersects($0.sourceRange) }.map { "object:\($0.id)" }
        } ?? []
        let relatedIDs = Set([node.id] + (equation?.symbolIDs ?? []) + equationLabels)
        let warnings = model.scienceDiagnostics.filter { $0.relatedObjectIDs.contains(where: relatedIDs.contains) }
        ForEach(warnings) { diagnostic in
            Button { model.selectScienceDiagnostic(diagnostic) } label: {
                ScienceText(diagnosticTitle(diagnostic)).multilineTextAlignment(.leading)
            }.buttonStyle(.borderless)
        }
        Button("Relationships") { model.scienceDetailSection = "Scientific Map" }
            .buttonStyle(.borderless).font(.caption)
    }

    func claimDetail(_ claim: ScientificClaim) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            property("Type", model.scienceReview.authorStatements.contains(claim.text) ? "Author statement" : claimCategory(claim.category))
            property("Classification", model.scienceReview.authorStatements.contains(claim.text) ? "Author override" : "Local pattern · low confidence")
            property("Review", model.scienceReview.authorStatements.contains(claim.text) ? "Marked as author statement" : model.scienceReview.ignoredClaims.contains(claim.text) ? "Warning ignored" : "Unreviewed")
            Text((claim.category == .authorStatement || model.scienceReview.authorStatements.contains(claim.text)) ? "Author experience or opinion; no automatic support warning." : claim.nearbyEvidence.isEmpty ? "No explicit support detected in this paragraph." : "\(claim.nearbyEvidence.count) nearby evidence candidates. Inspect Relationships to assess their relevance.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Find support…") { model.findScienceSupport(claim) }
                .buttonStyle(.borderless).disabled(!model.prefs.aiEnabled || model.prefs.selectedProvider == nil)
                .help("Ask the configured Assistant about this claim, sending the whole document as context; existing AI data-access settings apply.")
            if !model.prefs.aiEnabled { Text("Enable Assistant in Settings to request a semantic review.").font(.caption).foregroundStyle(.secondary) }
            Button("Mark as author statement") { model.markScienceClaim(claim, asAuthorStatement: true) }.buttonStyle(.borderless)
            Button("Ignore warning") { model.markScienceClaim(claim, asAuthorStatement: false) }.buttonStyle(.borderless)
        }
    }

    func property(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            ScienceText(value, math: (name == "Symbol" && value != "Not linked") || (name == "Unit" && value.contains("\\"))).multilineTextAlignment(.trailing)
        }.font(.caption)
    }

    func occurrenceActions(_ node: ScientificNode, ranges: [TextSpan]) -> some View {
        let position = model.scienceReview.occurrencePositions[node.id, default: 0] % max(1, ranges.count)
        return HStack {
            Text("\(ranges.count) occurrences").foregroundStyle(.secondary)
            Spacer()
            Button("Next location") {
                guard !ranges.isEmpty else { return }
                model.navigateScience(objectID: node.id, range: ranges[position])
                model.scienceReview.occurrencePositions[node.id] = position + 1
            }.buttonStyle(.borderless).disabled(ranges.isEmpty)
        }.font(.caption)
    }

    @ViewBuilder func relationshipExplorer(_ science: ScientificDocumentModel) -> some View {
        Text("Follow explicit links and nearby evidence through the document. A connection is not proof of support.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let selected = science.nodes.first(where: { $0.id == model.selectedScienceObjectID }) {
            SectionLabel(selected.kind)
            Button { model.navigateScience(objectID: selected.id, range: selected.sourceRange) } label: {
                ScienceText(selected.title, math: isMath(selected, science: science))
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            let links = science.relationships.filter { $0.sourceID == selected.id || $0.targetID == selected.id }
            if links.isEmpty { empty("No explicit relationships detected for this object.") }
            ForEach(links) { link in
                let outgoing = link.sourceID == selected.id
                if let other = science.nodes.first(where: { $0.id == (outgoing ? link.targetID : link.sourceID) }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(relationshipLabel(link.kind, outgoing: outgoing)).font(.caption).foregroundStyle(.secondary)
                        Button { model.navigateScience(objectID: other.id, range: other.sourceRange) } label: {
                            ScienceText(other.title, math: isMath(other, science: science)).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }.padding(.vertical, 5)
                }
            }
            Button("Choose another object") { model.scienceDetailSection = nil }.buttonStyle(.borderless)
        } else {
            SectionLabel("Start with a claim or equation")
            let roots = science.nodes.filter { ["Claim", "Equation"].contains($0.kind) }
            if roots.isEmpty { empty("Open an object from Document model and choose Relationships.") }
            ForEach(roots) { node in
                Button { model.navigateScience(objectID: node.id, range: node.sourceRange) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.kind).font(.caption).foregroundStyle(.secondary)
                        ScienceText(node.title, math: isMath(node, science: science)).multilineTextAlignment(.leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }
    }

    func diagnosticExplanation(_ diagnostic: ScientificDiagnostic, science: ScientificDocumentModel) -> String {
        guard diagnostic.id.hasPrefix("science.notation.variants:"),
              let separator = diagnostic.explanation.range(of: ": ") else { return diagnostic.explanation }
        let forms = science.symbols.filter { diagnostic.relatedObjectIDs.contains("symbol:\($0.id)") }
            .map { "$\($0.displayForm)$" }.joined(separator: ", ")
        return forms + diagnostic.explanation[separator.lowerBound...]
    }

    func diagnosticTitle(_ diagnostic: ScientificDiagnostic) -> String {
        guard [.notation, .definitions, .quantities].contains(diagnostic.category),
              let separator = diagnostic.title.range(of: ": ", options: .backwards) else { return diagnostic.title }
        return String(diagnostic.title[..<separator.upperBound]) + "$" + diagnostic.title[separator.upperBound...] + "$"
    }

    func isMath(_ node: ScientificNode, science: ScientificDocumentModel) -> Bool {
        (node.kind == "Notation" || node.kind == "Quantity") || science.definitions.contains { $0.id == node.id && $0.symbolID.hasPrefix("symbol:") }
    }

    func open(_ node: ScientificNode) {
        let section: String? = switch node.kind {
        case "Notation": "Notation"
        case "Term": nil
        case "Definition": "Definitions"
        case "Quantity": "Quantities"
        case "Equation": "Equations"
        case "Claim": "Claims"
        case "Evidence": "Evidence"
        default: "References"
        }
        if let section {
            model.scienceReview.expandedSections.insert(section)
            model.scienceDetailSection = nil
        } else { model.scienceDetailSection = "Scientific Map" }
        model.navigateScience(objectID: node.id, range: node.sourceRange)
    }

    /// Typeset from parsed parts so the unit shows even when the source splits
    /// it across math delimiters (`$70$ kg`).
    func quantityTitle(_ quantity: ScientificQuantity, science: ScientificDocumentModel) -> String {
        // Locale-independent: a decimal comma would typeset as a list separator.
        func number(_ value: Double) -> String { value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value) }
        var text = number(quantity.numericValue)
        if let uncertainty = quantity.uncertainty { text += " \\pm " + number(uncertainty) }
        if let unit = quantity.normalizedUnit { text += "\\," + mathUnit(unit) }
        if let symbol = quantity.symbol {
            text = (science.symbols.first { $0.id == symbol }?.displayForm ?? symbol) + " = " + text
        }
        return text
    }

    func quantitySubtitle(_ quantity: ScientificQuantity, science: ScientificDocumentModel) -> String {
        guard quantity.normalizedUnit != nil else { return "No unit detected" }
        return science.quantityMetadata(for: quantity).unitDimension?.capitalized ?? "Unit outside profile"
    }

    func mathUnit(_ unit: String) -> String {
        guard unit != "%" else { return "\\%" }
        let (base, exponent) = unit.hasSuffix("^{-1}") ? (String(unit.dropLast(5)), "^{-1}") : (unit, "")
        let micro = base.hasPrefix("μ") || base.hasPrefix("µ")
        return (micro ? "\\mu" : "") + "\\mathrm{\(micro ? String(base.dropFirst()) : base)}" + exponent
    }

    func sourceLocation(_ range: TextSpan) -> String {
        guard let snapshot = model.editor?.currentSnapshot,
              let prefix = snapshot.substring(TextSpan(location: 0, length: range.location)) else { return "Source" }
        return "line \(prefix.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").filter { $0 == "\n" }.count + 1)"
    }

    func definitionLabel(_ status: ScientificDefinitionStatus) -> String {
        switch status {
        case .defined: "Defined"
        case .undefined: "No definition detected"
        case .assumedKnowledge: "Possibly assumed knowledge"
        }
    }
    func claimCategory(_ category: ScientificClaimCategory) -> String {
        category == .authorStatement ? "Author statement" : category.rawValue.capitalized
    }
    func relationshipLabel(_ kind: ScientificRelationship.Kind, outgoing: Bool) -> String {
        switch kind {
        case .defines: outgoing ? "Defines" : "Defined by"
        case .uses: outgoing ? "Uses" : "Used by"
        case .represents: outgoing ? "Represents" : "Value assigned in"
        case .cites: outgoing ? "Cites" : "Cited by"
        case .nearbyEvidence: outgoing ? "Nearby evidence candidate" : "Nearby claim"
        case .references: outgoing ? "References" : "Referenced by"
        }
    }
}

/// A full-width hit target with a quiet native hover, without adding row chrome.
private struct ScienceModelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.09 : hovering ? 0.045 : 0),
                            in: RoundedRectangle(cornerRadius: 3))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
