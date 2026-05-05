import SwiftUI
import UIKit
import ImageIO

/// `AsyncImage`-style view backed by a shared in-memory cache so covers
/// don't re-fetch every time a feed cell scrolls back into view. The
/// underlying `URLSession.shared` uses the app-wide URLCache configured in
/// `WWAVApp.init` for disk-level persistence.
///
/// Behavior:
///   - On render, check the in-memory cache for `url` → instant draw.
///   - Otherwise fetch once on a Task; on success, decode + cache + draw.
///   - When `url` changes, swap the displayed image (no flash) once the
///     new URL resolves; stale fetches are dropped via a generation token.
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var onImageLoad: (UIImage) -> Void = { _ in }
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var generation: UUID = UUID()

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        // Wide / tall source images render outside their frame when using
        // `.aspectRatio(.fill)`. Clipping the whole view to its frame stops
        // those images from bleeding into adjacent feed rows.
        .clipped()
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        let token = UUID()
        await MainActor.run { self.generation = token }
        guard let url else {
            await MainActor.run { self.image = nil }
            return
        }

        // 1. In-memory cache — instant.
        if let hit = ImageCache.shared.image(for: url) {
            await MainActor.run {
                if self.generation == token {
                    self.image = hit
                    self.onImageLoad(hit)
                }
            }
            return
        }

        // 2. Network / disk-cache fetch via URLSession (URLCache picks up).
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            guard let decoded = ImageCache.decodedImage(from: data) else { return }
            ImageCache.shared.set(decoded, for: url)
            try Task.checkCancellation()
            await MainActor.run {
                if self.generation == token {
                    self.image = decoded
                    self.onImageLoad(decoded)
                }
            }
        } catch {
            // Quietly leave the placeholder showing — the next scroll-in
            // pass will retry without spamming the user.
        }
    }
}

/// Process-wide image cache. NSCache auto-evicts under memory pressure,
/// so we don't need a manual size cap — but we set a generous count limit
/// so a long scrolling session doesn't kick out covers the user just saw.
final class ImageCache {
    static let shared = ImageCache()
    private let store = NSCache<NSURL, UIImage>()
    private static let maxPixelSize: CGFloat = 1_200

    private init() {
        store.countLimit = 90
        store.totalCostLimit = 72 * 1_024 * 1_024
    }

    func image(for url: URL) -> UIImage? {
        store.object(forKey: url as NSURL)
    }

    func set(_ image: UIImage, for url: URL) {
        store.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
    }

    static func decodedImage(from data: Data) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return UIImage(data: data)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: image)
    }

    private static func cost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        return max(1, Int(pixels * 4))
    }
}
