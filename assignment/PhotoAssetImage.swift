import Photos
import SwiftUI

struct PhotoAssetImage: View {
    let identifier: String
    let photoLibrary: PhotoLibraryService
    let targetSize: CGSize
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ProgressView()
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .onAppear(perform: requestImage)
        .onDisappear(perform: cancelRequest)
    }

    private func requestImage() {
        guard requestID == nil else { return }
        requestID = photoLibrary.requestImage(
            identifier: identifier,
            targetSize: targetSize,
            deliveryMode: .opportunistic
        ) { loadedImage in
            image = loadedImage
        }
    }

    private func cancelRequest() {
        guard let requestID else { return }
        photoLibrary.cancelImageRequest(requestID)
        self.requestID = nil
    }
}
