import SwiftUI

/// Shared column sizing keeps headings and rows aligned as the window resizes.
struct MetadataColumnsLayout: Layout {
    private let spacing: CGFloat = 12

    private func widths(for width: CGFloat) -> [CGFloat] {
        let checkbox = min(20, width)
        let textSpace = max(0, width - checkbox - spacing * 2)
        let tag = min(220, max(120, width * 0.32), textSpace * 0.48)
        return [checkbox, tag, max(0, textSpace - tag)]
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? 600)
        let columns = widths(for: width)
        let height = subviews.enumerated().map { index, view in
            view.sizeThatFits(ProposedViewSize(width: columns[index], height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = widths(for: bounds.width)
        var x = bounds.minX
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: columns[index], height: nil))
            x += columns[index] + spacing
        }
    }
}

struct MetadataColumnHeadings: View {
    var body: some View {
        MetadataColumnsLayout {
            Color.clear.frame(height: 1).accessibilityHidden(true)
            Text("Tag").frame(maxWidth: .infinity, alignment: .leading)
            Text("Value").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }
}

struct MetadataTagRow: View, Equatable {
    let tag: MetadataTag
    let selected: Bool
    let disabled: Bool
    var showCategory = true
    let onChange: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tag == rhs.tag && lhs.selected == rhs.selected && lhs.disabled == rhs.disabled && lhs.showCategory == rhs.showCategory
    }
    var body: some View {
        MetadataColumnsLayout {
            Toggle("Select \(tag.label)", isOn: Binding(get: { selected }, set: onChange))
                .labelsHidden().disabled(disabled)
            VStack(alignment: .leading, spacing: 3) {
                Text(tag.label).fontWeight(.medium).lineLimit(2)
                Text(tag.key).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if showCategory, let category = tag.category {
                    Text(category.title).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(tag.value).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).help(tag.value)
        }
        .padding(.vertical, 7)
    }
}
