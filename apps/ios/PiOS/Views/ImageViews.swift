import PiOSCore
import SwiftUI
import UIKit

/// Decoded images by ref or by a hash of their inline data. Refs are content
/// addressed on the daemon, so a hit never goes stale.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func store(_ image: UIImage, key: String, bytes: Int) {
        cache.setObject(image, forKey: key as NSString, cost: bytes)
    }
}

/// An image block: inline base64, or a ref fetched from the daemon with the
/// device token. Space is reserved from the reported size when there is one.
struct ImageContentView: View {
    let image: ImageContent
    var maxHeight: CGFloat = 320
    @Environment(AppModel.self) private var model
    @State private var loaded: UIImage? = nil
    @State private var failed = false
    @State private var zoomed = false

    private var key: String { image.ref ?? "inline:\(image.data.count):\(image.data.prefix(64))" }

    var body: some View {
        Group {
            if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture { zoomed = true }
            } else if failed {
                Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxHeight: min(maxHeight, 160))
                    .overlay(ProgressView())
            }
        }
        .task(id: key) { await load() }
        .fullScreenCover(isPresented: $zoomed) {
            if let loaded { ZoomableImage(image: loaded) }
        }
    }

    private var aspect: CGFloat {
        guard let width = image.width, let height = image.height, height > 0 else { return 4 / 3 }
        return width / height
    }

    private func load() async {
        if let cached = ImageCache.shared.image(key) {
            loaded = cached
            return
        }
        var data: Data?
        if !image.data.isEmpty {
            data = Data(base64Encoded: image.data, options: .ignoreUnknownCharacters)
        } else if let ref = image.ref, let api = model.api {
            data = try? await api.image(ref: ref)
        }
        guard let data, let decoded = UIImage(data: data) else {
            failed = true
            return
        }
        ImageCache.shared.store(decoded, key: key, bytes: data.count)
        loaded = decoded
    }
}

struct ZoomableImage: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in scale = max(1, base * value.magnification) }
                        .onEnded { _ in base = scale }
                )
                .onTapGesture(count: 2) {
                    withAnimation { scale = scale > 1 ? 1 : 2.5; base = scale }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.8))
            }
            .padding()
        }
    }
}

/// Downscales a picked photo before it is inlined into the outbox: a
/// 12-megapixel original is slow over a relay and no better for a model.
func encodeForPrompt(_ data: Data, maxDimension: CGFloat = 1568) -> ImageContent? {
    guard let image = UIImage(data: data) else { return nil }
    let size = image.size
    let scale = min(1, maxDimension / max(size.width, size.height))
    let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: target))
    }
    guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return nil }
    return ImageContent(
        data: jpeg.base64EncodedString(), mimeType: "image/jpeg", width: Double(target.width), height: Double(target.height)
    )
}
