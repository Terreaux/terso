// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// The statistics sheet's card surface: the control background inside a
/// hairline separator, so cards read as raised on the window background in
/// both appearances without a shadow.
extension View {
    func dashboardSurface(cornerRadius: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

/// A titled card. The accessory sits on the title line: a mode picker, or the
/// few summary figures the chart below explains.
struct DashboardCard<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardSurface()
    }
}

extension DashboardCard where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// One headline figure: what it measures, the value, and a line of context.
/// The footer carries a goal bar or a reveal action when the figure has one.
struct KPITile<Footer: View>: View {
    let label: String
    let value: String
    let symbol: String
    var caption: String?
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label).font(.callout.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: symbol).font(.callout).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardSurface()
        .accessibilityElement(children: .combine)
    }
}

extension KPITile where Footer == EmptyView {
    init(label: String, value: String, symbol: String, caption: String? = nil) {
        self.init(label: label, value: value, symbol: symbol, caption: caption) { EmptyView() }
    }
}

/// A row of tiles that share the tallest tile's height.
struct KPIRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 12) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The floating label a chart shows under the pointer.
struct ChartTooltip: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(lines, id: \.self) { Text($0).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A small figure in a card's title line: "Median 14.0".
struct StatChip: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A list row that reveals a passage: hover tints it, the arrow says where it goes.
struct PassageRowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                label
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(hovering ? .primary : .tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hovering ? Color.secondary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
