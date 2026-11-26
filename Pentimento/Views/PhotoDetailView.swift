import SwiftUI

struct PhotoDetailView: View {
    @ObservedObject var library: PhotoLibrary
    let metadata: PhotoMetadata
    @State private var confirmSelected = false
    @State private var confirmAll = false

    private var visibleGroups: [MetadataGroup] {
        metadata.groups.filter { group in
            (library.groupFilter == "all" || library.groupFilter == group.id) &&
            (library.search.isEmpty || group.tags.contains { tag in
                [tag.label, tag.name, tag.value].contains { $0.localizedCaseInsensitiveContains(library.search) }
            })
        }.map { group in
            guard !library.search.isEmpty else { return group }
            return MetadataGroup(id: group.id, label: group.label, tags: group.tags.filter { tag in
                [tag.label, tag.name, tag.value].contains { $0.localizedCaseInsensitiveContains(library.search) }
            })
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 24)
                overview.padding(.bottom, 24)
                if !metadata.findings.isEmpty { personalInformation.padding(.bottom, 24) }
                metadataControls.padding(.bottom, 12)
                if visibleGroups.isEmpty { Text("No tags match your filters.").foregroundStyle(.secondary) }
                ForEach(visibleGroups) { group in
                    Section {
                        ForEach(group.tags) { tag in tagRow(tag) }
                    } header: {
                        groupHeader(group).padding(.top, 16).padding(.bottom, 6)
                    }
                }
            }
            .frame(maxWidth: 850, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .alert("Remove selected tags?", isPresented: $confirmSelected) {
            Button("Remove", role: .destructive) { library.removeSelected(broad: false) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The selected metadata will be permanently removed from the original file. This can’t be undone.")
        }
        .alert("Remove all supported metadata?", isPresented: $confirmAll) {
            Button("Remove All", role: .destructive) { library.removeSelected(broad: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Embedded metadata will be removed while preserving image orientation and color information. This can’t be undone." + (LivePhotoPolicy.isLivePhoto(metadata) ? " Live Photo pairing, Apple Maker Notes and camera make/model will be retained. The companion MOV is not edited and may still contain private metadata." : ""))
        }
    }

    private var overview: some View {
        HStack(alignment: .top, spacing: 20) {
            PhotoThumbnail(url: metadata.url, size: 168, maxPixelSize: 512, revision: library.imageRevision(for: metadata.url), cache: library.imageCache)
            VStack(alignment: .leading, spacing: 12) {
                if metadata.sensitiveTags > 0 {
                    Label("Found \(metadata.sensitiveTags) privacy-sensitive tags in \(metadata.sensitiveCategories) categories. Select what to remove, or remove all supported metadata.", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                } else {
                    Label("No classified personal information found in this photo’s metadata.", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                }
                Text("\(metadata.totalTags) tags · \(metadata.removableTags) removable")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let gps = metadata.gps {
                    HStack {
                        Label(String(format: "%.5f, %.5f", gps.latitude, gps.longitude), systemImage: "mappin")
                        Button("Open in Maps…") { openMaps(gps) }
                            .help("Sends these coordinates to Apple Maps")
                    }
                }
                if metadata.protectedSensitiveTags > 0 {
                    Text("\(metadata.protectedSensitiveTags) sensitive tags are read-only or protected; see All Metadata.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if metadata.unclassifiedRemovableTags > 0 {
                    Text("\(metadata.unclassifiedRemovableTags) removable tags are outside the privacy categories.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var personalInformation: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                selectionButton(metadata.findings.flatMap { $0.tags.map(\.key) })
                Text("Personal Information").font(.title3.bold())
            }
            ForEach(metadata.findings) { finding in
                PrivacyFindingCard(finding: finding, selectedKeys: $library.selectedKeys,
                    selectionDisabled: !isWritableFormat || library.busy)
            }
        }
    }
    private var metadataControls: some View {
        HStack {
            Text("All Metadata").font(.title3.bold())
            Spacer()
            Picker("Group", selection: $library.groupFilter) {
                Text("All Groups").tag("all")
                ForEach(metadata.groups) { group in Text(group.label).tag(group.id) }
            }.labelsHidden().frame(width: 180)
            TextField("Search tags", text: $library.search).textFieldStyle(.roundedBorder).frame(width: 200)
        }
    }
    private func groupHeader(_ group: MetadataGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                selectionButton(group.tags.filter(\.removable).map(\.key))
                Text(group.label).fontWeight(.semibold)
                Text("\(group.tags.count)").foregroundStyle(.secondary)
                if !group.removable { Text("· Read-only").foregroundStyle(.secondary) }
            }
            MetadataColumnHeadings()
            Divider()
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metadata.url.lastPathComponent).font(.largeTitle.bold()).textSelection(.enabled)
                    Text([metadata.fileType, metadata.fileSize, metadata.dimensions].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder") { library.showInFinder(metadata.url) }
            }
            HStack {
                Button("Remove Selected") { confirmSelected = true }
                    .disabled(library.selectedKeys.isEmpty || library.busy || !isWritableFormat)
                Button("Remove All") { confirmAll = true }
                    .disabled(LivePhotoPolicy.broadTargets(in: metadata).isEmpty || library.busy || !isWritableFormat)
                if library.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh") { library.loadSelected(forceRefresh: true) }.disabled(library.busy)
            }
            if !isWritableFormat {
                Label("Editing is disabled for this format. JPEG, PNG, TIFF and HEIC/HEIF can be edited.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if LivePhotoPolicy.isLivePhoto(metadata) {
                Label("Live Photo still image. Remove All preserves pairing information and Apple Maker Notes, which may contain identifiers. The companion MOV is not cleaned and may contain private metadata.", systemImage: "livephoto")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = library.result {
                Label(result.verified ? "Verified removal of \(result.removed) requested tags. \(result.metadata.sensitiveTags) classified sensitive tags remain; other information may remain." : "Removed \(result.removed) of \(result.requested) requested tags. \(result.remaining.count) remain.", systemImage: result.verified ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(result.verified ? .green : .orange)
            }
            if let error = library.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            ForEach(metadata.warnings, id: \.self) { warning in Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            ForEach(library.result?.warnings ?? [], id: \.self) { warning in Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        }
    }
    private var isWritableFormat: Bool { MetadataService.writableExtensions.contains(metadata.url.pathExtension.lowercased()) }
    private func selectionButton(_ keys: [String]) -> some View {
        let checked = !keys.isEmpty && keys.allSatisfy { library.selectedKeys.contains($0) }
        return Toggle("Select tags", isOn: Binding(get: { checked }, set: { library.toggle(keys, to: $0) }))
            .labelsHidden().disabled(keys.isEmpty || !isWritableFormat || library.busy)
    }
    private func tagRow(_ tag: MetadataTag) -> some View {
        MetadataTagRow(tag: tag, selected: library.selectedKeys.contains(tag.key),
            disabled: !tag.removable || !isWritableFormat || library.busy,
            onChange: { library.toggle([tag.key], to: $0) }).equatable()
    }
    private func openMaps(_ gps: GPSCoordinates) {
        guard let url = URL(string: "https://maps.apple.com/?ll=\(gps.latitude),\(gps.longitude)") else { return }
        NSWorkspace.shared.open(url)
    }
}

