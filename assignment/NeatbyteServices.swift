import AVFoundation
import CryptoKit
import Foundation
import Photos
import UIKit
import Vision

struct StorageService {
    func snapshot() throws -> StorageSnapshot {
        let values = try URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])

        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else {
            throw CocoaError(.fileReadUnknown)
        }

        return StorageSnapshot(
            totalBytes: Int64(total),
            availableBytes: available
        )
    }
}

@MainActor
final class PhotoLibraryService {
    let imageManager = PHCachingImageManager()

    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func fetchScreenshots() -> [ScreenshotItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "(mediaSubtype & %d) != 0",
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var screenshots: [ScreenshotItem] = []
        screenshots.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            screenshots.append(
                ScreenshotItem(
                    id: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight
                )
            )
        }
        return screenshots
    }

    func fetchVideos() -> [LargeVideoItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: .video, options: options)
        var videos: [LargeVideoItem] = []
        videos.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            videos.append(
                LargeVideoItem(
                    id: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    duration: asset.duration,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight
                )
            )
        }
        return videos
    }

    func fetchPhotoCandidates() -> [PhotoCandidate] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var photos: [PhotoCandidate] = []
        photos.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            photos.append(
                PhotoCandidate(
                    id: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    isFavorite: asset.isFavorite
                )
            )
        }
        return photos
    }

    func requestImage(
        identifier: String,
        targetSize: CGSize,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic,
        completion: @escaping (UIImage?) -> Void
    ) -> PHImageRequestID? {
        guard let asset = asset(for: identifier) else {
            completion(nil)
            return nil
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            completion(image)
        }
    }

    func cancelImageRequest(_ requestID: PHImageRequestID) {
        imageManager.cancelImageRequest(requestID)
    }

    func measureLocalBytes(identifier: String) async throws -> Int64 {
        guard let asset = asset(for: identifier) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let resource: PHAssetResource?
        if asset.mediaType == .video {
            resource = resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video })
        } else {
            resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo })
        }

        guard let resource else {
            throw CocoaError(.fileReadUnknown)
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        return try await withCheckedThrowingContinuation { continuation in
            var byteCount: Int64 = 0
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { data in
                    byteCount += Int64(data.count)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: byteCount)
                    }
                }
            )
        }
    }

    func hashLocalPhoto(identifier: String) async throws -> String {
        guard let asset = asset(for: identifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let photoResource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo }) else {
            throw CocoaError(.fileReadUnknown)
        }

        var resourcesToHash = [photoResource]
        if let pairedVideo = resources.first(where: { $0.type == .fullSizePairedVideo })
            ?? resources.first(where: { $0.type == .pairedVideo }) {
            resourcesToHash.append(pairedVideo)
        }

        var componentHashes: [String] = []
        for resource in resourcesToHash {
            componentHashes.append(try await hash(resource: resource))
        }
        let combined = SHA256.hash(data: Data(componentHashes.joined(separator: "|").utf8))
        return combined.map { String(format: "%02x", $0) }.joined()
    }

    private func hash(resource: PHAssetResource) async throws -> String {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let accumulator = SHA256Accumulator()

        return try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { data in
                    accumulator.update(data)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: accumulator.finalize())
                    }
                }
            )
        }
    }

    func requestAnalysisData(identifier: String) async throws -> Data {
        guard let asset = asset(for: identifier) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 512, height: 512),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let image, let data = image.jpegData(compressionQuality: 0.82) {
                    continuation.resume(returning: data)
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                        ?? CocoaError(.fileReadUnknown)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func requestLocalAVAsset(identifier: String) async throws -> AVAsset {
        guard let asset = asset(for: identifier) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                        ?? CocoaError(.fileReadUnknown)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func deleteAssets(identifiers: Set<String>) async throws {
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: Array(identifiers),
            options: nil
        )
        guard result.count > 0 else { return }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(result)
        }
    }

    private func asset(for identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            .firstObject
    }
}

private final class SHA256Accumulator: @unchecked Sendable {
    private var hasher = SHA256()
    private let lock = NSLock()

    func update(_ data: Data) {
        lock.lock()
        hasher.update(data: data)
        lock.unlock()
    }

    func finalize() -> String {
        lock.lock()
        let digest = hasher.finalize()
        lock.unlock()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

actor PhotoFeatureAnalyzer {
    private var observations: [String: VNFeaturePrintObservation] = [:]

    func storeFeaturePrint(identifier: String, imageData: Data) throws {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(data: imageData)
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw CocoaError(.fileReadUnknown)
        }
        observations[identifier] = observation
    }

    func distance(from firstID: String, to secondID: String) throws -> Float {
        guard let first = observations[firstID],
              let second = observations[secondID] else {
            throw CocoaError(.fileReadUnknown)
        }
        var distance: Float = 0
        try first.computeDistance(&distance, to: second)
        return distance
    }

    func reset() {
        observations.removeAll()
    }
}
