import Photos
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

    private var key: String { image.ref ?? "inline:\(image.data.count):\(image.data.prefix(64))" }

    var body: some View {
        Group {
            if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture { model.viewedImage = ViewedImage(image: loaded) }
                    .contextMenu {
                        Button {
                            Task { model.toast = await saveToPhotos(loaded) }
                        } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                        Button {
                            UIPasteboard.general.image = loaded
                            model.toast = "Copied image"
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                        ShareLink(item: Image(uiImage: loaded), preview: SharePreview("Image", image: Image(uiImage: loaded))) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
            } else if failed {
                Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.hover)
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxHeight: min(maxHeight, 160))
                    .overlay(ProgressView())
            }
        }
        .task(id: key) { await load() }
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

/// An image open full screen. Held by the app model and presented from the
/// root, not from the transcript row: a rotation can rebuild the chat's
/// layout, and a cover owned by a row would close with it.
struct ViewedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Adds to the library only, so the prompt asks for the narrowest access.
func saveToPhotos(_ image: UIImage) async -> String {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
        return "Allow PiOS to add photos in Settings to save images."
    }
    do {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
        return "Saved to Photos"
    } catch {
        return "Could not save: \(error.localizedDescription)"
    }
}

struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var chrome = true
    @State private var note: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableImage(image: image) {
                withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
            }
            .ignoresSafeArea()
            if chrome { controls.transition(.opacity) }
        }
        .statusBarHidden(!chrome)
        .task(id: note) {
            guard note != nil else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { note = nil }
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
            }
            Spacer()
            if let note {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.6)))
            }
            HStack(spacing: 12) {
                ShareLink(item: Image(uiImage: image), preview: SharePreview("Image", image: Image(uiImage: image))) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
                Spacer()
                Button {
                    Task {
                        let result = await saveToPhotos(image)
                        withAnimation { note = result }
                    }
                } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel("Save to Photos")
            }
        }
        .font(.system(size: 17, weight: .medium))
        .buttonStyle(ViewerButtonStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Dark disc that reads on any image, light or dark.
private struct ViewerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(.black.opacity(configuration.isPressed ? 0.75 : 0.5)))
            .contentShape(Circle())
    }
}

/// UIScrollView zooming: the pinch anchors under the fingers, a zoomed image
/// pans, and a double tap zooms toward the tapped point, none of which a
/// SwiftUI scale effect does.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var onTap: () -> Void = {}

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(image: image)
        view.onTap = onTap
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onTap = onTap
        view.setImage(image)
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    var onTap: () -> Void = {}
    private let imageView = UIImageView()
    /// Bounds the image was last fitted to; a rotation refits it.
    private var fittedTo: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        fittedTo = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedTo { fit() }
        centre()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    /// Zoom scale 1 is the image fitted to the screen, so the zoom range
    /// means the same thing in either orientation.
    private func fit() {
        fittedTo = bounds.size
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        zoomScale = 1
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        minimumZoomScale = 1
        // Far enough to read a screenshot's small print, or its own pixels
        // twice over if it is larger.
        maximumZoomScale = max(4, 2 / scale)
    }

    /// A fitted or zoomed-out image sits centred instead of in the corner.
    private func centre() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        if contentInset != inset { contentInset = inset }
    }

    @objc private func tapped() { onTap() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let target = min(maximumZoomScale, 3)
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
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
