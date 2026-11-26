import SwiftUI

struct PhotoThumbnail: View {
    let url: URL
    let size: CGFloat
    let maxPixelSize: Int
    let revision: Int
    let cache: PhotoImageCache
    @State private var image: CGImage?

    private var request: PhotoImageCache.Request {
        .init(url: url, maxPixelSize: maxPixelSize, revision: revision)
    }
    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").resizable().scaledToFit().foregroundStyle(.secondary).padding(size > 40 ? 30 : 6)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: size > 40 ? 8 : 5))
        .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 8 : 5))
        .task(id: request) {
            let loaded = await cache.image(for: request)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
