// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

/// Screen-space clustering keeps hit targets separate even in a long document.
/// Every finding is retained; importance determines the first one shown.
struct MapMarkerCluster: Identifiable {
    let slot: Int
    let markers: [MapMarker]
    var id: Int { slot }

    static func layout(_ markers: [MapMarker], height: CGFloat) -> [Self] {
        let slots = max(1, Int(max(1, height) / 18))
        return Dictionary(grouping: markers) { min(slots - 1, max(0, Int($0.fraction * CGFloat(slots)))) }
            .map { slot, members in
                Self(slot: slot, markers: members.sorted {
                    if $0.severity != $1.severity { return $0.severity > $1.severity }
                    if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
                    return $0.id.uuidString < $1.id.uuidString
                })
            }.sorted { $0.slot < $1.slot }
    }
}

struct IssueRail: View {
    let model: WorkspaceModel
    var body: some View {
        GeometryReader { geo in
            let height = max(1, geo.size.height - 18)
            let clusters = MapMarkerCluster.layout(model.mapMarkers, height: height)
            ZStack(alignment: .top) {
                Capsule().fill(Color.secondary.opacity(0.10)).frame(width: 1)
                if let passage = model.selectedPassage {
                    let selected = clusters.filter { cluster in cluster.markers.contains { passage.findingIDs.contains($0.id) } }
                    if let first = selected.first, let last = selected.last {
                        Capsule().fill(Color(nsColor: HighlightStyle.passageAccent).opacity(0.4))
                            .frame(width: 3, height: CGFloat(last.slot - first.slot) * 18 + 9)
                            .offset(y: CGFloat(first.slot) * 18 + 4)
                            .allowsHitTesting(false)
                    }
                }
                ForEach(clusters) { cluster in
                    RailMarker(model: model, cluster: cluster)
                        // Fixed slots prevent invisible hit regions overlapping.
                        .offset(y: CGFloat(cluster.slot) * 18)
                }
            }.frame(width: 12, height: geo.size.height, alignment: .top)
        }
        .frame(width: 12)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document analysis map")
        .onDisappear { model.previewAnnotation(nil) }
    }
}

private struct RailMarker: View {
    let model: WorkspaceModel
    let cluster: MapMarkerCluster
    private var marker: MapMarker {
        cluster.markers.first { $0.id == model.previewAnnotationID }
        ?? cluster.markers.first { $0.id == model.activeAnnotationID }
        ?? cluster.markers[0]
    }
    private var emphasized: Bool {
        cluster.markers.contains { $0.id == model.previewAnnotationID || $0.id == model.activeAnnotationID }
    }
    private var tooltip: String {
        let excerpt = model.editor?.currentSnapshot.substring(marker.range) ?? ""
        return "\(marker.category.title) · \(marker.severityLabel ?? marker.severity.label)\n\n\(excerpt.prefix(160))\n\n\(marker.message)"
            + (marker.explanation.map { "\n\($0)" } ?? "")
            + (cluster.markers.count > 1 ? "\n\n\(cluster.markers.count) findings here. Click again for the next; secondary-click to choose." : "\n\nClick to inspect this finding.")
    }
    var body: some View {
        Button {
            let current = cluster.markers.firstIndex { $0.id == model.activeAnnotationID }
            let next = current.map { ($0 + 1) % cluster.markers.count } ?? 0
            navigate(cluster.markers[next])
        } label: {
            RoundedRectangle(cornerRadius: marker.category == .references ? 1 : 3)
                .fill(Color(nsColor: HighlightStyle.color(marker.family)).opacity(emphasized ? 1 : marker.severity == .warning ? 0.7 : 0.4))
                .frame(width: emphasized ? 7 : 5, height: cluster.markers.count > 1 ? 9 : 5)
                .overlay {
                    if cluster.markers.count > 1 {
                        Rectangle().fill(Color(nsColor: Preferences.shared.theme.background)).frame(width: 5, height: 1)
                    }
                }
                .frame(width: 12, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel("\(marker.category.title): \(marker.message)")
        .accessibilityValue(cluster.markers.count > 1 ? "\(cluster.markers.count) findings" : "")
        .onHover { over in
            if over { model.previewAnnotation(marker.id) }
            else if cluster.markers.contains(where: { $0.id == model.previewAnnotationID }) { model.previewAnnotation(nil) }
        }
        .onDisappear {
            if cluster.markers.contains(where: { $0.id == model.previewAnnotationID }) { model.previewAnnotation(nil) }
        }
        .contextMenu {
            ForEach(cluster.markers) { item in
                Button("\(item.category.title): \(item.message)") { navigate(item) }
            }
        }
        .animation(.easeOut(duration: 0.12), value: emphasized)
    }
    private func navigate(_ marker: MapMarker) {
        guard let annotation = model.annotation(id: marker.id) else { return }
        model.previewAnnotation(nil)
        if model.inspectorTab == .science, model.selectScienceAnnotation(annotation) { return }
        model.select(annotation)
    }
}
