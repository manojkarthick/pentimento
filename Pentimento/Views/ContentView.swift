import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @ObservedObject var library: PhotoLibrary
    @State private var dropTarget = false
    @State private var selectingPhotos = false
    @State private var photosToRemove: Set<URL> = []
    @State private var sidebarSelection: Set<URL> = []
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Photos").font(.headline)
                    Spacer()
                    Button {
                        selectingPhotos.toggle()
                        photosToRemove = []
                    } label: {
                        if selectingPhotos { Text("Done") }
                        else { Image(systemName: "checklist") }
                    }
                    .buttonStyle(.borderless)
                    .disabled(library.photos.isEmpty)
                    .help(selectingPhotos ? "Finish selecting photos" : "Select photos to remove from the list")
                    .accessibilityLabel(selectingPhotos ? "Done Selecting Photos" : "Select Photos")
                    Button { library.openPanel() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Open Photos… (⌘O)")
                }.padding(12)
                List(selection: Binding<Set<URL>>(
                    get: { selectingPhotos ? [] : sidebarSelection },
                    set: { if !selectingPhotos { sidebarSelection = $0 } }
                )) {
                    ForEach(library.photos, id: \.self) { url in
                        Group {
                            if selectingPhotos {
                                Button {
                                    if !photosToRemove.insert(url).inserted { photosToRemove.remove(url) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: photosToRemove.contains(url) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(photosToRemove.contains(url) ? Color.accentColor : Color.secondary)
                                        photoRow(url)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(url.lastPathComponent)
                                .accessibilityValue(photosToRemove.contains(url) ? "Selected" : "Not selected")
                            } else {
                                photoRow(url)
                            }
                        }
                        .tag(url)
                    }
                }
                // The list supplies the clicked row or the full selection, matching Finder.
                .contextMenu(forSelectionType: URL.self) { urls in
                    if !urls.isEmpty {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(library.photos.filter { urls.contains($0) })
                        }
                        Button(urls.count == 1 ? "Remove from List" : "Remove \(urls.count) Photos from List") {
                            library.removeFromList(urls)
                        }
                    }
                }
                if selectingPhotos {
                    VStack(spacing: 10) {
                        HStack {
                            Text("\(photosToRemove.count) selected")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(photosToRemove.count == library.photos.count ? "Deselect All" : "Select All") {
                                photosToRemove = photosToRemove.count == library.photos.count ? [] : Set(library.photos)
                            }
                            .buttonStyle(.borderless)
                        }
                        Button(role: .destructive) {
                            library.removeFromList(photosToRemove)
                            photosToRemove = []
                            selectingPhotos = false
                        } label: {
                            Label("Remove from List", systemImage: "minus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(photosToRemove.isEmpty)
                        .help("Remove selected photos from the list. Original files stay on disk.")
                    }
                    .padding(12)
                }
                if library.photos.isEmpty {
                    Text("Opened photos appear here.")
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
            }
            .onChange(of: library.photos) { _, photos in
                sidebarSelection.formIntersection(photos)
                photosToRemove.formIntersection(photos)
                if photos.isEmpty { selectingPhotos = false }
            }
            .onChange(of: sidebarSelection) { _, selection in
                library.selected = selection.count == 1 ? selection.first : nil
            }
            .onChange(of: library.selected) { _, selected in
                if let selected { sidebarSelection = [selected] }
                else if sidebarSelection.count == 1 { sidebarSelection = [] }
            }
            .onAppear {
                if let selected = library.selected { sidebarSelection = [selected] }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            Group {
                if sidebarSelection.count > 1 {
                    VStack(spacing: 14) {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 46)).foregroundStyle(.secondary)
                        Text("\(sidebarSelection.count) photos selected").font(.title2.bold())
                        Text("Select one photo to inspect its metadata.").foregroundStyle(.secondary)
                    }
                    .padding(32)
                }
                else if library.selected == nil { home }
                else if library.busy && library.metadata == nil { ProgressView("Reading photo…") }
                else if let metadata = library.metadata { PhotoDetailView(library: library, metadata: metadata).id(metadata.url) }
                else { errorView }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    guard let url = object else { return }
                    Task { @MainActor in library.add([url]) }
                }
            }
            return !providers.isEmpty
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 10).stroke(.tint, lineWidth: 3).padding(8).allowsHitTesting(false) } }
    }
    private func photoRow(_ url: URL) -> some View {
        HStack(spacing: 10) {
            PhotoThumbnail(url: url, size: 30, maxPixelSize: 96, revision: library.imageRevision(for: url), cache: library.imageCache)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).lineLimit(1)
                Text(library.summary(for: url))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var home: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 46)).foregroundStyle(.secondary)
            Text(library.photos.isEmpty ? "Inspect photo metadata" : "Select a photo").font(.title2.bold())
            Text(library.photos.isEmpty ? "Drop photos here or open them to see location, device details and other personal information they contain." : "Choose a photo in the sidebar to see what its metadata reveals.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Button("Open Photos…") { library.openPanel() }.buttonStyle(.borderedProminent)
        }.padding(32)
    }
    private var errorView: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text("Can’t read this photo").font(.title2.bold())
            Text(library.error ?? "Unknown error").foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Try Again") { library.loadSelected(forceRefresh: true) }
                if let url = library.selected { Button("Remove from List") { library.removeFromList(url) } }
            }
        }.padding(32)
    }
}
