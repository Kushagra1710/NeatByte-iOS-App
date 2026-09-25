import AVFoundation
import Foundation
import Observation
import Photos

enum VideoCompressionQuality: String, CaseIterable, Identifiable {
    case balanced
    case spaceSaver

    var id: Self { self }

    var title: String {
        switch self {
        case .balanced: "Balanced (1080p)"
        case .spaceSaver: "Space Saver (720p)"
        }
    }

    var detail: String {
        switch self {
        case .balanced: "Good quality with moderate savings"
        case .spaceSaver: "Smaller file with more compression"
        }
    }

    var presetName: String {
        switch self {
        case .balanced: AVAssetExportPreset1920x1080
        case .spaceSaver: AVAssetExportPreset1280x720
        }
    }
}

struct VideoCompressionResult: Equatable {
    let originalBytes: Int64?
    let compressedBytes: Int64

    var savedBytes: Int64? {
        guard let originalBytes else { return nil }
        return max(0, originalBytes - compressedBytes)
    }
}

enum VideoCompressionState: Equatable {
    case idle
    case preparing
    case exporting
    case saving
    case completed(VideoCompressionResult)
    case failed(String)
}

@MainActor
@Observable
final class VideoCompressionModel {
    private(set) var state: VideoCompressionState = .idle
    private(set) var progress: Double = 0

    private var exportSession: AVAssetExportSession?
    private var temporaryURL: URL?

    var isWorking: Bool {
        switch state {
        case .preparing, .exporting, .saving:
            true
        case .idle, .completed, .failed:
            false
        }
    }

    func compress(
        identifier: String,
        originalBytes: Int64?,
        quality: VideoCompressionQuality,
        photoLibrary: PhotoLibraryService
    ) async {
        guard !isWorking else { return }

        state = .preparing
        progress = 0

        do {
            let asset = try await photoLibrary.requestLocalAVAsset(identifier: identifier)
            guard let session = AVAssetExportSession(
                asset: asset,
                presetName: quality.presetName
            ) else {
                throw CompressionError.unsupportedPreset
            }

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Neatbyte-\(UUID().uuidString)")
                .appendingPathExtension("mov")
            try? FileManager.default.removeItem(at: outputURL)

            session.outputURL = outputURL
            session.outputFileType = .mov
            session.shouldOptimizeForNetworkUse = true

            exportSession = session
            temporaryURL = outputURL
            state = .exporting

            let progressTask = Task { @MainActor [weak self, weak session] in
                while let session, session.status == .exporting {
                    self?.progress = Double(session.progress)
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }

            await session.export()
            progressTask.cancel()

            guard !Task.isCancelled else {
                throw CancellationError()
            }
            guard session.status == .completed else {
                throw session.error ?? CompressionError.exportFailed
            }

            progress = 1
            state = .saving

            let values = try outputURL.resourceValues(forKeys: [.fileSizeKey])
            let compressedBytes = Int64(values.fileSize ?? 0)
            guard compressedBytes > 0 else {
                throw CompressionError.emptyOutput
            }

            try await saveVideoToPhotos(outputURL)
            state = .completed(
                VideoCompressionResult(
                    originalBytes: originalBytes,
                    compressedBytes: compressedBytes
                )
            )
            cleanupTemporaryFile()
        } catch is CancellationError {
            state = .idle
            progress = 0
            cleanupTemporaryFile()
        } catch {
            state = .failed(error.localizedDescription)
            cleanupTemporaryFile()
        }

        exportSession = nil
    }

    func cancel() {
        exportSession?.cancelExport()
        state = .idle
        progress = 0
        cleanupTemporaryFile()
    }

    func reset() {
        guard !isWorking else { return }
        state = .idle
        progress = 0
    }

    private func saveVideoToPhotos(_ url: URL) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw CompressionError.photosAccessRequired
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }

    private func cleanupTemporaryFile() {
        guard let temporaryURL else { return }
        try? FileManager.default.removeItem(at: temporaryURL)
        self.temporaryURL = nil
    }
}

enum CompressionError: LocalizedError {
    case unsupportedPreset
    case exportFailed
    case emptyOutput
    case photosAccessRequired

    var errorDescription: String? {
        switch self {
        case .unsupportedPreset:
            "This video cannot be compressed with the selected quality."
        case .exportFailed:
            "The video export did not finish."
        case .emptyOutput:
            "The compressed video file was empty."
        case .photosAccessRequired:
            "Photos access is required to save the compressed copy."
        }
    }
}
