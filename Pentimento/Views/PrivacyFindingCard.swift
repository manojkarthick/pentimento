import SwiftUI

struct PrivacyFindingCard: View {
    let finding: PrivacyFinding
    @Binding var selectedKeys: Set<String>
    let selectionDisabled: Bool
    @State private var expanded = false

    private var keys: [String] { finding.tags.filter(\.removable).map(\.key) }
    private var disclosureLabel: String { "\(expanded ? "Collapse" : "Expand") \(finding.category.title)" }
    private var selection: Binding<Bool> {
        Binding(get: { !keys.isEmpty && keys.allSatisfy { selectedKeys.contains($0) } }, set: { selected in
            if selected { selectedKeys.formUnion(keys) } else { selectedKeys.subtract(keys) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.body.weight(.medium))
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(disclosureLabel)
                .help(disclosureLabel)

                Toggle("Select \(finding.category.title)", isOn: selection)
                    .labelsHidden().frame(width: 20)
                    .disabled(keys.isEmpty || selectionDisabled)

                Button { expanded.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: finding.category.symbol).frame(width: 20).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.category.title).fontWeight(.semibold).lineLimit(1)
                            Text(finding.category.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(minWidth: 110, maxWidth: 280, alignment: .leading)
                        .layoutPriority(1)
                        Spacer(minLength: 0)
                        Text(finding.summary).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                            .frame(maxWidth: 300, alignment: .trailing)
                        Text("\(finding.tags.count)").font(.caption).fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(disclosureLabel)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    MetadataColumnHeadings()
                    ForEach(finding.tags) { tag in
                        MetadataTagRow(tag: tag, selected: selectedKeys.contains(tag.key),
                            disabled: !tag.removable || selectionDisabled, showCategory: false,
                            onChange: { selected in
                                if selected { selectedKeys.insert(tag.key) } else { selectedKeys.remove(tag.key) }
                            }).equatable()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
